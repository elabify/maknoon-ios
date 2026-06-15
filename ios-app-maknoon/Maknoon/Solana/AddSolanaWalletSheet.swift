// Add-Solana-wallet flow. Mirrors AddEthereumWalletSheet: a Source
// picker switches between Software (derive from sandwich seed) and
// Hardware (pair with a Ledger / Trezor that supports Solana). When
// the Identity Sandwich is locked, the software path pivots to a
// single "Unlock with hardware device" affordance via
// HardwareUnlockView; the hardware path remains usable because it
// does not need the master seed.

import SwiftUI

struct AddSolanaWalletSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onCreated: (SolanaWalletDescriptor?) -> Void

    enum Source: String, CaseIterable, Identifiable {
        case software = "Software"
        case hardware = "Hardware"
        var id: String { rawValue }
    }

    @State private var source: Source = .software
    @State private var label: String = ""
    @State private var initialNetwork: SolanaNetwork = .mainnet
    @State private var account: UInt32 = 0
    /// Trezor-only hidden-wallet selector. `.standard` reproduces exact
    /// Ledger behavior (empty passphrase).
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
    @State private var creating: Bool = false
    @State private var errorText: String?
    @State private var showUnlock: Bool = false
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var pendingReadyDiscover: PendingHardwareOperation?
    @State private var showSoftwareDiscover: Bool = false
    @State private var hardwareDiscoverSource: DiscoverSolanaWalletsView.Source?

    private var solanaDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.solana)
    }

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
                    if let devId = selectedDeviceId,
                       let dev = store.devices.find(id: devId) {
                        hardwareWalletSection(dev)
                        hardwareCreateSection
                        hardwareDiscoverSection(dev)
                    }
                }
            }
            .navigationTitle("Add Solana wallet")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if !didSeedSoftwareAccount {
                    seedSoftwareAccount()
                    didSeedSoftwareAccount = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCreated(nil)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showUnlock) {
                HardwareUnlockView(enrollments: store.pendingHardwareUnlock)
                    .environment(store)
            }
            .sheet(isPresented: $showSoftwareDiscover) {
                NavigationStack {
                    DiscoverSolanaWalletsView(
                        network: initialNetwork,
                        source: .software,
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
                    DiscoverSolanaWalletsView(
                        network: initialNetwork,
                        source: src,
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
            .sheet(item: $pendingReadyDiscover) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: {
                        hardwareDiscoverSource = .hardware(deviceId: op.device.id)
                    },
                    onCancel: {}
                )
            }
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
    private var lockedBannerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Identity Sandwich is locked", systemImage: "lock.shield.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Software wallets derive from your master seed and need the Sandwich unlocked. Hardware wallets do not. Tap below to unlock, or switch the Source to Hardware.")
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

    @ViewBuilder
    private var hardwareDeviceSection: some View {
        if solanaDevices.isEmpty {
            Section("Device") {
                Text("No Solana-capable hardware devices registered. Add one from Settings → Devices first. Ledger Nano X supports Solana.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Device") {
                Picker("Device", selection: $selectedDeviceId) {
                    Text("Pick a device").tag(UUID?.none)
                    ForEach(solanaDevices) { dev in
                        Text("\(dev.label) (\(dev.kind.displayName))").tag(Optional(dev.id))
                    }
                }
            }
        }
    }

    private var softwareWalletSection: some View {
        Section {
            TextField("Label (e.g. Daily)", text: $label)
            Picker("Open on", selection: $initialNetwork) {
                ForEach(SolanaNetwork.allCases, id: \.self) { n in
                    Text(n.displayName).tag(n)
                }
            }
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
                    Text(creating ? "Setting up…" : "Create wallet")
                }
            }
            .disabled(creating || !canCreate || softwareAccountInUse)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("New Solana wallet")
        } footer: {
            Text("The same wallet works on every Solana cluster; \"Open on\" picks which one opens first. The account number fills in automatically to the next free one. You'll confirm with biometric or passcode once.")
                .font(.caption)
        }
    }

    private func seedSoftwareAccount() {
        softwareAccount = store.solanaWalletStore.nextSoftwareAccount()
    }

    private var softwareAccountInUse: Bool {
        store.solanaWalletStore.hasSoftwareWallet(account: softwareAccount)
    }

    private func hardwareWalletSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Picker("Open on", selection: $initialNetwork) {
                ForEach(SolanaNetwork.allCases, id: \.self) { n in
                    Text(n.displayName).tag(n)
                }
            }
            Stepper("Account #\(account)", value: $account, in: 0...255)
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
                standardPath: BIP32Path.standardSolana(account: account),
                useCustom: $useCustomPath,
                customPath: $customPath
            )
        } header: {
            Text("New Solana wallet")
        } footer: {
            Text(dev.kind == .trezor
                ? hwPassphrase.footer
                : "Leave the label blank to use \"\(autoLabel(for: dev))\". The address is the same on every Solana cluster; \"Open on\" picks which one the wallet opens to first.")
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
                    Text(creating ? "Setting up…" : "Create single wallet")
                }
            }
            .disabled(creating || !canCreate)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } footer: {
            Text("Imports just account #\(account) from the selected device. Use Discover existing wallets below if you don't know which accounts already hold value.")
                .font(.caption)
        }
    }

    private var softwareDiscoverSection: some View {
        Section {
            Button {
                showSoftwareDiscover = true
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
            .disabled(store.sandwich == nil)
        } footer: {
            Text("Scans accounts on \(initialNetwork.displayName) under your Identity Sandwich seed until 4 consecutive empty accounts are found, then stops. Use this when restoring from a backup that already has on-chain activity.")
                .font(.caption)
        }
    }

    private func hardwareDiscoverSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Button {
                if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                    pendingReadyDiscover = PendingHardwareOperation(
                        device: dev,
                        purpose: .solanaDiscover
                    )
                } else {
                    hardwareDiscoverSource = .hardware(deviceId: dev.id)
                }
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("Walks accounts from this device on \(initialNetwork.displayName) until 4 consecutive empty accounts are found, then stops.")
                .font(.caption)
        }
    }

    private func autoLabel(for dev: RegisteredDevice) -> String {
        "\(dev.label) #\(account)"
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
            guard let devId = selectedDeviceId,
                  let dev = store.devices.find(id: devId) else {
                errorText = "Pick a device first."
                return
            }
            if let existing = existingHardwareWallet(deviceId: dev.id, account: account) {
                errorText = "A wallet for \(dev.label) at account #\(account) already exists, labelled \"\(existing.label)\". Use Discover existing wallets if you're trying to recover a different account."
                return
            }
            if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .solanaWallet
                )
            } else {
                creating = true
                await createHardware()
                creating = false
            }
        }
    }

    private func existingHardwareWallet(deviceId: UUID, account: UInt32) -> SolanaWalletDescriptor? {
        store.solanaWalletStore.wallets.first { w in
            guard case let .hardware(d, a, _) = w.kind else { return false }
            return d == deviceId && a == account
        }
    }

    @MainActor
    private func createSoftware() async {
        guard let sandwich = store.sandwich else {
            showUnlock = true
            return
        }
        let account = softwareAccount
        // Never create a second software wallet at the same account: it
        // would derive the identical keypair and address.
        if store.solanaWalletStore.hasSoftwareWallet(account: account) {
            errorText = "A software wallet at account \(account) already exists. Pick a different account number."
            return
        }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let baseLabel = trimmed.isEmpty ? "Solana" : trimmed
        do {
            _ = try SolanaDescriptors.addressFromSandwich(
                sandwich: sandwich,
                account: account,
                biometricReason: "Create \(baseLabel)"
            )
            let descriptor = SolanaWalletDescriptor(
                label: baseLabel,
                kind: .software(account: account)
            )
            store.solanaWalletStore.add(descriptor, initialNetwork: initialNetwork)
            onCreated(descriptor)
            dismiss()
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
        if dev.kind == .trezor, !hwPassphrase.isReady(hostPassphrase: hwHostPassphrase) {
            errorText = "Enter the hidden-wallet passphrase first."
            return
        }
        // Persist the hidden-wallet binding (writes a host-typed
        // passphrase to the Keychain). nil for the standard wallet and
        // for every Ledger add.
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

        // A hidden or custom-path wallet shares the account index with
        // the standard one but derives a different address, so the
        // account-based pre-check is skipped for it; the address-based
        // check below catches a true duplicate after derivation.
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
            let publicKey = try await hardware.getSolanaAddress(account: account)
            // Address-based dedup catches a hidden wallet that resolves
            // to an address already on file.
            if let existing = store.solanaWalletStore.wallets.first(where: {
                guard case let .hardware(d, _, pk) = $0.kind else { return false }
                return d == dev.id && pk == publicKey
            }) {
                errorText = "This wallet (\(publicKey.prefix(6))…) already exists, labelled \"\(existing.label)\"."
                return
            }
            let descriptor = SolanaWalletDescriptor(
                label: suffixedLabel,
                kind: .hardware(deviceId: dev.id, account: account, publicKeyBase58: publicKey),
                hidden: hidden,
                derivationPath: pathOverride
            )
            store.solanaWalletStore.add(descriptor, initialNetwork: initialNetwork)
            store.devices.addSolanaWallet(deviceId: dev.id, walletId: descriptor.id)
            onCreated(descriptor)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
