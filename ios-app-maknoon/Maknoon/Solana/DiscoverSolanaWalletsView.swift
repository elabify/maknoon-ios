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
    /// Fired after the discover sheet finishes adding wallets, so the
    /// parent can refresh + dismiss its own sheet.
    var onCompleted: (() -> Void)? = nil

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [SolanaWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<UInt32> = []
    @State private var error: String?
    /// Per-account add/skip lines shown in the Results section.
    @State private var addReport: [String]?

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: network.displayName)
            } header: {
                Text("Scanning")
            } footer: {
                Text("Walks accounts 0, 1, 2, ... under your Identity Sandwich seed on \(network.displayName) until \(SolanaWalletDiscovery.emptyAccountGapLimit) consecutive empty accounts are found. Reads the seed once, then queries the configured RPC for balance + signatures per account.")
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
                    ForEach(discovered) { acct in
                        Toggle(isOn: Binding(
                            get: { selection.contains(acct.account) },
                            set: { include in
                                if include { selection.insert(acct.account) }
                                else { selection.remove(acct.account) }
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
        return "\(bal) · \(acct.signatureCount) recent tx"
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
                error = "Identity Sandwich is locked. Unlock with your hardware device first."
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
            discoverySource = .hardware(client: client)
        }

        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil
        addReport = nil
        defer { scanning = false }

        let rpcURL = store.solanaSettings.rpcURL(for: network)
        do {
            let hits = try await SolanaWalletDiscovery.scan(
                source: discoverySource,
                network: network,
                rpcURL: rpcURL,
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
            // Pre-select any account that doesn't already exist as a
            // wallet of the matching kind. For hardware discover we
            // dedupe against existing hardware wallets at the same
            // (deviceId, account); for software, against software
            // wallets at the same account.
            let existing = existingAccountIndices()
            for hit in hits where !existing.contains(hit.account) {
                selection.insert(hit.account)
            }
            progress.append("Stopped after \(SolanaWalletDiscovery.emptyAccountGapLimit) consecutive empty accounts.")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Account indices already registered as wallets of the matching
    /// source kind. Used to pre-select only the truly new ones.
    private func existingAccountIndices() -> Set<UInt32> {
        switch source {
        case .software:
            return Set(store.solanaWalletStore.wallets.compactMap { w in
                if case let .software(a) = w.kind { return a }
                return nil
            })
        case .hardware(let deviceId):
            return Set(store.solanaWalletStore.wallets.compactMap { w in
                if case let .hardware(d, a, _) = w.kind, d == deviceId { return a }
                return nil
            })
        }
    }

    @MainActor
    private func addSelected() {
        var report: [String] = []
        for acct in discovered where selection.contains(acct.account) {
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
                dedupHit = store.solanaWalletStore.wallets.first(where: { w in
                    if case let .hardware(d, a, _) = w.kind { return d == deviceId && a == acct.account }
                    return false
                })
            }
            if let existing = dedupHit {
                report.append("Account \(acct.account), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            let label = "\(labelPrefix) #\(acct.account)"
            let descriptor = SolanaWalletDescriptor(label: label, kind: kind)
            store.solanaWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
            if case .hardware(let deviceId) = source {
                store.devices.addSolanaWallet(deviceId: deviceId, walletId: descriptor.id)
            }
            report.append("Account \(acct.account) added as \"\(label)\".")
        }
        addReport = report
    }
}
