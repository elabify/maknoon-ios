// Multi-wallet management. List of every wallet in
// BitcoinWalletStore, "Add software wallet" button, "Pair hardware
// wallet" button (routes to DevicesView), per-row rename / remove.

import SwiftUI

struct BitcoinWalletsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSoftware: Bool = false
    @State private var renameTarget: BitcoinWalletDescriptor?
    @State private var renameDraft: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Wallets") {
                    ForEach(store.bitcoinWalletStore.wallets) { w in
                        row(for: w)
                    }
                    .onMove { offsets, dest in
                        store.bitcoinWalletStore.move(
                            fromOffsets: offsets, toOffset: dest
                        )
                    }
                }
                Section {
                    Button {
                        showAddSoftware = true
                    } label: {
                        Label("Add wallet", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Bitcoin wallets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSoftware) {
                AddBitcoinWalletSheet()
                    .environment(store)
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(target: target)
            }
        }
    }

    private func row(for w: BitcoinWalletDescriptor) -> some View {
        Button {
            store.bitcoinWalletStore.setActive(w.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.label).font(.headline)
                    Text("\(kindLabel(w.kind)) - \(w.network.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.bitcoinWalletStore.activeWalletId == w.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.plain)
        // allowsFullSwipe: false prevents a continued right-swipe from
        // auto-firing Remove. The user has to tap the exposed Remove
        // button explicitly.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.bitcoinWalletStore.remove(id: w.id)
                // Clear the wallet id from any device's promotion
                // list so the Settings > Devices badge stops showing
                // "Bitcoin" once the last linked wallet is gone.
                store.devices.scrubWalletId(w.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                renameDraft = w.label
                renameTarget = w
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func renameSheet(target: BitcoinWalletDescriptor) -> some View {
        NavigationStack {
            Form {
                Section("Wallet label") {
                    TextField("e.g. Cold storage", text: $renameDraft)
                }
                Section {
                    Button("Save") {
                        store.bitcoinWalletStore.rename(id: target.id, to: renameDraft)
                        renameTarget = nil
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { renameTarget = nil }
                }
            }
        }
    }

    private func kindLabel(_ kind: BitcoinWalletKind) -> String {
        switch kind {
        case .software(let acct):   return "Software (account \(acct))"
        case .hardware:             return "Hardware"
        }
    }
}

struct AddBitcoinWalletSheet: View {
    /// Optional callback fired AFTER the wallet has been created and
    /// the sheet has dismissed.
    var onCreated: (() -> Void)? = nil

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case software = "Software"
        case hardware = "Hardware"
        var id: String { rawValue }
    }

    @State private var source: Source = .software
    @State private var label: String = ""
    @State private var network: BitcoinNetwork = .mainnet
    @State private var selectedDeviceId: UUID?
    @State private var showSoftwareDiscovery: Bool = false
    @State private var account: UInt32 = 0
    /// Trezor-only hidden-wallet selector for the direct-add path.
    /// `.standard` reproduces exact Ledger behavior (empty passphrase).
    @State private var useCustomPath: Bool = false
    @State private var customPath: String = ""
    @State private var hwPassphrase: HiddenWalletSelection = .standard
    /// Host-typed passphrase, used only when `hwPassphrase == .hostTyped`.
    @State private var hwHostPassphrase: String = ""
    /// Software-path account index, kept separate from the hardware
    /// `account` so each path has its own default. Seeded to the next
    /// free account on the selected network so the default never
    /// duplicates an existing wallet; the user can still adjust it.
    @State private var softwareAccount: UInt32 = 0
    @State private var didSeedSoftwareAccount = false
    @State private var creating: Bool = false
    @State private var errorText: String?
    @State private var showUnlock: Bool = false
    /// Populated when the user taps Create on the hardware tab.
    /// Drives the pre-tap "get the device ready" sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?

    private var bitcoinDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.bitcoin)
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.sandwich == nil {
                    lockedBannerSection
                }
                Section("Source") {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: source) { _, _ in
                        // Errors and in-flight state belong to the
                        // tab the user was just on, not the one they
                        // just switched to.
                        errorText = nil
                    }
                    Text(sourceFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if source == .software {
                    softwareWalletSection
                    softwareDiscoverSection
                } else {
                    hardwareDeviceSection
                    if let devId = selectedDeviceId,
                       let dev = store.devices.find(id: devId) {
                        hardwareWalletSection(dev)
                        hardwareCreateSection
                        hardwareDiscoverSection(dev)
                    }
                }
            }
            .navigationTitle("Add Bitcoin wallet")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if !didSeedSoftwareAccount {
                    seedSoftwareAccount()
                    didSeedSoftwareAccount = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showUnlock) {
                HardwareUnlockView(enrollments: store.pendingHardwareUnlock)
                    .environment(store)
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: {
                        Task { @MainActor in
                            creating = true
                            await createHardware()
                            creating = false
                        }
                    },
                    onCancel: {}
                )
            }
            .sheet(isPresented: $showSoftwareDiscovery) {
                DiscoverWalletsSheet()
                    .environment(store)
            }
        }
    }

    @ViewBuilder
    private var lockedBannerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Identity Sandwich is locked", systemImage: "lock.shield.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Software wallets derive from your master seed and need the Sandwich unlocked. Hardware wallets do not. Tap below to unlock with your enrolled device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showUnlock = true
                } label: {
                    Label("Unlock with hardware device", systemImage: "key.radiowaves.forward")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private var sourceFooter: String {
        switch source {
        case .software:
            return "Creates a wallet on this iPhone. One biometric or passcode confirmation at setup; everyday use is silent."
        case .hardware:
            return "Pairs a wallet with a Ledger you've registered. Sending requires the device to confirm each transaction."
        }
    }

    @ViewBuilder
    private var hardwareDeviceSection: some View {
        if bitcoinDevices.isEmpty {
            Section("Device") {
                Text("No hardware devices registered yet. Add one from Settings → Devices first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Device") {
                Picker("Device", selection: $selectedDeviceId) {
                    Text("Pick a device").tag(UUID?.none)
                    ForEach(bitcoinDevices) { dev in
                        Text("\(dev.label) (\(dev.kind.displayName))").tag(Optional(dev.id))
                    }
                }
            }
        }
    }

    private func hardwareWalletSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Picker("Network", selection: $network) {
                ForEach(BitcoinNetwork.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Stepper("Account #\(account)", value: $account, in: 0...20)
            TextField(autoLabel(for: dev), text: $label)
            if dev.kind == .trezor {
                Picker("Wallet", selection: $hwPassphrase) {
                    ForEach(HiddenWalletSelection.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if hwPassphrase == .hostTyped {
                    SecureField("Passphrase", text: $hwHostPassphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            DerivationPathAdvancedField(
                standardPath: BIP32Path.standardBitcoin(account: account, coinType: network.coinType),
                useCustom: $useCustomPath,
                customPath: $customPath
            )
        } header: {
            Text("New Bitcoin wallet")
        } footer: {
            Text(dev.kind == .trezor
                ? hwPassphrase.footer
                : "Leave the label blank to use \"\(autoLabel(for: dev))\".")
                .font(.caption)
        }
    }

    private var hardwareCreateSection: some View {
        Section {
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if creating { ProgressView().controlSize(.small) }
                    Text(creating ? "Setting up…" : "Create Single Wallet")
                }
            }
            .disabled(creating || !canCreate)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } footer: {
            Text("Imports just account #\(account) on \(network.displayName) from the selected device. Use Discover existing wallets below if you don't know which accounts already hold coins.")
                .font(.caption)
        }
    }

    private func hardwareDiscoverSection(_ dev: RegisteredDevice) -> some View {
        Section {
            NavigationLink {
                DiscoverHardwareWalletsView(device: dev, network: network)
                    .environment(store)
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("Scans accounts on \(network.displayName) until 4 consecutive empty accounts are found, then stops. Use this when restoring from a device you've used before.")
                .font(.caption)
        }
    }

    private var softwareWalletSection: some View {
        Section {
            TextField("Label", text: $label)
            Picker("Network", selection: $network) {
                ForEach(BitcoinNetwork.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .onChange(of: network) { _, _ in
                // Account space is per-network for Bitcoin, so re-seed
                // to the new network's next free account when it changes.
                seedSoftwareAccount()
            }
            Stepper(value: $softwareAccount, in: 0...20) {
                HStack {
                    Text("Account")
                    Spacer()
                    Text("\(softwareAccount)").foregroundStyle(.secondary)
                }
            }
            if softwareAccountInUse {
                Text("Account \(softwareAccount) already exists on \(network.displayName). Pick another to avoid a duplicate.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if creating { ProgressView().controlSize(.small) }
                    Text(creating ? "Setting up…" : "Create")
                }
            }
            .disabled(creating || !canCreate || softwareAccountInUse)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("New Bitcoin wallet")
        } footer: {
            Text("The account number fills in automatically to the next free one on this network. You'll confirm with biometric or passcode once.")
                .font(.caption)
        }
    }

    private func seedSoftwareAccount() {
        softwareAccount = store.bitcoinWalletStore.nextSoftwareAccount(on: network)
    }

    private var softwareAccountInUse: Bool {
        store.bitcoinWalletStore.hasSoftwareWallet(account: softwareAccount, on: network)
    }

    private var softwareDiscoverSection: some View {
        Section {
            Button {
                showSoftwareDiscovery = true
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
            .disabled(store.sandwich == nil)
        } footer: {
            Text("Sweeps your Identity Sandwich seed for accounts that already have on-chain activity. Useful when restoring from a backup or migrating from another wallet built on the same 24-word recovery phrase.")
                .font(.caption)
        }
    }

    /// Default label used when the user leaves the Label field blank
    /// on the hardware path. Format: "DeviceName SubNetwork #N" so the
    /// wallet list stays self-explanatory if the user creates several
    /// accounts on the same device + network.
    private func autoLabel(for dev: RegisteredDevice) -> String {
        "\(dev.label) \(network.displayName) #\(account)"
    }

    private var canCreate: Bool {
        switch source {
        case .software: return true
        case .hardware: return selectedDeviceId != nil
        }
    }

    @MainActor
    private func create() async {
        errorText = nil
        switch source {
        case .software:
            creating = true
            await createSoftware()
            creating = false
        case .hardware:
            guard let devId = selectedDeviceId,
                  let dev = store.devices.find(id: devId) else {
                errorText = "Pick a device first."
                return
            }
            if dev.kind == .trezor, !hwPassphrase.isReady(hostPassphrase: hwHostPassphrase) {
                errorText = "Enter the hidden-wallet passphrase first."
                return
            }
            if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .bitcoinWallet(network: network)
                )
            } else {
                creating = true
                await createHardware()
                creating = false
            }
        }
    }

    @MainActor
    private func createSoftware() async {
        let account = softwareAccount
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let baseLabel = trimmed.isEmpty ? "Wallet" : trimmed
        let suffixedLabel = "\(baseLabel) #\(account)"

        // Never create a second software wallet at the same (network,
        // account): it would derive the identical address.
        if store.bitcoinWalletStore.hasSoftwareWallet(account: account, on: network) {
            errorText = "A software wallet at account #\(account) on \(network.displayName) already exists. Pick a different account number."
            return
        }

        guard let sandwich = store.sandwich else {
            // Surface the unlock sheet inline rather than just an
            // error message. The banner at the top of the form also
            // exposes the same affordance.
            showUnlock = true
            return
        }
        do {
            let derived = try BitcoinDescriptors.deriveFromSeed(
                sandwich: sandwich,
                account: account,
                network: network,
                biometricReason: "Set up your Bitcoin wallet"
            )
            let descriptor = BitcoinWalletDescriptor(
                label: suffixedLabel,
                kind: .software(account: account),
                network: network,
                cachedAccountFingerprint: derived.accountFingerprint,
                cachedAccountXpub: derived.accountXpub
            )
            store.bitcoinWalletStore.add(descriptor, makeActive: true)
            dismiss()
            onCreated?()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @MainActor
    private func createHardware() async {
        guard let devId = selectedDeviceId,
              let dev = store.devices.find(id: devId)
        else {
            errorText = "Pick a device first."
            return
        }
        // Persist the hidden-wallet binding (writes a host-typed
        // passphrase to the Keychain). nil for the standard wallet and
        // for every Ledger add.
        let hidden = dev.kind == .trezor
            ? HardwarePassphraseRef.persist(selection: hwPassphrase)
            : nil
        // Custom derivation path (both vendors). nil = standard BIP84.
        // The purpose (44/49/84) selects the script type.
        let pathOverride = DerivationPathAdvancedField.resolve(useCustom: useCustomPath, customPath: customPath)
        if let p = pathOverride, !BIP32Path.isValid(p) {
            errorText = "Not a valid derivation path: \(p)"
            return
        }
        var suffix = hidden == nil ? "" : " (Hidden)"
        if pathOverride != nil { suffix += " (Custom path)" }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let suffixedLabel = trimmed.isEmpty
            ? "\(autoLabel(for: dev))\(suffix)"
            : "\(trimmed) #\(account)\(suffix)"

        let kindForFactory: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
        let client = HardwareWalletFactory.make(kind: kindForFactory)
        // A Trezor hidden wallet derives in its own passphrase session.
        // Ledger / mock clients ignore this.
        if let trezor = client as? TrezorBLE {
            trezor.applyPassphraseMode(hwPassphrase.choice(hostPassphrase: hwHostPassphrase))
        }
        client.setDerivationPathOverride(pathOverride)
        // Pin the BLE session across identify + fingerprint + xpub so
        // they share one connection. The Ledger doesn't reliably
        // survive 3 back-to-back reconnects on the same device.
        client.beginSession()
        defer { client.endSession() }
        do {
            let liveSerial = try await client.identifyDevice()
            guard liveSerial == dev.serial else {
                throw HardwareWalletError.transport(
                    "Connected device has serial \(liveSerial) which does not match the registered device. Reconnect the correct device or re-register this one."
                )
            }
            let fingerprint = try await client.getBitcoinMasterFingerprint(networkCoinType: network.coinType)
            let xpub = try await client.getBitcoinAccountXpub(
                account: account,
                networkCoinType: network.coinType
            )
            // Dedup against any existing hardware wallet on the same
            // (device, network) with the same xpub. The xpub is the
            // unique key, since `(device, account, network)` collapses
            // 1:1 to a single xpub from the device.
            if let existing = store.bitcoinWalletStore.wallets.first(where: { w in
                guard w.network == network,
                      case let .hardware(d, _, walletXpub) = w.kind,
                      d == dev.id else { return false }
                return walletXpub == xpub
            }) {
                errorText = "A wallet for \(dev.label) on \(network.displayName) at account #\(account) already exists, labelled \"\(existing.label)\". Use Discover existing wallets if you're trying to recover a different account."
                return
            }
            let descriptor = BitcoinWalletDescriptor(
                label: suffixedLabel,
                kind: .hardware(deviceId: dev.id, accountFingerprint: fingerprint, accountXpub: xpub),
                network: network,
                hidden: hidden,
                derivationPath: pathOverride
            )
            store.bitcoinWalletStore.add(descriptor, makeActive: true)
            store.devices.addBitcoinWallet(deviceId: dev.id, walletId: descriptor.id)
            dismiss()
            onCreated?()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

// MARK: -- DiscoverWalletsSheet

/// Sparrow-style "scan my seed for prior Bitcoin activity" flow. Walks
/// account indices 0...4 on mainnet (configurable to also include
/// testnet/signet via the network picker), surfaces per-account
/// progress, and lets the user pick which discovered accounts to add
/// as named wallets.
private struct DiscoverWalletsSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [BitcoinWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var alsoScanTestnets: Bool = false
    /// Per-account report shown after Add Selected runs: every
    /// discovered account either gets a "added" line or a "skipped,
    /// already labelled X" line. Keeps the user oriented when the
    /// list they expected to grow doesn't.
    @State private var addReport: [String]?

    var body: some View {
        NavigationStack {
            Form {
                if !scanning && discovered.isEmpty && progress.isEmpty {
                    Section {
                        Toggle("Also scan Testnet3 + Signet", isOn: $alsoScanTestnets)
                    } header: {
                        Text("Discovery")
                    } footer: {
                        Text("Scans accounts 0-4 on each selected network. Mainnet only by default; turn this on if you regularly use the public testnets.")
                            .font(.caption)
                    }
                    Section {
                        Button {
                            Task { await runScan() }
                        } label: {
                            Label("Start scan", systemImage: "magnifyingglass")
                        }
                        .disabled(store.sandwich == nil)
                    } footer: {
                        Text("Requires your biometric or passcode once. Scans against the configured Electrum endpoint for each network.")
                            .font(.caption)
                    }
                }

                if scanning || !progress.isEmpty {
                    Section("Progress") {
                        if scanning { progressRow }
                        ForEach(Array(progress.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }

                if !discovered.isEmpty {
                    Section {
                        ForEach(discovered, id: \.key) { acct in
                            Toggle(isOn: Binding(
                                get: { selection.contains(acct.key) },
                                set: { include in
                                    if include { selection.insert(acct.key) }
                                    else { selection.remove(acct.key) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(acct.network.displayName) - account \(acct.account)")
                                        .font(.callout.weight(.semibold))
                                    Text("\(acct.txCount) tx · \(formatSats(acct.balanceSat, ticker: acct.network.ticker))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Found activity")
                    } footer: {
                        Text("Selected accounts will be added to your wallet list. Existing accounts already on the list are skipped automatically.")
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

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Discover wallets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(scanning ? "Hide" : "Close") { dismiss() }
                }
            }
        }
    }

    private var progressRow: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Scanning…").font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func runScan() async {
        guard let sandwich = store.sandwich else {
            error = "Identity Sandwich is locked. Unlock Maknoon first."
            return
        }
        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil

        let networks: [BitcoinNetwork] = alsoScanTestnets
            ? [.mainnet, .testnet3, .signet]
            : [.mainnet]
        // Snapshot Electrum URLs into a Sendable dictionary BEFORE
        // entering the @Sendable closure so we don't carry the
        // non-Sendable BitcoinSettings reference across actor borders.
        let urls: [BitcoinNetwork: String] = Dictionary(
            uniqueKeysWithValues: networks.map { ($0, store.bitcoinSettings.electrumURL(for: $0)) }
        )
        let urlFor: @Sendable (BitcoinNetwork) -> String = { net in
            urls[net] ?? net.defaultElectrumURL
        }

        let onProgress: @Sendable (BitcoinWalletDiscovery.Progress) -> Void = { p in
            Task { @MainActor in
                let line: String
                switch p.phase {
                case .scanning:
                    line = "Scanning \(p.network.displayName) account \(p.account)…"
                case .completed(let n):
                    line = "\(p.network.displayName) account \(p.account): \(n) tx"
                }
                progress.append(line)
            }
        }

        do {
            // Pull the seed material on the main actor (Face ID gate
            // runs here) so the actor-isolated scan only sees plain
            // Sendable strings.
            let material = try sandwich.recoveryMaterial(
                localizedReason: "Discover existing Bitcoin wallets"
            )
            let words = material.words.joined(separator: " ")
            let pw: String? = material.hasPassphrase ? material.passphrase : nil
            let found = try await BitcoinWalletDiscovery.scan(
                mnemonicWords: words,
                passphrase: pw,
                networks: networks,
                maxAccount: 4,
                electrumURL: urlFor,
                onProgress: onProgress
            )
            // Pre-select all discovered accounts that are not already
            // present in the store.
            discovered = found
            let existing = Set(store.bitcoinWalletStore.wallets.compactMap { w -> String? in
                guard case let .software(account) = w.kind else { return nil }
                return "\(w.network.rawValue):\(account)"
            })
            for a in found where !existing.contains(a.key) {
                selection.insert(a.key)
            }
        } catch {
            self.error = "Scan failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        scanning = false
    }

    private func addSelected() {
        // Find the next free "BTC Wallet N" label index so the new
        // entries get sequential names.
        var nextN = nextBtcWalletIndex()
        var report: [String] = []
        for acct in discovered where selection.contains(acct.key) {
            // Skip if a wallet for this (network, account) already exists.
            let existing = store.bitcoinWalletStore.wallets.first { w in
                guard case let .software(a) = w.kind else { return false }
                return w.network == acct.network && a == acct.account
            }
            if let existing {
                report.append("Account \(acct.account) (\(acct.network.displayName)), already labelled \"\(existing.label)\", skipped.")
                continue
            }
            let label = "BTC Wallet \(nextN)"
            nextN += 1
            let descriptor = BitcoinWalletDescriptor(
                label: label,
                kind: .software(account: acct.account),
                network: acct.network
            )
            store.bitcoinWalletStore.add(descriptor, makeActive: false)
            report.append("Account \(acct.account) (\(acct.network.displayName)) added as \"\(label)\".")
        }
        addReport = report
    }

    private func nextBtcWalletIndex() -> Int {
        let used: [Int] = store.bitcoinWalletStore.wallets.compactMap {
            let parts = $0.label.split(separator: " ")
            guard parts.count == 3, parts[0] == "BTC", parts[1] == "Wallet" else { return nil }
            return Int(parts[2])
        }
        return (used.max() ?? 0) + 1
    }

    private func formatSats(_ sats: UInt64, ticker: String) -> String {
        let btc = Double(sats) / 100_000_000.0
        return String(format: "%.8f %@", btc, ticker)
    }
}

private extension BitcoinWalletDiscovery.DiscoveredAccount {
    /// Stable key for SwiftUI selection sets + de-duplication.
    var key: String { "\(network.rawValue):\(account)" }
}
