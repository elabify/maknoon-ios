// RBF fee-bump sheet. Presented from BitcoinTxRow's long-press
// context menu when the user has an outgoing unconfirmed tx that
// would benefit from a higher fee. The flow mirrors
// BitcoinSendView's state machine: build the replacement PSBT,
// sign (software / hardware BLE), broadcast as a separate step.
//
// The replacement tx reuses the same recipients + amounts as the
// original (BDK's BumpFeeTxBuilder pulls those from the wallet's
// stored tx history), so the user only chooses the new fee rate.

import SwiftUI
import BitcoinDevKit

struct BumpFeeSheet: View {
    let wallet: BitcoinWallet
    let originalTxidHex: String
    /// Original fee in satoshis; surfaced so the user can compare
    /// before vs after. Nil if the parent couldn't compute it (eg
    /// the original tx isn't fully populated in BDK's cache).
    var originalFeeSat: Int64? = nil

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum FeeMode: String, CaseIterable, Identifiable {
        case fastest = "Fastest"
        case halfHour = "30 min"
        case hour = "1 hour"
        case economy = "Economy"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @State private var feeMode: FeeMode = .fastest
    @State private var customSatsPerVb: String = "20"
    @State private var feeRecommended: FeeRecommended?
    @State private var sendState: BumpState = .idle
    /// Re-typed each signing for a host-entry hidden wallet; never stored.
    @State private var signingPassphrase: String = ""
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var status: String?

    enum BumpState {
        case idle
        case signing
        case signed(signedPSBTBase64: String, unsignedPSBTBase64: String)
        case broadcasting
        case done(txid: String)
        case failed(message: String, debugCode: String?)
    }

    private var boundDevice: RegisteredDevice? {
        guard let w = store.bitcoinWalletStore.activeWallet else { return nil }
        if case let .hardware(deviceId, _, _) = w.kind {
            return store.devices.find(id: deviceId)
        }
        return nil
    }

    private var signingMechanism: BitcoinSigningMechanism {
        guard let w = store.bitcoinWalletStore.activeWallet else { return .software }
        switch w.kind {
        case .software: return .software
        case .hardware(let deviceId, _, _):
            return store.devices.find(id: deviceId)?.kind.bitcoinSigningMechanism ?? .airgappedPSBT
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                originalSection
                newFeeSection
                if case let .failed(message, debugCode) = sendState {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message).foregroundStyle(.red).font(.callout)
                            if let debugCode {
                                Text("Debug code: \(debugCode)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let status {
                    Section { Text(status).foregroundStyle(.green).font(.callout) }
                }
                Section {
                    primaryActionButton
                    if case .failed = sendState {
                        Button(role: .destructive) { sendState = .idle } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Bump fee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadFees() }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    requiresPassphrase: store.bitcoinWalletStore.activeWallet?.hidden?.needsHostPassphrase == true,
                    onContinue: {
                        dismissSendViewKeyboard()
                        Task { await signOnly() }
                    },
                    onCancel: {},
                    onPassphrase: { signingPassphrase = $0 }
                )
            }
        }
    }

    // MARK: -- sections

    private var originalSection: some View {
        Section {
            LabeledContent("Replacing tx") {
                Text(shortTxid).font(.caption.monospaced())
            }
            if let sat = originalFeeSat {
                LabeledContent("Original fee") {
                    Text(formatSats(sat)).monospacedDigit()
                }
            }
        } header: {
            Text("Original transaction")
        } footer: {
            Text("BDK's BumpFee preserves the recipient and amount; only the fee changes. The replacement reuses the same UTXOs as the original (BIP-125 rule 4).")
                .font(.caption)
        }
    }

    private var newFeeSection: some View {
        Section {
            Picker("New fee", selection: $feeMode) {
                ForEach(FeeMode.allCases) { mode in
                    Text(modeLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if feeMode == .custom {
                HStack {
                    TextField("sats/vB", text: $customSatsPerVb)
                        .keyboardType(.numberPad)
                    Text("sats/vB").foregroundStyle(.secondary)
                }
            } else if let rate = recommendedRate(for: feeMode) {
                Text("Approximately \(rate) sats/vB at the current mempool snapshot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Replacement fee")
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch sendState {
        case .idle:
            Button {
                switch signingMechanism {
                case .software:    Task { await signOnly() }
                case .hardwareBLE:
                    if let op = makeHardwareReadyOp() {
                        pendingReadyOp = op
                    } else {
                        Task { await signOnly() }
                    }
                case .airgappedPSBT:
                    sendState = .failed(
                        message: "Air-gapped wallets can't bump fees from within Maknoon today; export the original PSBT and sign manually.",
                        debugCode: nil
                    )
                }
            } label: {
                Text(idleButtonLabel).frame(maxWidth: .infinity)
            }
            .disabled(effectiveSatsPerVb == 0)
        case .signing:
            HStack {
                ProgressView().controlSize(.small)
                Text(inProgressLabel).frame(maxWidth: .infinity)
            }
        case .signed:
            Button {
                Task { await broadcastSignedOnly() }
            } label: {
                Label("Broadcast replacement", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
                    .bold()
            }
            .buttonStyle(.borderedProminent)
        case .broadcasting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Broadcasting…").frame(maxWidth: .infinity)
            }
        case .done:
            EmptyView()
        case .failed:
            Button { Task { await signOnly() } } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .bold()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var idleButtonLabel: String {
        switch signingMechanism {
        case .software: return "Sign replacement"
        case .hardwareBLE:
            let name = boundDevice?.label ?? "device"
            return "Sign using Hardware Wallet, \(name)"
        case .airgappedPSBT: return "Bump unsupported for this wallet"
        }
    }

    private var inProgressLabel: String {
        switch signingMechanism {
        case .software:    return "Signing locally…"
        case .hardwareBLE:
            let name = boundDevice?.label ?? "device"
            return "Signing on \(name)…"
        case .airgappedPSBT: return ""
        }
    }

    private func makeHardwareReadyOp() -> PendingHardwareOperation? {
        guard let device = boundDevice,
              let descriptor = store.bitcoinWalletStore.activeWallet
        else { return nil }
        return PendingHardwareOperation(
            device: device,
            purpose: .bitcoinWallet(network: descriptor.network)
        )
    }

    // MARK: -- actions

    @MainActor
    private func signOnly() async {
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        sendState = .signing
        status = nil
        do {
            let unsignedB64 = try await wallet.buildBumpFeePSBT(
                originalTxidHex: originalTxidHex,
                newFeeRateSatsPerVb: effectiveSatsPerVb
            )
            let signedB64: String
            switch (signingMechanism, descriptor.kind) {
            case (.software, .software(let account)):
                guard let sandwich = store.sandwich else {
                    throw BitcoinWallet.WalletError.sandwichRequired
                }
                signedB64 = try BitcoinSigningHelpers.signSoftware(
                    unsignedBase64: unsignedB64,
                    sandwich: sandwich,
                    account: account,
                    network: descriptor.network
                )
            case (.hardwareBLE, .hardware(let deviceId, let fingerprintHex, let xpub)):
                guard let device = store.devices.find(id: deviceId) else {
                    throw BitcoinWallet.WalletError.sendFailed("Paired device not registered")
                }
                signedB64 = try await BitcoinSigningHelpers.signOverBLE(
                    unsignedBase64: unsignedB64,
                    device: device,
                    fingerprintHex: fingerprintHex,
                    accountXpub: xpub,
                    network: descriptor.network,
                    hidden: descriptor.hidden,
                    derivationPath: descriptor.derivationPath,
                    hostEntered: signingPassphrase
                )
            default:
                throw BitcoinWallet.WalletError.hardwareSigningNotImplemented
            }
            sendState = .signed(signedPSBTBase64: signedB64, unsignedPSBTBase64: unsignedB64)
        } catch {
            sendState = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Sign failed: \(error)",
                debugCode: BitcoinSigningHelpers.extractDebugCode(error)
            )
        }
    }

    @MainActor
    private func broadcastSignedOnly() async {
        guard case let .signed(signedB64, unsignedB64) = sendState else { return }
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        let url = store.bitcoinSettings.electrumURL(for: descriptor.network)
        sendState = .broadcasting
        do {
            let txid = try await wallet.importSignedPSBTAndBroadcast(
                signedPSBTBase64: signedB64,
                originalUnsignedBase64: unsignedB64,
                electrumURL: url
            )
            // Carry the original tx's label over to the replacement
            // so RBF does not silently strip the user's annotation.
            if let originalLabel = store.bitcoinLabels.label(
                forOutput: originalTxidHex, vout: 0
            ), !originalLabel.isEmpty {
                store.bitcoinLabels.setLabel(originalLabel, forOutput: txid, vout: 0)
            }
            sendState = .done(txid: txid)
            status = "Replaced. New txid \(txid.prefix(12))…"
            dismiss()
        } catch {
            sendState = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Broadcast failed: \(error)",
                debugCode: BitcoinSigningHelpers.extractDebugCode(error)
            )
        }
    }

    // MARK: -- helpers

    private var shortTxid: String {
        let s = originalTxidHex
        if s.count <= 16 { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }

    private var effectiveSatsPerVb: UInt64 {
        switch feeMode {
        case .custom: return UInt64(customSatsPerVb) ?? 0
        default:      return recommendedRate(for: feeMode) ?? 0
        }
    }

    private func recommendedRate(for mode: FeeMode) -> UInt64? {
        guard let rec = feeRecommended else { return nil }
        switch mode {
        case .fastest:  return rec.fastestFee
        case .halfHour: return rec.halfHourFee
        case .hour:     return rec.hourFee
        case .economy:  return rec.economyFee
        case .custom:   return nil
        }
    }

    private func modeLabel(_ mode: FeeMode) -> String {
        if let rate = recommendedRate(for: mode) {
            return "\(mode.rawValue) (\(rate) sats/vB)"
        }
        return mode.rawValue
    }

    @MainActor
    private func loadFees() async {
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        let base = store.bitcoinSettings.mempoolURL(for: descriptor.network)
        if let live = try? await BitcoinFeeEstimator.fetch(baseURL: base) {
            feeRecommended = live
        } else {
            feeRecommended = BitcoinFeeEstimator.fallback
        }
    }

    private func formatSats(_ sat: Int64) -> String {
        let btc = Double(sat) / 100_000_000
        return String(format: "%.8f BTC", btc)
    }
}
