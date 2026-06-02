// Pair a SeedSigner by importing the account it exports.
//
// SeedSigner has no live transport, so "pairing" is just reading
// the descriptor or cosigner block it prints on screen. The user
// taps "Scan QR" and points the phone at the SeedSigner, or pastes
// the text manually if scanning fails.
//
// We extract the master fingerprint, the BIP44 derivation path,
// and the account-level xpub. The fingerprint becomes the device's
// stable serial in DeviceRegistry; the xpub builds a watch-only
// Bitcoin wallet. Both happen in one step so the user doesn't have
// to repeat the scan to add their first wallet.

import SwiftUI

struct SeedSignerPairingSheet: View {
    let onDone: (RegisteredDevice?) -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case scan = "Scan QR"
        case paste = "Paste text"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .scan
    @State private var pastedText: String = ""
    @State private var parsed: SeedSignerAccount?
    @State private var label: String = "SeedSigner"
    @State private var network: BitcoinNetwork = .mainnet
    @State private var lastError: String?
    @State private var working: Bool = false
    @State private var showingScanner: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                introSection
                if parsed == nil {
                    importSection
                } else {
                    summarySection
                    confirmSection
                }
                if let lastError {
                    Section { Text(lastError).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Add SeedSigner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onDone(nil)
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ZStack {
                    QRScannerView(onCode: handleScannedString)
                    VStack {
                        Spacer()
                        Button("Cancel") { showingScanner = false }
                            .buttonStyle(.borderedProminent)
                            .padding(.bottom, 32)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: -- sections

    private var introSection: some View {
        Section {
            Text("On the SeedSigner: Seeds → Select your seed → Export Xpub → Single Sig → Native Segwit → BlueWallet → I Understand → Export Xpub. Scan the static QR it shows, or paste the text exported alongside it. Sparrow and Specter exports work via paste but emit animated multi-frame QR that Maknoon's single-frame scanner can't assemble yet.")
                .font(.callout)
        } header: {
            Text("How to pair")
        }
    }

    private var importSection: some View {
        Section {
            Picker("How", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .scan:
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .paste:
                TextEditor(text: $pastedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                Button {
                    parse(pastedText)
                } label: {
                    Label("Parse", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Account export")
        } footer: {
            Text("If you have the descriptor (wpkh([…]xpub…/0/*)), paste it. SeedSigner's \"Sparrow QR\" export works directly.")
                .font(.caption)
        }
    }

    private var summarySection: some View {
        Section {
            row("Master fingerprint", parsed?.masterFingerprintHex.uppercased() ?? "")
            row("Derivation path", parsed?.derivationPath ?? "")
            row("xpub", parsed?.xpub ?? "", small: true)
        } header: {
            Text("Detected account")
        }
    }

    private var confirmSection: some View {
        Section {
            TextField("Label", text: $label)
            Picker("Network", selection: $network) {
                ForEach(BitcoinNetwork.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Button {
                Task { await register() }
            } label: {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Text(working ? "Adding…" : "Add SeedSigner and create wallet")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
        } header: {
            Text("Confirm")
        } footer: {
            Text("Maknoon stores only the xpub and the fingerprint. The private keys never leave your SeedSigner.")
                .font(.caption)
        }
    }

    private func row(_ label: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(small ? .caption2 : .caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(small ? 4 : 1)
        }
    }

    // MARK: -- parse + register

    private func handleScannedString(_ s: String) {
        showingScanner = false
        parse(s)
    }

    private func parse(_ raw: String) {
        do {
            let account = try SeedSignerAccount.parse(raw)
            parsed = account
            lastError = nil
            // Infer network from coin type in the derivation path:
            // 0 = mainnet, 1 = testnet/signet/regtest.
            if account.derivationPath.contains("/1'/") || account.derivationPath.contains("/1h/") {
                network = .signet
            } else {
                network = .mainnet
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @MainActor
    private func register() async {
        guard let account = parsed else { return }
        working = true
        defer { working = false }
        do {
            let device = store.devices.register(
                kind: .seedsigner,
                serial: account.masterFingerprintHex,
                label: label.trimmingCharacters(in: .whitespaces).isEmpty ? "SeedSigner" : label
            )
            let wallet = BitcoinWalletDescriptor(
                label: "\(device.label) \(network.displayName)",
                kind: .hardware(
                    deviceId: device.id,
                    accountFingerprint: account.masterFingerprintHex,
                    accountXpub: account.xpub
                ),
                network: network
            )
            store.bitcoinWalletStore.add(wallet, makeActive: false)
            store.devices.addBitcoinWallet(deviceId: device.id, walletId: wallet.id)
            onDone(device)
            dismiss()
        }
    }
}
