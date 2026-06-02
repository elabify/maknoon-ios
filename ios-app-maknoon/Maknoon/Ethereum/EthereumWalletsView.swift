// Multi-wallet management for Ethereum. Mirrors BitcoinWalletsView:
// list every wallet, add software wallet, pair hardware wallet
// (hardware add flow lives in the Devices screen / per-device
// detail, same as Bitcoin).

import SwiftUI

struct EthereumWalletsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSoftware = false
    @State private var renameTarget: EthereumWalletDescriptor?
    @State private var renameDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Wallets") {
                    ForEach(store.ethereumWalletStore.wallets) { w in
                        row(for: w)
                    }
                    .onMove { offsets, dest in
                        store.ethereumWalletStore.move(
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
            .navigationTitle("Ethereum wallets")
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
                AddEthereumWalletSheet()
                    .environment(store)
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(target: target)
            }
        }
    }

    private func row(for w: EthereumWalletDescriptor) -> some View {
        Button {
            store.ethereumWalletStore.setActive(w.id)
        } label: {
            HStack(spacing: 12) {
                WalletThumbprint(
                    seed: w.address ?? w.id.uuidString,
                    size: 36,
                    systemImage: "diamond.fill"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.label).font(.headline)
                    Text(subtitle(for: w))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.ethereumWalletStore.activeWalletId == w.id {
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
                store.ethereumWalletStore.remove(id: w.id)
                // Clear the wallet id from any device's promotion
                // list so the Settings > Devices badge stops showing
                // "Ethereum" once the last linked wallet is gone.
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

    private func subtitle(for w: EthereumWalletDescriptor) -> String {
        switch w.kind {
        case .software(let acct): return "Software · account \(acct)"
        case .hardware(_, let acct, _): return "Hardware · account \(acct)"
        }
    }

    @ViewBuilder
    private func renameSheet(target: EthereumWalletDescriptor) -> some View {
        NavigationStack {
            Form {
                Section("Wallet label") {
                    TextField("e.g. Daily", text: $renameDraft)
                }
                Section {
                    Button("Save") {
                        store.ethereumWalletStore.rename(id: target.id, to: renameDraft)
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
}

// MARK: -- AddEthereumWalletSheet

struct AddEthereumWalletSheet: View {
    var onCreated: (() -> Void)? = nil
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case software = "Software"
        case hardware = "Hardware"
        var id: String { rawValue }
    }

    @State private var source: Source = .software
    @State private var label = ""
    @State private var selectedDeviceId: UUID?
    @State private var account: UInt32 = 0
    @State private var creating = false
    @State private var errorText: String?
    @State private var discoverSource: DiscoverEthereumWalletsView.Source?
    @State private var showUnlock: Bool = false
    /// Populated when the user taps Create on the hardware tab.
    /// Drives the pre-tap "get the device ready" sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?
    /// Populated when the user taps Discover with a hardware device
    /// selected. Same sheet, different purpose copy.
    @State private var pendingReadyDiscover: PendingHardwareOperation?
    /// Initial network the wallet opens on after creation. Drives
    /// the per-wallet network selection map; not stored on the
    /// descriptor itself. Defaults to mainnet (or Sepolia for the
    /// software discover path, which is testnet-friendly).
    @State private var initialNetwork: EthereumNetwork = .mainnet

    private var ethereumDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.ethereum)
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
                    softwareCreateSection
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
            .navigationTitle("Add Ethereum wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showUnlock) {
                HardwareUnlockView(enrollments: store.pendingHardwareUnlock)
                    .environment(store)
            }
            .sheet(item: $discoverSource) { src in
                DiscoverEthereumWalletsView(
                    source: src,
                    network: initialNetwork,
                    onCompleted: {
                        dismiss()
                        onCreated?()
                    }
                )
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
            .sheet(item: $pendingReadyDiscover) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: {
                        discoverSource = .hardware(deviceId: op.device.id)
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

    @ViewBuilder
    private var hardwareDeviceSection: some View {
        if ethereumDevices.isEmpty {
            Section("Device") {
                Text("No hardware devices registered yet. Add one from Settings → Devices first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Device") {
                Picker("Device", selection: $selectedDeviceId) {
                    Text("Pick a device").tag(UUID?.none)
                    ForEach(ethereumDevices) { dev in
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
                Section {
                    ForEach(EthereumNetwork.displayOrdered.filter { !$0.isTestnet }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Section("Testnets") {
                    ForEach(EthereumNetwork.displayOrdered.filter { $0.isTestnet }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
        } header: {
            Text("New Ethereum wallet")
        } footer: {
            Text("The same wallet works on every EVM network, the initial choice just decides which one opens first. You can switch from the dropdown above the wallet's balance any time.")
                .font(.caption)
        }
    }

    private func hardwareWalletSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Picker("Open on", selection: $initialNetwork) {
                Section {
                    ForEach(EthereumNetwork.displayOrdered.filter { !$0.isTestnet }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Section("Testnets") {
                    ForEach(EthereumNetwork.displayOrdered.filter { $0.isTestnet }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            Stepper("Account #\(account)", value: $account, in: 0...255)
            TextField(autoLabel(for: dev), text: $label)
        } header: {
            Text("New Ethereum wallet")
        } footer: {
            Text("Leave the label blank to use \"\(autoLabel(for: dev))\". The address is the same on every EVM network; \"Open on\" picks which one the wallet opens to first.")
                .font(.caption)
        }
    }

    private var softwareCreateSection: some View {
        Section {
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if creating { ProgressView().controlSize(.small) }
                    Text(creating ? "Setting up…" : "Create")
                }
            }
            .disabled(creating || !canCreate)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
        } footer: {
            Text("You'll be asked to confirm with biometric or passcode once.")
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
            Text("Imports just account #\(account) from the selected device. Use Discover existing wallets below if you don't know which accounts already hold value.")
                .font(.caption)
        }
    }

    private var softwareDiscoverSection: some View {
        Section {
            Button {
                discoverSource = .software
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("Scans accounts on \(initialNetwork.displayName) until 4 consecutive empty accounts are found, then stops. Use this when restoring from a backup that already has on-chain activity.")
                .font(.caption)
        }
    }

    private func hardwareDiscoverSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Button {
                if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                    pendingReadyDiscover = PendingHardwareOperation(
                        device: dev,
                        purpose: .ethereumDiscover
                    )
                } else {
                    discoverSource = .hardware(deviceId: dev.id)
                }
            } label: {
                Label("Discover existing wallets…", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("Scans accounts on \(initialNetwork.displayName) from this device until 4 consecutive empty accounts are found, then stops.")
                .font(.caption)
        }
    }

    /// Default label used when the user leaves the Label field blank
    /// on the hardware path. Format: "DeviceName #N". No network in
    /// the label because the Ethereum address is the same on every
    /// EVM network the wallet later opens on.
    private func autoLabel(for dev: RegisteredDevice) -> String {
        "\(dev.label) #\(account)"
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
            // Pre-flight the dedup check so the user gets an instant
            // "already exists" error instead of being walked through
            // the readiness sheet + BLE roundtrip before the same
            // collision is caught inside createHardware.
            if let existing = existingHardwareWallet(deviceId: dev.id, account: account) {
                errorText = "A wallet for \(dev.label) at account #\(account) already exists, labelled \"\(existing.label)\". Use Discover existing wallets if you're trying to recover a different account."
                return
            }
            if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .ethereumWallet
                )
            } else {
                creating = true
                await createHardware()
                creating = false
            }
        }
    }

    /// Look up an existing hardware wallet for this (device, account)
    /// pair so the dedup error can name the existing label.
    private func existingHardwareWallet(deviceId: UUID, account: UInt32) -> EthereumWalletDescriptor? {
        store.ethereumWalletStore.wallets.first { w in
            guard case let .hardware(d, a, _) = w.kind else { return false }
            return d == deviceId && a == account
        }
    }

    @MainActor
    private func createSoftware() async {
        let account = store.ethereumWalletStore.nextSoftwareAccount()
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let baseLabel = trimmed.isEmpty ? "Wallet" : trimmed
        let suffixedLabel = "\(baseLabel) #\(account)"

        guard let sandwich = store.sandwich else {
            // Surface the unlock sheet inline rather than just an
            // error message. The banner at the top of the form also
            // exposes the same affordance.
            showUnlock = true
            return
        }
        do {
            let address = try EthereumDescriptors.addressFromSandwich(
                sandwich: sandwich,
                account: account,
                biometricReason: "Set up your Ethereum wallet"
            )
            let descriptor = EthereumWalletDescriptor(
                label: suffixedLabel,
                kind: .software(account: account),
                cachedAddress: address
            )
            store.ethereumWalletStore.add(descriptor, initialNetwork: initialNetwork, makeActive: true)
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
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let suffixedLabel = trimmed.isEmpty
            ? autoLabel(for: dev)
            : "\(trimmed) #\(account)"

        // Second-line defence in case the user races the form (rapid
        // double-tap of Create) and the pre-flight dedup in create()
        // missed it.
        if let existing = existingHardwareWallet(deviceId: dev.id, account: account) {
            errorText = "A wallet for \(dev.label) at account #\(account) already exists, labelled \"\(existing.label)\"."
            return
        }
        let kind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
        let hardware = HardwareWalletFactory.make(kind: kind)
        // Pin the BLE session for identify + getEthereumAddress so
        // they share one connection.
        hardware.beginSession()
        defer { hardware.endSession() }
        do {
            let identifiedSerial = try await hardware.identifyDevice()
            guard identifiedSerial == dev.serial else {
                throw HardwareWalletError.transport(
                    "Connected device serial \(identifiedSerial) does not match registered \(dev.serial)"
                )
            }
            let address = try await hardware.getEthereumAddress(account: account)
            let descriptor = EthereumWalletDescriptor(
                label: suffixedLabel,
                kind: .hardware(deviceId: dev.id, account: account, address: address),
                cachedAddress: address
            )
            store.ethereumWalletStore.add(descriptor, initialNetwork: initialNetwork, makeActive: true)
            store.devices.addEthereumWallet(deviceId: dev.id, walletId: descriptor.id)
            dismiss()
            onCreated?()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
