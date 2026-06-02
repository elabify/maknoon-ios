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
    @State private var selection: Set<UInt32> = []
    @State private var errorText: String?
    /// Populated when the user taps Start Scan. Drives the pre-tap
    /// "open the Bitcoin app on the device" sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?
    /// Per-account report shown after Add Selected runs.
    @State private var addReport: [String]?

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
        var id: UInt32 { account }
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
                            get: { selection.contains(acct.account) },
                            set: { include in
                                if include { selection.insert(acct.account) }
                                else { selection.remove(acct.account) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(network.displayName) - account \(acct.account)")
                                    .font(.callout.weight(.semibold))
                                Text("\(acct.txCount) tx · \(formatSats(acct.balanceSat, ticker: network.ticker))")
                                    .font(.caption).foregroundStyle(.secondary)
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

        let electrumURL = store.bitcoinSettings.electrumURL(for: network)

        // Pin the BLE session for the duration of the scan so the
        // 6+ back-to-back APDUs share one connection. Without this,
        // each method's `defer { resetSession() }` would drop the
        // link and force a fresh scan + reconnect, which the Ledger
        // doesn't reliably survive when repeated in quick succession.
        client.beginSession()
        defer { client.endSession() }

        do {
            // Confirm the same physical device.
            let liveSerial = try await client.identifyDevice()
            guard liveSerial == device.serial else {
                throw HardwareWalletError.transport("Connected device has serial \(liveSerial) which does not match the registered serial \(device.serial). Reconnect the correct device.")
            }
            let fingerprint = try await client.getBitcoinMasterFingerprint(networkCoinType: network.coinType)

            // BIP44-style gap-limit at the ACCOUNT level: keep walking
            // 0, 1, 2, ... until we hit emptyAccountGapLimit empty
            // accounts in a row, then stop. This avoids the old
            // hard-coded 5-account ceiling cutting off long histories.
            var account: UInt32 = 0
            var consecutiveEmpty = 0
            while consecutiveEmpty < Self.emptyAccountGapLimit {
                progress.append("Reading \(network.displayName) account \(account) xpub…")
                let xpub = try await client.getBitcoinAccountXpub(
                    account: account, networkCoinType: network.coinType
                )

                progress.append("Scanning \(network.displayName) account \(account)…")
                let pair = try BitcoinDescriptors.watchOnlyFromCachedKey(
                    accountFingerprint: fingerprint,
                    accountXpub: xpub,
                    network: network
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
                progress.append("  \(network.displayName) account \(account): \(txCount) tx, \(balanceSat) sats")

                if txCount > 0 {
                    consecutiveEmpty = 0
                    let d = Discovered(
                        account: account, xpub: xpub, fingerprint: fingerprint,
                        txCount: txCount, balanceSat: balanceSat
                    )
                    found.append(d)
                    // Pre-select any account that doesn't already
                    // exist for this (device, network).
                    let exists = store.bitcoinWalletStore.wallets.contains { w in
                        guard w.network == network,
                              case let .hardware(deviceId, _, walletXpub) = w.kind,
                              deviceId == device.id else { return false }
                        return walletXpub == xpub
                    }
                    if !exists { selection.insert(account) }
                } else {
                    consecutiveEmpty += 1
                }
                account += 1
            }
            progress.append("Stopped after \(Self.emptyAccountGapLimit) consecutive empty accounts.")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func addSelected() {
        var report: [String] = []
        for d in found where selection.contains(d.account) {
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
            let baseLabel = "\(device.label) \(network.displayName)"
            let label = "\(baseLabel) #\(d.account)"
            let descriptor = BitcoinWalletDescriptor(
                label: label,
                kind: .hardware(deviceId: device.id, accountFingerprint: d.fingerprint, accountXpub: d.xpub),
                network: network
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
