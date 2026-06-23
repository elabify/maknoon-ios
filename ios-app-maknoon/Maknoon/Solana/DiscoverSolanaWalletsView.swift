// Solana equivalent of DiscoverEthereumWalletsView and the Bitcoin
// DiscoverWalletsSheet. Walks the holder's seed for accounts that
// already have on-chain activity on the chosen cluster, lets the user
// pre-add the ones they want.
//
// One biometric prompt for the whole sweep (the seed is read once at
// the start). The cluster is passed in by the parent so the user is
// scanning whichever network "Open on" was set to in the Add sheet.

import SwiftUI

struct DiscoverSolanaWalletsView: View {
    /// Software (sandwich seed) or hardware (device-derived per
    /// account). Mirrors `DiscoverEthereumWalletsView.Source`.
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
    /// Cluster to scan. Passed from AddSolanaWalletSheet's "Open on"
    /// picker so the user is scanning whichever network they intend
    /// to land the discovered wallets on.
    let network: SolanaNetwork
    /// Defaults to .software for back-compat with existing callers.
    /// AddSolanaWalletSheet's Hardware tab passes .hardware(deviceId:).
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
    /// Fired after the discover sheet finishes adding wallets, so the
    /// parent can refresh + dismiss its own sheet.
    var onCompleted: (() -> Void)? = nil

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [SolanaWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    /// Per-account add/skip lines shown in the Results section.
    @State private var addReport: [String]?
    /// Hardware-only: also sweep well-known alternative derivation paths
    /// (Ledger Live, …) for each account.
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: network.displayName)
            } header: {
                Text("Scanning")
            } footer: {
                Text("Walks accounts 0, 1, 2, ... \(isHardwareSource ? "on this device" : "under your recovery phrase") on \(network.displayName) until \(SolanaWalletDiscovery.emptyAccountGapLimit) consecutive empty accounts are found, then queries the configured RPC for balance + signatures per account.")
                    .font(.caption)
            }

            if isHardwareSource && !scanning && discovered.isEmpty && progress.isEmpty {
                Section {
                    Toggle("Try alternative derivation paths", isOn: $alsoTryAltPaths)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Also checks well-known non-standard paths (e.g. Ledger Live's m/44'/501'/N') so a wallet created in another app is found.")
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
                    ForEach(discovered) { acct in
                        Toggle(isOn: Binding(
                            get: { selection.contains(acct.id) },
                            set: { include in
                                if include { selection.insert(acct.id) }
                                else { selection.remove(acct.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Account \(acct.account)").font(.callout.weight(.semibold))
                                Text(shorten(acct.address))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(detailLine(acct))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
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
                    Button("Add selected wallets") {
                        addSelected()
                    }
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
        .navigationTitle("Discover Solana wallets")
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

    private func detailLine(_ acct: SolanaWalletDiscovery.DiscoveredAccount) -> String {
        let sol = Double(acct.lamports) / 1_000_000_000.0
        let bal = String(format: "%.6f SOL", sol)
        var s = "\(bal) · \(acct.signatureCount) recent tx"
        if let path = acct.derivationPath { s += " · \(path)" }
        return s
    }

    // MARK: -- scan

    @MainActor
    private func runScan() async {
        // Resolve the discovery source. Software needs the sandwich;
        // hardware needs the registered device + a live HardwareWallet
        // client that can derive addresses on demand.
        let discoverySource: SolanaWalletDiscovery.Source
        switch source {
        case .software:
            guard let sandwich = store.sandwich else {
                error = "Maknoon is locked. Unlock with your hardware device first."
                return
            }
            discoverySource = .software(sandwich: sandwich)
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
            discoverySource = .hardware(client: client)
        }

        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil
        addReport = nil
        defer { scanning = false }

        // A fresh hidden wallet has no on-chain activity, so the sweep
        // would surface nothing; keep account 0 so it can still be added.
        let keepEmptyFirst = isTrezorSource && passphrase != .standard
        let rpcURL = store.solanaSettings.rpcURL(for: network)
        do {
            let templates = (isHardwareSource && alsoTryAltPaths)
                ? BIP32Path.alternativeTemplates(.solana)
                : nil
            let hits = try await SolanaWalletDiscovery.scan(
                source: discoverySource,
                network: network,
                rpcURL: rpcURL,
                includeFirstAccountAlways: keepEmptyFirst,
                pathTemplates: templates,
                onProgress: { p in
                    let line: String
                    switch p.phase {
                    case .scanning:
                        line = "Account \(p.account): scanning…"
                    case .completed(let active, let lamports):
                        let sol = Double(lamports) / 1_000_000_000.0
                        line = active
                            ? String(format: "Account %d: %.6f SOL, active", p.account, sol)
                            : "Account \(p.account): empty"
                    case .failed(let m):
                        line = "Account \(p.account): \(m)"
                    }
                    progress.append(line)
                }
            )
            discovered = hits
            // Pre-select any account not already added. Software dedupes
            // by account index; hardware dedupes by ADDRESS, so a hidden
            // wallet's distinct address at the same index is not hidden
            // behind the standard wallet.
            for hit in hits where !alreadyAdded(hit) {
                selection.insert(hit.id)
            }
            progress.append("Stopped after \(SolanaWalletDiscovery.emptyAccountGapLimit) consecutive empty accounts.")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Whether a discovered account is already registered as a wallet of
    /// the matching source kind (by account for software, by address for
    /// hardware).
    private func alreadyAdded(_ hit: SolanaWalletDiscovery.DiscoveredAccount) -> Bool {
        switch source {
        case .software:
            return store.solanaWalletStore.wallets.contains { w in
                if case let .software(a) = w.kind { return a == hit.account }
                return false
            }
        case .hardware(let deviceId):
            return store.solanaWalletStore.wallets.contains { w in
                if case let .hardware(d, _, pk) = w.kind { return d == deviceId && pk == hit.address }
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
        for acct in discovered where selection.contains(acct.id) {
            let kind: SolanaWalletKind
            let labelPrefix: String
            let dedupHit: SolanaWalletDescriptor?
            switch source {
            case .software:
                kind = .software(account: acct.account)
                labelPrefix = "Solana Wallet"
                dedupHit = store.solanaWalletStore.wallets.first(where: { w in
                    if case let .software(a) = w.kind { return a == acct.account }
                    return false
                })
            case .hardware(let deviceId):
                // For Solana the address IS the 32-byte Ed25519 pubkey
                // in base58, so the discovered account.address can
                // double as publicKeyBase58 on the descriptor.
                kind = .hardware(
                    deviceId: deviceId,
                    account: acct.account,
                    publicKeyBase58: acct.address
                )
                let devLabel = store.devices.find(id: deviceId)?.label ?? "Hardware"
                labelPrefix = "\(devLabel)"
                // Dedup by address: a hidden wallet shares the account
                // index but derives a distinct address.
                dedupHit = store.solanaWalletStore.wallets.first(where: { w in
                    if case let .hardware(d, _, pk) = w.kind { return d == deviceId && pk == acct.address }
                    return false
                })
            }
            if let existing = dedupHit {
                report.append("Account \(acct.account), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            // Relink-by-key (ADR-0033): re-point an ORPHANED wallet with the same
            // public key (its stored deviceId no longer resolves) instead of
            // adding a duplicate.
            if case .hardware(let deviceId) = source,
               let orphan = store.solanaWalletStore.wallets.first(where: { w in
                   if case let .hardware(d, _, pk) = w.kind {
                       return pk == acct.address && store.devices.find(id: d) == nil
                   }
                   return false
               }) {
                store.solanaWalletStore.relink(walletId: orphan.id, toDeviceId: deviceId)
                store.devices.addSolanaWallet(deviceId: deviceId, walletId: orphan.id)
                report.append("Account \(acct.account) re-linked to existing \"\(orphan.label)\".")
                continue
            }
            let pathSuffix = acct.derivationPath != nil ? " (Custom path)" : ""
            let label = "\(labelPrefix) #\(acct.account)\(suffix)\(pathSuffix)"
            let descriptor = SolanaWalletDescriptor(
                label: label, kind: kind, hidden: hidden, derivationPath: acct.derivationPath
            )
            store.solanaWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
            if case .hardware(let deviceId) = source {
                store.devices.addSolanaWallet(deviceId: deviceId, walletId: descriptor.id)
            }
            report.append("Account \(acct.account) added as \"\(label)\".")
        }
        addReport = report
    }
}
