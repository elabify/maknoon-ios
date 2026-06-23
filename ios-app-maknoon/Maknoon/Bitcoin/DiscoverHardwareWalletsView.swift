// "Scan device for existing wallets" flow, parallel to the
// BitcoinWalletDiscovery flow that scans the sandwich seed for
// software-wallet activity. This one walks account indices 0..4 on
// a paired hardware device, asks the device for each account's xpub,
// runs a full Electrum scan against the resulting watch-only
// descriptor, and surfaces every account that has prior history.
//
// Each device round-trip prompts the user on the device only once
// per session (Ledger's GET_EXTENDED_PUBKEY with display_flag=0
// auto-confirms once the Bitcoin app is open). The full-scan
// per-account is a real Electrum call; each takes several seconds.

import SwiftUI
import BitcoinDevKit

struct DiscoverHardwareWalletsView: View {
    let device: RegisteredDevice
    /// Network to scan. Passed in by the parent (AddBitcoinWalletSheet)
    /// so the discover view is locked to the same subnetwork the user
    /// already picked, removing one source of "why didn't it find my
    /// signet wallet" confusion.
    let network: BitcoinNetwork
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var found: [Discovered] = []
    @State private var selection: Set<String> = []
    @State private var errorText: String?
    /// Populated when the user taps Start Scan. Drives the pre-tap
    /// "open the Bitcoin app on the device" sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?
    /// Per-account report shown after Add Selected runs.
    @State private var addReport: [String]?
    /// Trezor hidden-wallet choice, collected UPSTREAM in the connection
    /// step (DeviceReadyConfirmationSheet) on the hardware add/discover tap.
    /// The one choice applies to both add and discover (ADR-0033). Passed as
    /// a BINDING so the scan reads the LIVE committed value: the readiness
    /// sheet sets it just before this view opens, and a plain snapshot could
    /// capture the pre-selection `.standard` during the two-sheet handoff
    /// (the bug that left the Trezor passphrase unsent). Ledger passes
    /// `.constant(.standard)` / `.constant("")`.
    @Binding var hwPassphrase: HiddenWalletSelection
    /// Host-typed passphrase that pairs with `hwPassphrase == .hostTyped`.
    @Binding var hwHostPassphrase: String
    /// Also sweep well-known alternative paths: BIP44 (legacy), BIP49
    /// (nested segwit), BIP84 (native segwit) per account.
    @State private var alsoTryAltPaths: Bool = false

    private var isTrezor: Bool { device.kind == .trezor }

    /// BIP44 gap-limit at the ACCOUNT level. Stop scanning once this
    /// many consecutive empty accounts are encountered. The default
    /// matches what hardware-wallet desktop apps use (4 empty accounts
    /// in a row, then stop) so a user with a long-tail of accounts
    /// 0..10 followed by a gap does not get prematurely truncated at
    /// the old hard-coded 5-account ceiling.
    private static let emptyAccountGapLimit = 4

    struct Discovered: Identifiable, Hashable {
        let account: UInt32
        let xpub: String
        let fingerprint: String
        let txCount: Int
        let balanceSat: UInt64
        /// Non-standard account path this was found at, when sweeping
        /// alternatives; nil for the standard BIP84 path.
        var derivationPath: String?
        var id: String { "\(account):\(derivationPath ?? "std")" }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Device", value: "\(device.label) (\(device.kind.displayName))")
                LabeledContent("Network", value: network.displayName)
            } header: {
                Text("Scanning")
            } footer: {
                Text("Maknoon will walk BIP44 accounts on this device + network until \(Self.emptyAccountGapLimit) consecutive empty accounts are found, then stop. Each account is a full Electrum scan and can take several seconds.")
                    .font(.caption)
            }

            if !scanning && found.isEmpty && progress.isEmpty {
                Section {
                    Toggle("Try alternative derivation paths", isOn: $alsoTryAltPaths)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Also checks BIP44 (legacy 1…), BIP49 (nested SegWit 3…) and BIP84 (native SegWit bc1q…) per account, so a wallet from another app is found. Slower: a full scan per script type.")
                        .font(.caption)
                }
            }

            if !scanning && found.isEmpty && progress.isEmpty {
                Section {
                    let appName = network == .mainnet ? "Bitcoin" : "Bitcoin Test"
                    Text("Open the \(appName) app on the \(device.kind.displayName) and approve the prompt when asked.")
                        .font(.callout)
                    Button {
                        if HardwareOperationPurpose.shouldPresent(for: device.kind) {
                            pendingReadyOp = PendingHardwareOperation(
                                device: device,
                                purpose: .bitcoinDiscover(network: network)
                            )
                        } else {
                            Task { await runScan() }
                        }
                    } label: {
                        Label("Start scan", systemImage: "magnifyingglass")
                    }
                    .disabled(!hwPassphrase.isReady(hostPassphrase: hwHostPassphrase))
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

            if !found.isEmpty {
                Section {
                    ForEach(found) { acct in
                        Toggle(isOn: Binding(
                            get: { selection.contains(acct.id) },
                            set: { include in
                                if include { selection.insert(acct.id) }
                                else { selection.remove(acct.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(network.displayName) - account \(acct.account)")
                                    .font(.callout.weight(.semibold))
                                Text("\(acct.txCount) tx · \(formatSats(acct.balanceSat, ticker: network.ticker))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let path = acct.derivationPath {
                                    Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Found activity")
                } footer: {
                    Text("Selected accounts are added to your wallet list. Accounts that already exist on this device + network are skipped.")
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
                    Button("Done") { dismiss() }
                } header: {
                    Text("Results")
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Discover wallets")
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

    @MainActor
    private func runScan() async {
        scanning = true
        progress = []
        found = []
        selection = []
        errorText = nil
        defer { scanning = false }

        let kindForFactory: HardwareWalletKind = device.kind == .ledger ? .ledger : .trezor
        let client = HardwareWalletFactory.make(kind: kindForFactory)
        // A Trezor hidden wallet derives in its own passphrase session.
        // Ledger / mock clients ignore this.
        if let trezor = client as? TrezorBLE {
            trezor.applyPassphraseMode(hwPassphrase.choice(hostPassphrase: hwHostPassphrase))
        }
        // A fresh hidden wallet has no on-chain activity, so the sweep
        // would surface nothing; keep account 0 so the user can still
        // add it. Standard sweeps are unaffected.
        let keepEmptyFirst = isTrezor && hwPassphrase != .standard

        let electrumURL = store.bitcoinSettings.electrumURL(for: network)

        // Pin the BLE session for the duration of the scan so the
        // 6+ back-to-back APDUs share one connection. Without this,
        // each method's `defer { resetSession() }` would drop the
        // link and force a fresh scan + reconnect, which the Ledger
        // doesn't reliably survive when repeated in quick succession.
        client.beginSession()
        defer { client.endSession() }

        do {
            // Confirm the same physical device. A Ledger's serial is a
            // platform-specific BLE id (iOS peripheral UUID vs Android MAC), so
            // a record carried across platforms by an encrypted backup can never
            // serial-match. When this is the SOLE registered device of its kind
            // there is no ambiguity about which physical unit answered, so
            // re-bind the stored serial to the live one (device id + wallet
            // links unchanged) and proceed. Mirrors Android withHardwareDevice;
            // with 2+ devices of a kind the hard guard stands. (ADR-0033)
            let liveSerial = try await client.identifyDevice()
            if liveSerial != device.serial {
                let sameKind = store.devices.devices.filter { $0.kind == device.kind }
                if sameKind.count == 1 {
                    store.devices.rebindSerial(deviceId: device.id, serial: liveSerial)
                } else {
                    throw HardwareWalletError.transport("Connected device has serial \(liveSerial) which does not match the registered serial \(device.serial). Reconnect the correct device.")
                }
            }
            let fingerprint = try await client.getBitcoinMasterFingerprint(networkCoinType: network.coinType)

            // Standard path only (nil), or the BIP44/49/84 templates per
            // account when sweeping alternatives.
            let templateList: [String?] = alsoTryAltPaths
                ? BIP32Path.alternativeTemplates(.bitcoin).map { Optional($0) }
                : [nil]
            // Dedup resolved paths + xpubs so a template that collides or
            // a device that ignores the override never yields a dup row.
            var seenPaths = Set<String>()
            var seenXpubs = Set<String>()

            // BIP44-style gap-limit at the ACCOUNT level: keep walking
            // 0, 1, 2, ... until we hit emptyAccountGapLimit empty
            // accounts in a row, then stop.
            var account: UInt32 = 0
            var consecutiveEmpty = 0
            var firstEntry: Discovered?
            while consecutiveEmpty < Self.emptyAccountGapLimit {
                var accountHadActivity = false
                for tmpl in templateList {
                    let pathOverride = tmpl.map {
                        BIP32Path.fill($0, account: account, coinType: network.coinType)
                    }
                    guard seenPaths.insert(pathOverride ?? "std").inserted else { continue }
                    client.setDerivationPathOverride(pathOverride)

                    // Read the account xpub; a device may forbid a foreign
                    // path (Trezor rejects non-standard purposes), so skip
                    // that template rather than aborting the sweep.
                    let xpub: String
                    do {
                        progress.append("Reading account \(account) \(pathOverride ?? "BIP84")…")
                        xpub = try await client.getBitcoinAccountXpub(
                            account: account, networkCoinType: network.coinType
                        )
                    } catch {
                        progress.append("Account \(account): \(pathOverride ?? "standard path") not supported, skipped")
                        continue
                    }
                    guard seenXpubs.insert(xpub).inserted else { continue }

                    let scriptType = BIP32Path.bitcoinScriptType(forPath: pathOverride ?? "") ?? .nativeSegwit
                    let pair = try BitcoinDescriptors.watchOnlyFromCachedKey(
                        accountFingerprint: fingerprint,
                        accountXpub: xpub,
                        network: network,
                        scriptType: scriptType
                    )
                    let persister = try Persister.newInMemory()
                    let probe = try Wallet(
                        descriptor: pair.external,
                        changeDescriptor: pair.internal,
                        network: network.bdk,
                        persister: persister
                    )
                    let request = try probe.startFullScan().build()
                    let cli = try ElectrumClient(url: electrumURL, socks5: nil)
                    let update = try cli.fullScan(
                        request: request, stopGap: 20, batchSize: 10, fetchPrevTxouts: false
                    )
                    try probe.applyUpdate(update: update)
                    let txCount = probe.transactions().count
                    let balanceSat = probe.balance().total.toSat()
                    progress.append("  account \(account) \(pathOverride ?? "BIP84"): \(txCount) tx, \(balanceSat) sats")

                    let d = Discovered(
                        account: account, xpub: xpub, fingerprint: fingerprint,
                        txCount: txCount, balanceSat: balanceSat, derivationPath: pathOverride
                    )
                    if account == 0, firstEntry == nil { firstEntry = d }

                    if txCount > 0 {
                        accountHadActivity = true
                        found.append(d)
                        // Dedup is by xpub, so a hidden / alt-path wallet's
                        // distinct xpub is never confused with the standard.
                        let exists = store.bitcoinWalletStore.wallets.contains { w in
                            guard w.network == network,
                                  case let .hardware(deviceId, _, walletXpub) = w.kind,
                                  deviceId == device.id else { return false }
                            return walletXpub == xpub
                        }
                        if !exists { selection.insert(d.id) }
                    }
                }
                if accountHadActivity { consecutiveEmpty = 0 } else { consecutiveEmpty += 1 }
                account += 1
            }
            client.setDerivationPathOverride(nil)
            // Surface account 0 for a fresh hidden wallet even with no
            // activity, so it can be added from the sweep too.
            if keepEmptyFirst, found.isEmpty, let first = firstEntry {
                found.append(first)
                selection.insert(first.id)
            }
            progress.append("Stopped after \(Self.emptyAccountGapLimit) consecutive empty accounts.")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func addSelected() {
        var report: [String] = []
        // Persist the hidden-wallet binding once for this sweep (writes
        // a host-typed passphrase to the Keychain). nil for the standard
        // wallet and for every Ledger sweep.
        let hidden = isTrezor
            ? HardwarePassphraseRef.persist(selection: hwPassphrase)
            : nil
        let baseSuffix = hidden == nil ? "" : " (Hidden)"
        for d in found where selection.contains(d.id) {
            let existing = store.bitcoinWalletStore.wallets.first { w in
                guard w.network == network,
                      case let .hardware(deviceId, _, walletXpub) = w.kind,
                      deviceId == device.id else { return false }
                return walletXpub == d.xpub
            }
            if let existing {
                report.append("Account \(d.account) (\(network.displayName)), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            // Relink-by-key (ADR-0033): if a wallet with this SAME xpub already
            // exists but is ORPHANED (its stored deviceId no longer resolves in
            // the registry, e.g. after a device remove/re-add or a cross-device
            // restore), re-point it to this device instead of adding a duplicate.
            let orphan = store.bitcoinWalletStore.wallets.first { w in
                guard w.network == network,
                      case let .hardware(deviceId, _, walletXpub) = w.kind,
                      walletXpub == d.xpub else { return false }
                return store.devices.find(id: deviceId) == nil
            }
            if let orphan {
                store.bitcoinWalletStore.relink(walletId: orphan.id, toDeviceId: device.id)
                store.devices.addBitcoinWallet(deviceId: device.id, walletId: orphan.id)
                report.append("Account \(d.account) (\(network.displayName)) re-linked to existing \"\(orphan.label)\".")
                continue
            }
            let suffix = baseSuffix + (d.derivationPath != nil ? " (Custom path)" : "")
            let baseLabel = "\(device.label) \(network.displayName)"
            let label = "\(baseLabel) #\(d.account)\(suffix)"
            let descriptor = BitcoinWalletDescriptor(
                label: label,
                kind: .hardware(deviceId: device.id, accountFingerprint: d.fingerprint, accountXpub: d.xpub),
                network: network,
                hidden: hidden,
                derivationPath: d.derivationPath
            )
            store.bitcoinWalletStore.add(descriptor, makeActive: false)
            store.devices.addBitcoinWallet(deviceId: device.id, walletId: descriptor.id)
            report.append("Account \(d.account) (\(network.displayName)) added as \"\(label)\".")
        }
        addReport = report
    }

    private func formatSats(_ sats: UInt64, ticker: String) -> String {
        let btc = Double(sats) / 100_000_000.0
        return String(format: "%.8f %@", btc, ticker)
    }
}
