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
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
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

// MARK: -- AddBitcoinWalletSheet

// Add-Bitcoin-wallet flow (ADR-0033 universal Add-wallet anatomy,
// identical to the Android Bitcoin reference per source). Bitcoin is
// the SPECIAL chain: its chain selection is load-bearing (coinType 0
// for Mainnet, 1 for Testnet3 / Signet, which changes the derived
// xpub/address), so a single **Chain** dropdown sits at the TOP of the
// form, above the Source picker, driving ONE shared `network` state used
// by software create, hardware add, AND both Auto Discovery sweeps.
// Bitcoin supports BOTH Ledger and Trezor.
//
//   Top      : Chain dropdown (Mainnet / Testnet3 / Signet).
//   Source   : Software | Hardware.
//   Software : Wallet Label -> Account -> Add wallet, then a divider +
//              Auto Discovery (software seed sweep on the chosen chain).
//   Hardware : Device rows + inline "Add New Device" -> Account (Ledger:
//              stepper; Trezor: fixed 0) -> readiness card -> Add wallet,
//              then a divider + Auto Discovery (device sweep, BIP44/49/84
//              per account).
//   Passphrase (Trezor): collected in the connection step
//              (DeviceReadyConfirmationSheet) on Add / Discover tap; the
//              one choice applies to both. Ledger has no passphrase step.
//
// UI copy says "second factor" / "security key", never "Identity Sandwich".

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
    /// ONE shared chain at the top of the form (Bitcoin is the only chain
    /// with this), driving software create, hardware add, and BOTH Auto
    /// Discovery sweeps, because its coinType is load-bearing.
    @State private var network: BitcoinNetwork = .mainnet
    @State private var selectedDeviceId: UUID?
    @State private var account: UInt32 = 0
    @State private var useCustomPath: Bool = false
    @State private var customPath: String = ""
    /// Trezor-only hidden-wallet selection, collected in the connection
    /// step (not inline). `.standard` reproduces exact Ledger behavior.
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
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var pendingReadyDiscover: PendingHardwareOperation?
    @State private var showSoftwareDiscovery: Bool = false
    @State private var hardwareDiscoverDevice: RegisteredDevice?
    @State private var showAddDevice: Bool = false

    private var bitcoinDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.bitcoin)
    }

    private var selectedDevice: RegisteredDevice? {
        guard let id = selectedDeviceId else { return nil }
        return store.devices.find(id: id)
    }

    private var isTrezor: Bool { selectedDevice?.kind == .trezor }

    /// Trezor's account is fixed to 0 (a hidden-wallet passphrase makes
    /// the index ambiguous); Ledger keeps the 0..N stepper.
    private var effectiveAccount: UInt32 { isTrezor ? 0 : account }

    var body: some View {
        NavigationStack {
            Form {
                if store.sandwich == nil && source == .software {
                    lockedBannerSection
                }
                bitcoinChainSection
                Section("Source") {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: source) { _, _ in errorText = nil }
                    Text(sourceFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if source == .software {
                    softwareWalletSection
                    softwareDiscoverSection
                } else {
                    hardwareDeviceSection
                    if let dev = selectedDevice {
                        hardwareWalletSection(dev)
                        hardwareCreateSection(dev)
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
            .onChange(of: selectedDeviceId) { _, _ in
                // A fresh device selection starts from the standard wallet;
                // the passphrase choice is re-collected in the connection step.
                hwPassphrase = .standard
                hwHostPassphrase = ""
                errorText = nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddDevice) {
                NavigationStack {
                    AddHardwareDeviceFlow(
                        kinds: DeviceKind.walletCapableRegistrableCases
                    ) { registered in
                        showAddDevice = false
                        if registered {
                            // Land on the freshly registered Bitcoin-capable
                            // device so the user can add its wallet at once.
                            source = .hardware
                            if let dev = bitcoinDevices.last {
                                selectedDeviceId = dev.id
                            }
                        }
                    }
                    .environment(store)
                    .navigationTitle("Add New Device")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showSoftwareDiscovery) {
                DiscoverWalletsSheet(network: network)
                    .environment(store)
            }
            .sheet(item: $hardwareDiscoverDevice) { dev in
                NavigationStack {
                    DiscoverHardwareWalletsView(
                        device: dev,
                        network: network,
                        hwPassphrase: $hwPassphrase,
                        hwHostPassphrase: $hwHostPassphrase
                    )
                    .environment(store)
                }
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    showsPassphraseSelector: op.device.kind == .trezor,
                    onContinue: {
                        Task { @MainActor in
                            creating = true
                            await createHardware()
                            creating = false
                        }
                    },
                    onCancel: {},
                    onPassphraseSelection: { sel, pass in
                        hwPassphrase = sel
                        hwHostPassphrase = pass
                    }
                )
            }
            .sheet(item: $pendingReadyDiscover) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    showsPassphraseSelector: op.device.kind == .trezor,
                    onContinue: {
                        hardwareDiscoverDevice = op.device
                    },
                    onCancel: {},
                    onPassphraseSelection: { sel, pass in
                        hwPassphrase = sel
                        hwHostPassphrase = pass
                    }
                )
            }
        }
    }

    /// The single Chain dropdown at the top of Add Bitcoin wallet
    /// (ADR-0033): Mainnet / Testnet3 / Signet. Bitcoin is the only chain
    /// with this because its coinType is load-bearing (it changes the
    /// derived xpub/address). Re-seeds the per-network software account
    /// when the chain changes.
    private var bitcoinChainSection: some View {
        Section {
            Picker("Chain", selection: $network) {
                ForEach(BitcoinNetwork.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .onChange(of: network) { _, _ in
                // Account space is per-network for Bitcoin, so re-seed
                // to the new network's next free account when it changes.
                seedSoftwareAccount()
                errorText = nil
            }
        } footer: {
            Text("Bitcoin's chain is load-bearing: Mainnet, Testnet3, and Signet derive different addresses, so pick it before you add or discover.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var lockedBannerSection: some View {
        Section {
            Text("Software wallets derive from your master seed and need your identity unlocked. Unlock from the Identity tab, or switch the Source to Hardware.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var sourceFooter: String {
        switch source {
        case .software:
            return "Creates a wallet on this iPhone. One biometric or passcode confirmation at setup; everyday use is silent."
        case .hardware:
            return "Pairs a wallet with a Ledger or Trezor you've registered. Sending requires the device to confirm each transaction."
        }
    }

    @ViewBuilder
    private var hardwareDeviceSection: some View {
        if bitcoinDevices.isEmpty {
            Section("Device") {
                Text("No Ledger or security key is registered yet. Register one to add its Bitcoin wallet.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add New Device", systemImage: "plus")
                }
            }
        } else {
            Section("Device") {
                // Selectable device rows (ADR-0033), label
                // "<dev.label> (<kind.displayName>)". Tapping a row selects
                // it; the active row shows a leading checkmark.
                ForEach(bitcoinDevices) { dev in
                    Button {
                        selectedDeviceId = dev.id
                    } label: {
                        HStack {
                            Image(systemName: dev.id == selectedDeviceId
                                ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(dev.id == selectedDeviceId ? Color.accentColor : Color.secondary)
                            Text("\(dev.label) (\(dev.kind.displayName))")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add New Device", systemImage: "plus")
                }
            }
        }
    }

    private var softwareWalletSection: some View {
        Section {
            TextField("Wallet Label", text: $label)
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
                    Text(creating ? "Setting up…" : "Add wallet")
                }
            }
            .disabled(creating || !canCreate || softwareAccountInUse)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("New Bitcoin wallet")
        } footer: {
            Text("The account number fills in automatically to the next free one on this chain. You'll confirm with biometric or passcode once.")
                .font(.caption)
        }
    }

    private func seedSoftwareAccount() {
        softwareAccount = store.bitcoinWalletStore.nextSoftwareAccount(on: network)
    }

    private var softwareAccountInUse: Bool {
        store.bitcoinWalletStore.hasSoftwareWallet(account: softwareAccount, on: network)
    }

    private func hardwareWalletSection(_ dev: RegisteredDevice) -> some View {
        Section {
            TextField(autoLabel(for: dev), text: $label)
            if dev.kind == .trezor {
                Text("Account 0.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("Account #\(account)", value: $account, in: 0...20)
            }
            DerivationPathAdvancedField(
                standardPath: BIP32Path.standardBitcoin(account: effectiveAccount, coinType: network.coinType),
                useCustom: $useCustomPath,
                customPath: $customPath
            )
        } header: {
            Text("New Bitcoin wallet")
        } footer: {
            Text("Leave the label blank to use \"\(autoLabel(for: dev))\".")
                .font(.caption)
        }
    }

    private func hardwareCreateSection(_ dev: RegisteredDevice) -> some View {
        Section {
            // Device-readiness card (ADR-0033): how to ready the device,
            // no passphrase copy (that lives in the connection step).
            Text(dev.kind == .ledger
                ? "Unlock the Ledger and open the Bitcoin app (Bitcoin Test for Testnet3 / Signet), then tap Add wallet."
                : "Unlock your Trezor, then tap Add wallet.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if creating { ProgressView().controlSize(.small) }
                    Text(creating ? "Setting up…" : "Add wallet")
                }
            }
            .disabled(creating || !canCreate)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var softwareDiscoverSection: some View {
        Section {
            Button {
                showSoftwareDiscovery = true
            } label: {
                Label("Discover existing wallets", systemImage: "magnifyingglass")
            }
            .disabled(store.sandwich == nil)
        } header: {
            Text("Auto Discovery")
        } footer: {
            Text("Scans for your Bitcoin accounts on \(network.displayName) that already have history, so you can re-add wallets created previously.")
                .font(.caption)
        }
    }

    private func hardwareDiscoverSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Button {
                if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                    pendingReadyDiscover = PendingHardwareOperation(
                        device: dev,
                        purpose: .bitcoinDiscover(network: network)
                    )
                } else {
                    hardwareDiscoverDevice = dev
                }
            } label: {
                Label("Discover existing wallets", systemImage: "magnifyingglass")
            }
        } header: {
            Text("Auto Discovery")
        } footer: {
            Text("Scans this device for your Bitcoin accounts on \(network.displayName) that already have history, so you can re-add wallets created previously.")
                .font(.caption)
        }
    }

    /// Default label used when the user leaves the Label field blank
    /// on the hardware path. Format: "DeviceName #N" (iOS-style default
    /// hardware label, consistent with the other chains).
    private func autoLabel(for dev: RegisteredDevice) -> String {
        "\(dev.label) #\(effectiveAccount)"
    }

    private var canCreate: Bool {
        switch source {
        case .software: return store.sandwich != nil
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
            guard let dev = selectedDevice else {
                errorText = "Pick a device first."
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
        let baseLabel = trimmed.isEmpty ? "Bitcoin" : trimmed
        let suffixedLabel = "\(baseLabel) #\(account)"

        // Never create a second software wallet at the same (network,
        // account): it would derive the identical address.
        if store.bitcoinWalletStore.hasSoftwareWallet(account: account, on: network) {
            errorText = "A software wallet at account #\(account) on \(network.displayName) already exists. Pick a different account number."
            return
        }

        guard let sandwich = store.sandwich else {
            errorText = "Software wallets derive from your master seed and need your identity unlocked. Unlock from the Identity tab, or switch the Source to Hardware."
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
        guard let dev = selectedDevice else {
            errorText = "Pick a device first."
            return
        }
        let account = effectiveAccount
        if dev.kind == .trezor, !hwPassphrase.isReady(hostPassphrase: hwHostPassphrase) {
            errorText = "Enter the hidden-wallet passphrase first."
            return
        }
        // Persist the hidden-wallet binding (records only the entry
        // method; the secret is never stored). nil for the standard
        // wallet and for every Ledger add.
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
/// account indices 0...4 on the chain chosen at the top of the Add form
/// (Bitcoin's chain is load-bearing, so the sweep inherits it rather
/// than offering its own picker), surfaces per-account progress, and
/// lets the user pick which discovered accounts to add as named wallets.
private struct DiscoverWalletsSheet: View {
    /// Chain to scan, inherited from the Add form's top-level Chain
    /// dropdown (ADR-0033: the chain is load-bearing, chosen once).
    let network: BitcoinNetwork

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var scanning: Bool = false
    @State private var progress: [String] = []
    @State private var discovered: [BitcoinWalletDiscovery.DiscoveredAccount] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
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
            error = "Maknoon is locked. Unlock Maknoon first."
            return
        }
        scanning = true
        progress = []
        discovered = []
        selection = []
        error = nil

        // The chain is chosen once at the top of the Add form (Bitcoin's
        // chain is load-bearing), so the sweep scans only that chain.
        let networks: [BitcoinNetwork] = [network]
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
