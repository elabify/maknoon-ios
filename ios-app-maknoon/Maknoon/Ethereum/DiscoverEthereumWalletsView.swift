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

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Hardware-only: also sweep well-known alternative derivation paths
    /// (Ledger Live, MEW legacy, …) for each account.
    @State private var alsoTryAltPaths: Bool = false

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [EthereumWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    /// Per-account report shown after Add Selected runs. Each
    /// discovered account either gets an "added" line or a "skipped,
    /// already labelled X" line.
    @State private var addReport: [String]?

    private var sourceLabel: String {
        switch source {
        case .software: return "your recovery phrase"
        case .hardware(let id):
            return store.devices.find(id: id)?.label ?? "the hardware device"
        }
    }

    /// Hidden wallets are a Trezor-only feature; the selector is gated
    /// to Trezor sources so the Ledger / software flows are untouched.
    private var isTrezorSource: Bool {
        if case .hardware(let id) = source {
            return store.devices.find(id: id)?.kind == .trezor
        }
        return false
    }

    /// Map the selector + typed text onto the in-memory choice handed
    /// to the Trezor client for this sweep.
    private var currentPassphraseChoice: PassphraseChoice {
        passphrase.choice(hostPassphrase: hostPassphrase)
    }

    /// True once the chosen mode is actionable (host-typed needs text).
    private var passphraseReady: Bool {
        passphrase.isReady(hostPassphrase: hostPassphrase)
    }

    /// Alternative-path sweeping is hardware-only (software wallets
    /// always derive at the standard path).
    private var isHardwareSource: Bool {
        if case .hardware = source { return true }
        return false
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

                if isHardwareSource && !scanning && discovered.isEmpty && progress.isEmpty {
                    Section {
                        Toggle("Try alternative derivation paths", isOn: $alsoTryAltPaths)
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("Also checks well-known non-standard paths (Ledger Live, MEW legacy, …) so a wallet created in another app is found. Slower: more lookups per account.")
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
                        .disabled(!passphraseReady)
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
        }
    }

    private func detailLine(_ acct: EthereumWalletDiscovery.DiscoveredAccount) -> String {
        var parts: [String] = []
        if acct.hasBalance { parts.append("has balance") }
        if acct.txCount > 0 { parts.append("has tx history") }
        if let path = acct.derivationPath { parts.append(path) }
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
                        NSLocalizedDescriptionKey: "Maknoon is locked. Unlock Maknoon first."
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
                // For a Trezor hidden wallet, open the right THP session
                // before any address derivation runs. Ledger / mock
                // clients have no passphrase concept and ignore this.
                if let trezor = client as? TrezorBLE {
                    trezor.applyPassphraseMode(currentPassphraseChoice)
                }
                let connected = try await client.identifyDevice()
                guard connected == dev.serial else {
                    throw HardwareWalletError.transport(
                        "Connected device has serial \(connected) which does not match the registered \(dev.serial). Reconnect the correct device."
                    )
                }
                scanSource = .hardware(client: client)
            }

            // A hidden wallet is expected to be fresh and empty, so the
            // activity probe would surface nothing. Keep account 0 in
            // the results when a passphrase is in play.
            let keepEmptyFirst = isTrezorSource && passphrase != .standard
            let templates = (isHardwareSource && alsoTryAltPaths)
                ? BIP32Path.alternativeTemplates(.ethereum)
                : nil
            let hits = try await EthereumWalletDiscovery.scan(
                source: scanSource,
                network: network,
                rpcURL: rpcURL,
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                maxAccount: 5,
                includeFirstAccountAlways: keepEmptyFirst,
                pathTemplates: templates,
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
            // Wallets are network-agnostic now: the same key covers
            // every chain. Software dedupes by account. Hardware
            // dedupes by ADDRESS, not account: a hidden (passphrase)
            // wallet derives a different address at the same account
            // index, so it is a genuinely distinct wallet that must
            // not be hidden behind the standard one.
            switch source {
            case .software:
                let existing = Set(store.ethereumWalletStore.wallets.compactMap { w -> UInt32? in
                    guard case let .software(account) = w.kind else { return nil }
                    return account
                })
                for hit in hits where !existing.contains(hit.account) {
                    selection.insert(hit.id)
                }
            case .hardware(let deviceId):
                let existing = Set(store.ethereumWalletStore.wallets.compactMap { w -> String? in
                    guard case let .hardware(walletDev, _, addr) = w.kind,
                          walletDev == deviceId else { return nil }
                    return addr.lowercased()
                })
                for hit in hits where !existing.contains(hit.address.lowercased()) {
                    selection.insert(hit.id)
                }
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
                // Dedup by address: a hidden wallet shares the account
                // index with the standard one but has a distinct address.
                if let existing = store.ethereumWalletStore.wallets.first(where: {
                    if case let .hardware(d, _, addr) = $0.kind {
                        return d == deviceId && addr.caseInsensitiveCompare(acct.address) == .orderedSame
                    }
                    return false
                }) {
                    report.append("\(shorten(acct.address)), already labelled \"\(existing.label)\", skipped.")
                    continue
                }
                // Relink-by-key (ADR-0033): re-point an ORPHANED wallet with the
                // same address (its stored deviceId no longer resolves) instead
                // of adding a duplicate.
                if let orphan = store.ethereumWalletStore.wallets.first(where: {
                    if case let .hardware(d, _, addr) = $0.kind {
                        return addr.caseInsensitiveCompare(acct.address) == .orderedSame
                            && store.devices.find(id: d) == nil
                    }
                    return false
                }) {
                    store.ethereumWalletStore.relink(walletId: orphan.id, toDeviceId: deviceId)
                    store.devices.addEthereumWallet(deviceId: deviceId, walletId: orphan.id)
                    report.append("\(shorten(acct.address)) re-linked to existing \"\(orphan.label)\".")
                    continue
                }
                let dev = store.devices.find(id: deviceId)
                let hiddenRef = makeHiddenRef()
                var suffix = hiddenRef == nil ? "" : " (Hidden)"
                if acct.derivationPath != nil { suffix += " (Custom path)" }
                let label = "\(dev?.label ?? "Device") #\(acct.account)\(suffix)"
                let descriptor = EthereumWalletDescriptor(
                    label: label,
                    kind: .hardware(deviceId: deviceId, account: acct.account, address: acct.address),
                    cachedAddress: acct.address,
                    hidden: hiddenRef,
                    derivationPath: acct.derivationPath
                )
                store.ethereumWalletStore.add(descriptor, initialNetwork: network, makeActive: false)
                store.devices.addEthereumWallet(deviceId: deviceId, walletId: descriptor.id)
                report.append("Account \(acct.account) added as \"\(label)\".")
            }
        }
        addReport = report
    }

    /// Build the persisted passphrase binding for a wallet being added
    /// in the current scan. Returns nil for the standard wallet (incl.
    /// every Ledger add, where the selector is never shown).
    private func makeHiddenRef() -> HardwarePassphraseRef? {
        HardwarePassphraseRef.persist(selection: passphrase)
    }
}
