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
        var isSoftware: Bool { if case .software = self { return true }; return false }
    }

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let network: TronNetwork
    var source: Source = .software
    /// Trezor hidden-wallet choice, collected upstream in the connection
    /// step (DeviceReadyConfirmationSheet) on the hardware path. The one
    /// choice applies to both add and discover (ADR-0033). Passed as a
    /// BINDING so the scan reads the LIVE committed value: the readiness
    /// sheet sets it just before this sheet opens, and a plain snapshot
    /// could capture the pre-selection `.standard` during the two-sheet
    /// handoff (the bug that left the Trezor passphrase unsent). Software /
    /// Ledger pass `.constant(.standard)` / `.constant("")`.
    @Binding var passphrase: HiddenWalletSelection
    /// Host-typed passphrase that pairs with `passphrase == .hostTyped`.
    @Binding var hostPassphrase: String
    var onCompleted: (() -> Void)? = nil

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [Hit] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var addReport: [String]?
    /// Hardware-only: also sweep well-known alternative derivation paths.
    @State private var alsoTryAltPaths: Bool = false

    /// Hidden wallets are a Trezor-only feature; the selector is gated
    /// to Trezor hardware sources.
    private var isTrezorSource: Bool {
        if case .hardware(let id) = source {
            return store.devices.find(id: id)?.kind == .trezor
        }
        return false
    }

    private var isHardwareSource: Bool {
        if case .hardware = source { return true }
        return false
    }

    struct Hit: Hashable, Identifiable {
        let account: UInt32
        let address: String
        let sun: Int64
        let txCount: Int
        /// Non-standard path this was derived at, when sweeping
        /// alternatives; nil for the standard path.
        var derivationPath: String?
        var id: String { "\(account):\(derivationPath ?? "std")" }
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
                Text("Walks BIP44 accounts on \(network.displayName) under your recovery phrase until \(Self.emptyAccountGapLimit) consecutive empty accounts are found. Reads the seed once, then queries TronGrid for balance + recent activity per account.")
                    .font(.caption)
            }

            if isHardwareSource && !scanning && discovered.isEmpty && progress.isEmpty {
                Section {
                    Toggle("Try alternative derivation paths", isOn: $alsoTryAltPaths)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Also checks well-known non-standard paths (Ledger, TIP-01, …) so a wallet created in another app is found.")
                        .font(.caption)
                }
            }

            if !scanning && discovered.isEmpty && progress.isEmpty {
                Section {
                    Button {
                        Task { await runScan() }
                    } label: {
                        Label("Start scan", systemImage: "magnifyingglass")
                    }
                    .disabled((source.isSoftware && store.sandwich == nil)
                        || !passphrase.isReady(hostPassphrase: hostPassphrase))
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
                            get: { selection.contains(hit.id) },
                            set: { include in
                                if include { selection.insert(hit.id) }
                                else { selection.remove(hit.id) }
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
        var s = String(format: "%.6f TRX · %d recent tx", trx, hit.txCount)
        if let path = hit.derivationPath { s += " · \(path)" }
        return s
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
                error = "Software wallets derive from your master seed and need your identity unlocked. Unlock from the Identity tab, or switch the Source to Hardware."
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
            let client = HardwareWalletFactory.make(kind: kind)
            // A Trezor hidden wallet derives in its own passphrase
            // session. Ledger / mock clients ignore this.
            if let trezor = client as? TrezorBLE {
                trezor.applyPassphraseMode(passphrase.choice(hostPassphrase: hostPassphrase))
            }
            client.beginSession()
            hardwareClient = client
        }
        // A fresh hidden wallet has no activity to find, so keep account
        // 0 in the results when a passphrase is in play.
        let keepEmptyFirst = isTrezorSource && passphrase != .standard

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

        // Standard path only (nil marker), or each alternative template
        // per account. An account counts as empty for the gap limit only
        // when no template had activity.
        let templateList: [String?] = (isHardwareSource && alsoTryAltPaths)
            ? BIP32Path.alternativeTemplates(.tron).map { Optional($0) }
            : [nil]

        var hits: [Hit] = []
        // Dedup by address: alternative templates can collide on a path
        // (or a device may ignore the override), so each address yields
        // one selectable row.
        var seenAddresses = Set<String>()
        // Dedup resolved paths: some templates fill to the SAME path at a
        // given account (e.g. Tron's standard and the SDK variant both
        // give m/44'/195'/0'/0/0 at account 0), so we never derive or
        // show the same path twice.
        var seenPaths = Set<String>()
        var firstEntry: Hit?
        var account: UInt32 = 0
        var consecutiveEmpty = 0
        while consecutiveEmpty < Self.emptyAccountGapLimit {
            progress.append("Account \(account): scanning…")
            var accountHadActivity = false
            for tmpl in templateList {
                let pathOverride = tmpl.map { BIP32Path.fill($0, account: account) }
                guard seenPaths.insert(pathOverride ?? "std").inserted else { continue }
                let addr: String
                do {
                    switch source {
                    case .software:
                        let path = pathOverride ?? TronDescriptors.derivationPath(account: account)
                        let priv = hdWallet!.getKeyByCurve(curve: .secp256k1, derivationPath: path)
                        addr = WalletCore.CoinType.tron.deriveAddress(privateKey: priv)
                    case .hardware:
                        hardwareClient!.setDerivationPathOverride(pathOverride)
                        addr = try await hardwareClient!.getTronAddress(account: account)
                    }
                } catch {
                    // A device may forbid a foreign path (Trezor rejects
                    // non-standard Tron paths). Skip it; not a failure.
                    let what = pathOverride ?? "standard path"
                    progress.append("Account \(account): \(what) not supported, skipped")
                    continue
                }
                do {
                    let sun = try await rpc.getBalance(addressBase58: addr)
                    let txs = (try? await rpc.getTransactionsByAddress(addressBase58: addr, limit: 1)) ?? []
                    let hit = Hit(account: account, address: addr, sun: sun, txCount: txs.count, derivationPath: pathOverride)
                    if account == 0, firstEntry == nil { firstEntry = hit }
                    if hit.hasActivity {
                        accountHadActivity = true
                        if seenAddresses.insert(addr).inserted {
                            hits.append(hit)
                        }
                        let trx = Double(sun) / 1_000_000.0
                        progress.append(String(format: "Account %d: %.6f TRX, active", account, trx))
                    } else {
                        progress.append("Account \(account): empty")
                    }
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    progress.append("Account \(account): \(msg)")
                }
            }
            if accountHadActivity { consecutiveEmpty = 0 } else { consecutiveEmpty += 1 }
            account += 1
        }
        hardwareClient?.setDerivationPathOverride(nil)
        if keepEmptyFirst, hits.isEmpty, let first = firstEntry {
            hits.append(first)
        }
        discovered = hits
        for hit in hits where !alreadyAdded(hit) {
            selection.insert(hit.id)
        }
        progress.append("Stopped after \(Self.emptyAccountGapLimit) consecutive empty accounts.")
    }

    /// Whether a discovered account is already registered (by account
    /// for software, by ADDRESS for hardware, so a hidden wallet's
    /// distinct address at the same index is not hidden behind the
    /// standard wallet).
    private func alreadyAdded(_ hit: Hit) -> Bool {
        switch source {
        case .software:
            return store.tronWalletStore.wallets.contains { w in
                if case let .software(a) = w.kind { return a == hit.account }
                return false
            }
        case .hardware(let deviceId):
            return store.tronWalletStore.wallets.contains { w in
                if case let .hardware(d, _, addr) = w.kind { return d == deviceId && addr == hit.address }
                return false
            }
        }
    }

    @MainActor
    private func addSelected() {
        var report: [String] = []
        // Persist the hidden-wallet binding once for this sweep (writes
        // a host-typed passphrase to the Keychain). nil for software and
        // for every Ledger / standard sweep.
        let hidden = isTrezorSource
            ? HardwarePassphraseRef.persist(selection: passphrase)
            : nil
        let suffix = hidden == nil ? "" : " (Hidden)"
        for hit in discovered where selection.contains(hit.id) {
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
                // Dedup by address: a hidden wallet shares the account
                // index but derives a distinct address.
                dedupHit = store.tronWalletStore.wallets.first(where: {
                    if case let .hardware(d, _, addr) = $0.kind { return d == deviceId && addr == hit.address }
                    return false
                })
            }
            if let existing = dedupHit {
                report.append("Account \(hit.account), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            // Relink-by-key (ADR-0033): re-point an ORPHANED wallet with the same
            // address (its stored deviceId no longer resolves) instead of adding
            // a duplicate.
            if case .hardware(let deviceId) = source,
               let orphan = store.tronWalletStore.wallets.first(where: { w in
                   if case let .hardware(d, _, addr) = w.kind {
                       return addr == hit.address && store.devices.find(id: d) == nil
                   }
                   return false
               }) {
                store.tronWalletStore.relink(walletId: orphan.id, toDeviceId: deviceId)
                store.devices.addTronWallet(deviceId: deviceId, walletId: orphan.id)
                report.append("Account \(hit.account) re-linked to existing \"\(orphan.label)\".")
                continue
            }
            let pathSuffix = hit.derivationPath != nil ? " (Custom path)" : ""
            let label = "\(labelPrefix) #\(hit.account)\(suffix)\(pathSuffix)"
            let descriptor = TronWalletDescriptor(
                label: label, kind: kind, hidden: hidden, derivationPath: hit.derivationPath
            )
            store.tronWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
            if case .hardware(let deviceId) = source {
                store.devices.addTronWallet(deviceId: deviceId, walletId: descriptor.id)
            }
            report.append("Account \(hit.account) added as \"\(label)\".")
        }
        addReport = report
    }
}
