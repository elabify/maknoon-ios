// Sweep the holder's seed for Tron accounts with on-chain activity.
// Mirrors `DiscoverSolanaWalletsView`. One biometric prompt; gap-
// limit walks accounts 0, 1, 2, ... until 4 consecutive empty
// accounts; results section with skip lines for dedup.

import SwiftUI
import WalletCore

struct DiscoverTronWalletsView: View {
    /// Software (sandwich seed) or hardware (per-account device call).
    /// Mirrors `DiscoverSolanaWalletsView.Source`.
    enum Source: Identifiable {
        case software
        case hardware(deviceId: UUID)
        var id: String {
            switch self {
            case .software: return "software"
            case .hardware(let id): return "hardware:\(id.uuidString)"
            }
        }
    }

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let network: TronNetwork
    var source: Source = .software
    var onCompleted: (() -> Void)? = nil

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [Hit] = []
    @State private var selection: Set<UInt32> = []
    @State private var error: String?
    @State private var addReport: [String]?

    struct Hit: Hashable, Identifiable {
        let account: UInt32
        let address: String
        let sun: Int64
        let txCount: Int
        var id: UInt32 { account }
        var hasActivity: Bool { sun > 0 || txCount > 0 }
    }

    static let emptyAccountGapLimit = 4

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: network.displayName)
            } header: {
                Text("Scanning")
            } footer: {
                Text("Walks BIP44 accounts on \(network.displayName) under your Identity Sandwich seed until \(Self.emptyAccountGapLimit) consecutive empty accounts are found. Reads the seed once, then queries TronGrid for balance + recent activity per account.")
                    .font(.caption)
            }

            if !scanning && discovered.isEmpty && progress.isEmpty {
                Section {
                    Button {
                        Task { await runScan() }
                    } label: {
                        Label("Start scan", systemImage: "magnifyingglass")
                    }
                    .disabled(store.sandwich == nil)
                } footer: {
                    Text("Requires biometric or passcode once.")
                        .font(.caption)
                }
            }

            if scanning || !progress.isEmpty {
                Section("Progress") {
                    if scanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(progress.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }

            if !discovered.isEmpty {
                Section {
                    ForEach(discovered) { hit in
                        Toggle(isOn: Binding(
                            get: { selection.contains(hit.account) },
                            set: { include in
                                if include { selection.insert(hit.account) }
                                else { selection.remove(hit.account) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Account \(hit.account)").font(.callout.weight(.semibold))
                                Text(shorten(hit.address))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(detailLine(hit)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Found activity")
                } footer: {
                    Text("Pre-selected the accounts with activity. Existing wallets at the same account index are skipped automatically.")
                        .font(.caption)
                }
                Section {
                    Button("Add selected wallets") { addSelected() }
                        .disabled(selection.isEmpty)
                }
            }

            if let addReport, !addReport.isEmpty {
                Section {
                    ForEach(Array(addReport.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption)
                    }
                    Button("Done") {
                        dismiss()
                        onCompleted?()
                    }
                } header: {
                    Text("Results")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Discover Tron wallets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(scanning ? "Hide" : "Close") { dismiss() }
            }
        }
    }

    private func shorten(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    private func detailLine(_ hit: Hit) -> String {
        let trx = Double(hit.sun) / 1_000_000.0
        return String(format: "%.6f TRX · %d recent tx", trx, hit.txCount)
    }

    @MainActor
    private func runScan() async {
        let rpcURL = store.tronSettings.rpcURL(for: network)
        guard let rpc = TronRPCClient(baseString: rpcURL) else {
            self.error = "Tron RPC URL is malformed: \(rpcURL)"
            return
        }
        // Resolve the derivation source up front.
        let hardwareClient: HardwareWallet?
        var hdWallet: WalletCore.HDWallet?
        switch source {
        case .software:
            guard let sandwich = store.sandwich else {
                error = "Identity Sandwich is locked. Unlock with your hardware device first."
                return
            }
            let material: MasterRecoveryMaterial
            do {
                material = try sandwich.recoveryMaterial(localizedReason: "Discover Tron wallets on this seed")
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return
            }
            let words = material.words.joined(separator: " ")
            let pass = material.hasPassphrase ? material.passphrase : ""
            guard let hd = WalletCore.HDWallet(mnemonic: words, passphrase: pass) else {
                self.error = "HDWallet derivation failed."
                return
            }
            hdWallet = hd
            hardwareClient = nil
        case .hardware(let deviceId):
            guard let dev = store.devices.find(id: deviceId) else {
                error = "Hardware device record missing. Re-register the device in Settings → Devices."
                return
            }
            let kind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
            hardwareClient = HardwareWalletFactory.make(kind: kind)
            hardwareClient?.beginSession()
        }

        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil
        addReport = nil
        defer {
            scanning = false
            hardwareClient?.endSession()
        }

        var hits: [Hit] = []
        var account: UInt32 = 0
        var consecutiveEmpty = 0
        while consecutiveEmpty < Self.emptyAccountGapLimit {
            progress.append("Account \(account): scanning…")
            let addr: String
            do {
                switch source {
                case .software:
                    let path = TronDescriptors.derivationPath(account: account)
                    let priv = hdWallet!.getKeyByCurve(curve: .secp256k1, derivationPath: path)
                    addr = WalletCore.CoinType.tron.deriveAddress(privateKey: priv)
                case .hardware:
                    addr = try await hardwareClient!.getTronAddress(account: account)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                progress.append("Account \(account): \(msg)")
                consecutiveEmpty += 1
                account += 1
                continue
            }
            do {
                let sun = try await rpc.getBalance(addressBase58: addr)
                let txs = (try? await rpc.getTransactionsByAddress(addressBase58: addr, limit: 1)) ?? []
                let hit = Hit(account: account, address: addr, sun: sun, txCount: txs.count)
                if hit.hasActivity {
                    hits.append(hit)
                    consecutiveEmpty = 0
                    let trx = Double(sun) / 1_000_000.0
                    progress.append(String(format: "Account %d: %.6f TRX, active", account, trx))
                } else {
                    consecutiveEmpty += 1
                    progress.append("Account \(account): empty")
                }
            } catch {
                consecutiveEmpty += 1
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                progress.append("Account \(account): \(msg)")
            }
            account += 1
        }
        discovered = hits
        let existing = existingAccountIndices()
        for hit in hits where !existing.contains(hit.account) {
            selection.insert(hit.account)
        }
        progress.append("Stopped after \(Self.emptyAccountGapLimit) consecutive empty accounts.")
    }

    private func existingAccountIndices() -> Set<UInt32> {
        switch source {
        case .software:
            return Set(store.tronWalletStore.wallets.compactMap { w in
                if case let .software(a) = w.kind { return a }
                return nil
            })
        case .hardware(let deviceId):
            return Set(store.tronWalletStore.wallets.compactMap { w in
                if case let .hardware(d, a, _) = w.kind, d == deviceId { return a }
                return nil
            })
        }
    }

    @MainActor
    private func addSelected() {
        var report: [String] = []
        for hit in discovered where selection.contains(hit.account) {
            let kind: TronWalletKind
            let labelPrefix: String
            let dedupHit: TronWalletDescriptor?
            switch source {
            case .software:
                kind = .software(account: hit.account)
                labelPrefix = "Tron Wallet"
                dedupHit = store.tronWalletStore.wallets.first(where: {
                    if case let .software(a) = $0.kind { return a == hit.account }
                    return false
                })
            case .hardware(let deviceId):
                kind = .hardware(
                    deviceId: deviceId,
                    account: hit.account,
                    addressBase58Check: hit.address
                )
                let devLabel = store.devices.find(id: deviceId)?.label ?? "Hardware"
                labelPrefix = "\(devLabel)"
                dedupHit = store.tronWalletStore.wallets.first(where: {
                    if case let .hardware(d, a, _) = $0.kind { return d == deviceId && a == hit.account }
                    return false
                })
            }
            if let existing = dedupHit {
                report.append("Account \(hit.account), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            let label = "\(labelPrefix) #\(hit.account)"
            let descriptor = TronWalletDescriptor(label: label, kind: kind)
            store.tronWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
            if case .hardware(let deviceId) = source {
                store.devices.addTronWallet(deviceId: deviceId, walletId: descriptor.id)
            }
            report.append("Account \(hit.account) added as \"\(label)\".")
        }
        addReport = report
    }
}
