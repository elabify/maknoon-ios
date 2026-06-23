// Add-Tron-wallet flow (ADR-0033 universal Add-wallet anatomy, identical
// to the Android reference per source). Tron is chain-agnostic (coinType
// 195), so there is NO network picker in the create path; the network
// dropdown appears ONLY in the Auto-Discovery scan subsection. Tron
// supports BOTH Ledger and Trezor.
//
//   Software : Wallet Label -> Account -> Add wallet, then a divider +
//              Auto Discovery (software sweep, network dropdown).
//   Hardware : Device chips + inline "Add New Device" -> Account (Ledger:
//              stepper; Trezor: fixed 0) -> readiness card -> Add wallet,
//              then a divider + Auto Discovery (device sweep, network
//              dropdown).
//   Passphrase (Trezor): collected in the connection step
//              (DeviceReadyConfirmationSheet) on Add / Discover tap; the
//              one choice applies to both. Ledger has no passphrase step.
//
// UI copy says "second factor" / "security key", never "Identity Sandwich".

import SwiftUI

struct AddTronWalletSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onCreated: (TronWalletDescriptor?) -> Void

    enum Source: String, CaseIterable, Identifiable {
        case software = "Software"
        case hardware = "Hardware"
        var id: String { rawValue }
    }

    @State private var source: Source = .software
    @State private var label: String = ""
    @State private var account: UInt32 = 0
    /// Trezor-only hidden-wallet selection, collected in the connection
    /// step (not inline). `.standard` reproduces exact Ledger behavior.
    @State private var hwPassphrase: HiddenWalletSelection = .standard
    /// Host-typed passphrase, used only when `hwPassphrase == .hostTyped`.
    @State private var hwHostPassphrase: String = ""
    /// Advanced custom derivation path (both vendors). Blank = standard.
    @State private var useCustomPath: Bool = false
    @State private var customPath: String = ""
    /// Software-path account index, kept separate from the hardware
    /// `account` so each path has its own default. Seeded once to the
    /// next free account so the default never duplicates an existing
    /// wallet; the user can still adjust it.
    @State private var softwareAccount: UInt32 = 0
    @State private var didSeedSoftwareAccount = false
    @State private var selectedDeviceId: UUID?
    /// Auto-Discovery "scan network" for both software and hardware
    /// discover, independent of the (now removed) create-path network.
    @State private var scanNetwork: TronNetwork = .mainnet
    @State private var creating: Bool = false
    @State private var errorText: String?
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var pendingReadyDiscover: PendingHardwareOperation?
    @State private var showSoftwareDiscover: Bool = false
    @State private var hardwareDiscoverSource: DiscoverTronWalletsView.Source?
    @State private var showAddDevice: Bool = false

    private var tronDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.tron)
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
            .navigationTitle("Add Tron wallet")
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
                    Button("Cancel") {
                        onCreated(nil)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAddDevice) {
                NavigationStack {
                    AddHardwareDeviceFlow(
                        kinds: DeviceKind.walletCapableRegistrableCases
                    ) { registered in
                        showAddDevice = false
                        if registered {
                            // Land on the freshly registered Tron-capable
                            // device so the user can add its wallet at once.
                            source = .hardware
                            if let dev = tronDevices.last {
                                selectedDeviceId = dev.id
                            }
                        }
                    }
                    .environment(store)
                    .navigationTitle("Add New Device")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showSoftwareDiscover) {
                NavigationStack {
                    DiscoverTronWalletsView(
                        network: scanNetwork,
                        source: .software,
                        passphrase: .constant(.standard),
                        hostPassphrase: .constant(""),
                        onCompleted: {
                            onCreated(nil)
                            dismiss()
                        }
                    )
                    .environment(store)
                }
            }
            .sheet(item: $hardwareDiscoverSource) { src in
                NavigationStack {
                    DiscoverTronWalletsView(
                        network: scanNetwork,
                        source: src,
                        passphrase: $hwPassphrase,
                        hostPassphrase: $hwHostPassphrase,
                        onCompleted: {
                            onCreated(nil)
                            dismiss()
                        }
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
                        hardwareDiscoverSource = .hardware(deviceId: op.device.id)
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

    private var sourceFooter: String {
        switch source {
        case .software:
            return "Creates a wallet on this iPhone. One biometric or passcode confirmation at setup; everyday use is silent."
        case .hardware:
            return "Pairs a wallet with a Ledger or Trezor you've registered. Sending requires the device to confirm each transaction."
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

    @ViewBuilder
    private var hardwareDeviceSection: some View {
        if tronDevices.isEmpty {
            Section("Device") {
                Text("No Ledger or security key is registered yet. Register one to add its Tron wallet.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add New Device", systemImage: "plus")
                }
            }
        } else {
            Section("Device") {
                // Selectable device rows (ADR-0033 FilterChips), label
                // "<dev.label> (<kind.displayName>)". Tapping a row selects
                // it; the active row shows a leading checkmark.
                ForEach(tronDevices) { dev in
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
                Text("Account \(softwareAccount) is already in your wallets. Pick another to avoid a duplicate.")
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
            Text("New Tron wallet")
        } footer: {
            Text("The same wallet works on every Tron network; switch networks from the wallet screen.")
                .font(.caption)
        }
    }

    private func seedSoftwareAccount() {
        softwareAccount = store.tronWalletStore.nextSoftwareAccount()
    }

    private var softwareAccountInUse: Bool {
        store.tronWalletStore.hasSoftwareWallet(account: softwareAccount)
    }

    private func hardwareWalletSection(_ dev: RegisteredDevice) -> some View {
        Section {
            TextField(autoLabel(for: dev), text: $label)
            if dev.kind == .trezor {
                Text("Account 0.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("Account #\(account)", value: $account, in: 0...255)
            }
            DerivationPathAdvancedField(
                standardPath: BIP32Path.standardTron(account: effectiveAccount),
                useCustom: $useCustomPath,
                customPath: $customPath
            )
        } header: {
            Text("New Tron wallet")
        } footer: {
            Text("Leave the label blank to use \"\(autoLabel(for: dev))\". The same wallet works on every Tron network; switch networks from the wallet screen.")
                .font(.caption)
        }
    }

    private func hardwareCreateSection(_ dev: RegisteredDevice) -> some View {
        Section {
            // Device-readiness card (ADR-0033): how to ready the device,
            // no passphrase copy (that lives in the connection step).
            Text(dev.kind == .ledger
                ? "Unlock the Ledger and open the Tron app, then tap Add wallet."
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
            Picker("Chain to scan", selection: $scanNetwork) {
                ForEach(TronNetwork.allCases, id: \.self) { n in
                    Text(n.displayName).tag(n)
                }
            }
            Button {
                showSoftwareDiscover = true
            } label: {
                Label("Discover existing wallets", systemImage: "magnifyingglass")
            }
            .disabled(store.sandwich == nil)
        } header: {
            Text("Auto Discovery")
        } footer: {
            Text("Scans for your Tron accounts on \(scanNetwork.displayName) that already have history, so you can re-add wallets created previously.")
                .font(.caption)
        }
    }

    private func hardwareDiscoverSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Picker("Chain to scan", selection: $scanNetwork) {
                ForEach(TronNetwork.allCases, id: \.self) { n in
                    Text(n.displayName).tag(n)
                }
            }
            Button {
                if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                    pendingReadyDiscover = PendingHardwareOperation(
                        device: dev,
                        purpose: .tronDiscover
                    )
                } else {
                    hardwareDiscoverSource = .hardware(deviceId: dev.id)
                }
            } label: {
                Label("Discover existing wallets", systemImage: "magnifyingglass")
            }
        } header: {
            Text("Auto Discovery")
        } footer: {
            Text("Scans this device for your Tron accounts on \(scanNetwork.displayName) that already have history, so you can re-add wallets created previously.")
                .font(.caption)
        }
    }

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
            // Trezor is fixed to account 0 and may add a hidden wallet (a
            // distinct address at the same index), so the account-based
            // pre-check is skipped for it; the address-based dedup in
            // createHardware catches a true duplicate after derivation.
            // Ledger has no hidden wallets, so the early check is safe.
            if dev.kind != .trezor,
               let existing = existingHardwareWallet(deviceId: dev.id, account: effectiveAccount) {
                errorText = "A wallet for \(dev.label) at account #\(effectiveAccount) already exists, labelled \"\(existing.label)\"."
                return
            }
            if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .tronWallet
                )
            } else {
                creating = true
                await createHardware()
                creating = false
            }
        }
    }

    private func existingHardwareWallet(deviceId: UUID, account: UInt32) -> TronWalletDescriptor? {
        store.tronWalletStore.wallets.first { w in
            guard case let .hardware(d, a, _) = w.kind else { return false }
            return d == deviceId && a == account
        }
    }

    @MainActor
    private func createSoftware() async {
        guard let sandwich = store.sandwich else {
            errorText = "Software wallets derive from your master seed and need your identity unlocked. Unlock from the Identity tab, or switch the Source to Hardware."
            return
        }
        let account = softwareAccount
        // Never create a second software wallet at the same account: it
        // would derive the identical keypair and address.
        if store.tronWalletStore.hasSoftwareWallet(account: account) {
            errorText = "A software wallet at account \(account) already exists. Pick a different account number."
            return
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let baseLabel = trimmed.isEmpty ? "Tron" : trimmed
        do {
            _ = try TronDescriptors.addressFromSandwich(
                sandwich: sandwich,
                account: account,
                biometricReason: "Create \(baseLabel)"
            )
            let descriptor = TronWalletDescriptor(
                label: baseLabel,
                kind: .software(account: account)
            )
            store.tronWalletStore.add(descriptor)
            onCreated(descriptor)
            dismiss()
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
        // A hidden or custom-path wallet shares the account index but
        // derives a different address, so the account-based pre-check is
        // skipped; the address-based check below catches a true dup.
        if hidden == nil, pathOverride == nil,
           let existing = existingHardwareWallet(deviceId: dev.id, account: account) {
            errorText = "A wallet for \(dev.label) at account #\(account) already exists, labelled \"\(existing.label)\"."
            return
        }
        let kind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
        let hardware = HardwareWalletFactory.make(kind: kind)
        // A Trezor hidden wallet derives in its own passphrase session.
        if let trezor = hardware as? TrezorBLE {
            trezor.applyPassphraseMode(hwPassphrase.choice(hostPassphrase: hwHostPassphrase))
        }
        hardware.setDerivationPathOverride(pathOverride)
        hardware.beginSession()
        defer { hardware.endSession() }
        do {
            let identifiedSerial = try await hardware.identifyDevice()
            guard identifiedSerial == dev.serial else {
                throw HardwareWalletError.transport(
                    "Connected device serial \(identifiedSerial) does not match registered \(dev.serial)"
                )
            }
            let address = try await hardware.getTronAddress(account: account)
            // Address-based dedup catches a hidden wallet that resolves
            // to an address already on file.
            if let existing = store.tronWalletStore.wallets.first(where: {
                guard case let .hardware(d, _, addr) = $0.kind else { return false }
                return d == dev.id && addr == address
            }) {
                errorText = "This wallet (\(address.prefix(8))…) already exists, labelled \"\(existing.label)\"."
                return
            }
            let descriptor = TronWalletDescriptor(
                label: suffixedLabel,
                kind: .hardware(deviceId: dev.id, account: account, addressBase58Check: address),
                hidden: hidden,
                derivationPath: pathOverride
            )
            store.tronWalletStore.add(descriptor)
            store.devices.addTronWallet(deviceId: dev.id, walletId: descriptor.id)
            onCreated(descriptor)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

