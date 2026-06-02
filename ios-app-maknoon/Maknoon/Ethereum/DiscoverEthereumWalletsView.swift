// Sweep BIP44 accounts 0..N on either the holder's seed or a paired
// hardware device, find the ones that have on-chain activity on the
// selected network, let the user check which to add to the wallet
// list. Mirrors the Bitcoin equivalent.
//
// Software sweeps consume one biometric prompt and derive every
// candidate address in-process from the BIP39 seed. Hardware sweeps
// drive the device's GET_PUBLIC_KEY APDU per account (no on-device
// confirmation needed because display_flag=0); the device must be
// awake on the Ethereum app for the duration.

import SwiftUI

struct DiscoverEthereumWalletsView: View {
    enum Source: Identifiable {
        case software
        case hardware(deviceId: UUID)
        var id: String {
            switch self {
            case .software:                  return "software"
            case .hardware(let id):          return "hw:\(id.uuidString)"
            }
        }
    }

    let source: Source
    let network: EthereumNetwork
    var onCompleted: (() -> Void)? = nil

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [EthereumWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    /// Populated when Start Scan is tapped against a hardware source.
    /// Drives the pre-tap readiness sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?
    /// Per-account report shown after Add Selected runs. Each
    /// discovered account either gets an "added" line or a "skipped,
    /// already labelled X" line.
    @State private var addReport: [String]?

    private var sourceLabel: String {
        switch source {
        case .software: return "your Identity Sandwich seed"
        case .hardware(let id):
            return store.devices.find(id: id)?.label ?? "the hardware device"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "diamond.fill")
                            .foregroundStyle(Color.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Discover on \(network.displayName)")
                                .font(.callout.weight(.semibold))
                            Text("From \(sourceLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Walks accounts 0 through 4 and checks each address for on-chain activity. Active accounts get pre-selected so you can add them in one tap.")
                        .font(.caption)
                }

                if !scanning && discovered.isEmpty && progress.isEmpty {
                    Section {
                        Button {
                            if case .hardware(let id) = source,
                               let dev = store.devices.find(id: id),
                               HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                                pendingReadyOp = PendingHardwareOperation(
                                    device: dev,
                                    purpose: .ethereumDiscover
                                )
                            } else {
                                Task { await runScan() }
                            }
                        } label: {
                            Label("Start scan", systemImage: "magnifyingglass")
                        }
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
                                    if include { selection.insert(acct.id) } else { selection.remove(acct.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Account \(acct.account)").font(.callout.weight(.semibold))
                                    Text(shorten(acct.address))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(detailLine(acct)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Text("Found activity")
                    } footer: {
                        Text("Pre-selected the accounts with activity. Existing wallets are skipped automatically.")
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

                if !scanning && !progress.isEmpty && discovered.isEmpty {
                    Section {
                        Text("No active accounts found in the first 5 indices.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(scanning ? "Hide" : "Close") { dismiss() }
                }
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: { Task { await runScan() } },
                    onCancel: {}
                )
            }
        }
    }

    private func detailLine(_ acct: EthereumWalletDiscovery.DiscoveredAccount) -> String {
        var parts: [String] = []
        if acct.hasBalance { parts.append("has balance") }
        if acct.txCount > 0 { parts.append("has tx history") }
        return parts.joined(separator: " · ")
    }

    private func shorten(_ addr: String) -> String {
        guard addr.count > 14 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    @MainActor
    private func runScan() async {
        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil

        let rpcURL = store.ethereumSettings.rpcURL(for: network)
        let explorerAPI = store.ethereumSettings.explorerAPIURL(for: network)
        let apiKey = store.ethereumSettings.explorerAPIKey(for: network)

        do {
            let scanSource: EthereumWalletDiscovery.Source
            switch source {
            case .software:
                guard let sandwich = store.sandwich else {
                    throw NSError(domain: "Discovery", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Identity Sandwich is locked. Unlock Maknoon first."
                    ])
                }
                scanSource = .software(sandwich: sandwich)
            case .hardware(let deviceId):
                guard let dev = store.devices.find(id: deviceId) else {
                    throw NSError(domain: "Discovery", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Hardware device record \(deviceId) is no longer registered."
                    ])
                }
                let hwKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
                let client = HardwareWalletFactory.make(kind: hwKind)
                let connected = try await client.identifyDevice()
                guard connected == dev.serial else {
                    throw HardwareWalletError.transport(
                        "Connected device has serial \(connected) which does not match the registered \(dev.serial). Reconnect the correct device."
                    )
                }
                scanSource = .hardware(client: client)
            }

            let hits = try await EthereumWalletDiscovery.scan(
                source: scanSource,
                network: network,
                rpcURL: rpcURL,
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                maxAccount: 5,
                onProgress: { p in
                    let line: String
                    switch p.phase {
                    case .scanning:
                        line = "Scanning account \(p.account)…"
                    case .completed(let active):
                        line = active
                            ? "Account \(p.account): active"
                            : "Account \(p.account): empty"
                    case .failed(let msg):
                        line = "Account \(p.account): \(msg)"
                    }
                    progress.append(line)
                }
            )
            discovered = hits
            // Wallets are network-agnostic now: a software wallet at
            // account 0 covers every chain. Dedupe by (kind, account)
            // regardless of which network the user is currently
            // scanning, so we don't offer to "add" a wallet that
            // already exists under a different active network.
            let existing: Set<String>
            switch source {
            case .software:
                existing = Set(store.ethereumWalletStore.wallets.compactMap { w -> String? in
                    guard case let .software(account) = w.kind else { return nil }
                    return "\(network.rawValue):\(account)"
                })
            case .hardware(let deviceId):
                existing = Set(store.ethereumWalletStore.wallets.compactMap { w -> String? in
                    guard case let .hardware(walletDev, account, _) = w.kind,
                          walletDev == deviceId else { return nil }
                    return "\(network.rawValue):\(account)"
                })
            }
            for hit in hits where !existing.contains(hit.id) {
                selection.insert(hit.id)
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        scanning = false
    }

    @MainActor
    private func addSelected() {
        var report: [String] = []
        for acct in discovered where selection.contains(acct.id) {
            switch source {
            case .software:
                if let existing = store.ethereumWalletStore.wallets.first(where: {
                    if case let .software(account) = $0.kind { return account == acct.account }
                    return false
                }) {
                    report.append("Account \(acct.account), already labelled \"\(existing.label)\", skipped.")
                    continue
                }
                let label = "Wallet #\(acct.account)"
                let descriptor = EthereumWalletDescriptor(
                    label: label,
                    kind: .software(account: acct.account),
                    cachedAddress: acct.address
                )
                store.ethereumWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
                report.append("Account \(acct.account) added as \"\(label)\".")
            case .hardware(let deviceId):
                if let existing = store.ethereumWalletStore.wallets.first(where: {
                    if case let .hardware(d, a, _) = $0.kind { return d == deviceId && a == acct.account }
                    return false
                }) {
                    report.append("Account \(acct.account), already labelled \"\(existing.label)\", skipped.")
                    continue
                }
                let dev = store.devices.find(id: deviceId)
                let label = "\(dev?.label ?? "Device") #\(acct.account)"
                let descriptor = EthereumWalletDescriptor(
                    label: label,
                    kind: .hardware(deviceId: deviceId, account: acct.account, address: acct.address),
                    cachedAddress: acct.address
                )
                store.ethereumWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
                store.devices.addEthereumWallet(deviceId: deviceId, walletId: descriptor.id)
                report.append("Account \(acct.account) added as \"\(label)\".")
            }
        }
        addReport = report
    }
}
