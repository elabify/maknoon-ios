// "Add a Bitcoin wallet from <hardware device>" flow.
//
// Steps the user walks through:
//   1. We re-connect to the device over its transport (BLE for
//      Ledger / Trezor) and confirm the serial matches what was
//      recorded at registration time.
//   2. We instruct the user to switch the device to the Bitcoin app
//      (Ledger Bitcoin app, Trezor's built-in Bitcoin firmware).
//   3. We fetch the BIP84 account-level xpub for a chosen account
//      index (default = next free index on the chosen network).
//   4. We build a watch-only BDK wallet from that xpub and append
//      it to BitcoinWalletStore with `kind = .hardware(deviceId,
//      fingerprint, xpub)`. The wallet appears immediately in the
//      Bitcoin wallet picker.
//
// The user can also pre-create a wallet against an account that does
// not yet hold any coins; the wallet starts at balance 0 and can be
// funded later.

import SwiftUI
import BitcoinDevKit

struct AddBitcoinWalletFromDeviceView: View {
    let device: RegisteredDevice
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var network: BitcoinNetwork = .mainnet
    @State private var accountIndex: UInt32 = 0
    @State private var label: String = ""
    @State private var status: String?
    @State private var phase: Phase = .ready
    @State private var errorText: String?
    /// Populated when the user taps "Connect and add wallet". Drives
    /// the pre-tap readiness sheet (Bitcoin app on the device).
    @State private var pendingReadyOp: PendingHardwareOperation?

    enum Phase { case ready, connecting, fetchingXpub, building, done }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: device.kind.systemImage)
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading) {
                        Text(device.label).font(.callout.weight(.semibold))
                        Text("\(device.kind.displayName) - \(device.serialDisplay)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Device")
            }

            Section {
                Picker("Network", selection: $network) {
                    ForEach(BitcoinNetwork.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Stepper("Account index: \(accountIndex)", value: $accountIndex, in: 0...20)
                TextField("Label (optional)", text: $label)
            } header: {
                Text("Wallet")
            }

            Section {
                NavigationLink {
                    DiscoverHardwareWalletsView(device: device, network: network)
                        .environment(store)
                } label: {
                    Label("Discover existing wallets on this device", systemImage: "magnifyingglass")
                }
            }

            Section {
                switch phase {
                case .ready:
                    instructionsForKind
                    Button {
                        if HardwareOperationPurpose.shouldPresent(for: device.kind) {
                            pendingReadyOp = PendingHardwareOperation(
                                device: device,
                                purpose: .bitcoinWallet(network: network)
                            )
                        } else {
                            Task { await addWallet() }
                        }
                    } label: {
                        Label("Connect and add wallet", systemImage: "plus.circle.fill")
                    }
                case .connecting:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(device.kind.displayName)…").font(.callout)
                    }
                case .fetchingXpub:
                    HStack {
                        ProgressView().controlSize(.small)
                        let appName = network == .mainnet ? "Bitcoin" : "Bitcoin Test"
                        Text("Open the \(appName) app on the \(device.kind.displayName) and approve the prompt…").font(.callout)
                    }
                case .building:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Building wallet…").font(.callout)
                    }
                case .done:
                    Label("Wallet added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Button("Done") { dismiss() }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Action")
            }
        }
        .navigationTitle("Add Bitcoin wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingReadyOp) { op in
            DeviceReadyConfirmationSheet(
                device: op.device,
                purpose: op.purpose,
                onContinue: { Task { await addWallet() } },
                onCancel: {}
            )
        }
        .onAppear {
            // Hardware wallets default to account 0. Hardware account
            // indices live in their own keyspace (each device's
            // master is independent of any software wallet) so we
            // don't try to find a "next-free" slot across the
            // software wallets — that's the bug that previously
            // forced new hardware wallets to account 1.
            accountIndex = 0
        }
    }

    @ViewBuilder
    private var instructionsForKind: some View {
        switch device.kind {
        case .ledger:
            let appName = network == .mainnet ? "Bitcoin" : "Bitcoin Test"
            Text("Unlock the Ledger and open the **\(appName)** app. Maknoon will request the account public key over Bluetooth; approve the prompt on the device.")
                .font(.callout)
        case .trezor:
            Text("Unlock the Trezor and approve the account public key request on the device.")
                .font(.callout)
        case .yubikey:
            Text("YubiKeys do not sign Bitcoin transactions. This row should not appear; please report.").font(.callout)
                .foregroundStyle(.red)
        case .seedsigner:
            Text("SeedSigner wallets are created during pairing. Use Settings → Devices → Add device → SeedSigner if you need to add another account.").font(.callout)
        }
    }

    @MainActor
    private func addWallet() async {
        phase = .connecting
        errorText = nil
        status = nil
        do {
            // Confirm the device is the SAME serial we registered.
            // Anything else means the user paired with a different
            // device by mistake, and we refuse to create a wallet
            // tagged with a serial that does not match the
            // physical device.
            guard device.kind == .ledger || device.kind == .trezor else {
                throw HardwareWalletError.transport("This device kind doesn't support live xpub fetching. Add it from its dedicated pairing screen instead.")
            }
            let kindForFactory: HardwareWalletKind = device.kind == .ledger ? .ledger : .trezor
            let client = HardwareWalletFactory.make(kind: kindForFactory)
            let liveSerial = try await client.identifyDevice()
            guard liveSerial == device.serial else {
                throw HardwareWalletError.transport("Connected device has serial \(liveSerial) which does not match the registered serial \(device.serial). Reconnect the correct device or re-register this one.")
            }

            phase = .fetchingXpub
            // Read the 4-byte BIP32 master fingerprint AND the
            // account xpub from the device. The fingerprint pairs
            // the xpub with its root master key inside the BIP84
            // descriptor, and BDK rejects descriptors whose
            // fingerprint doesn't actually correspond to the xpub's
            // master.
            let fingerprint = try await client.getBitcoinMasterFingerprint(networkCoinType: network.coinType)
            let xpub = try await client.getBitcoinAccountXpub(
                account: accountIndex,
                networkCoinType: network.coinType
            )

            phase = .building

            let trimmed = label.trimmingCharacters(in: .whitespaces)
            let baseLabel = trimmed.isEmpty ? "\(device.label) \(network.displayName)" : trimmed
            let suffixedLabel = "\(baseLabel) #\(accountIndex)"

            let wallet = BitcoinWalletDescriptor(
                label: suffixedLabel,
                kind: .hardware(deviceId: device.id, accountFingerprint: fingerprint, accountXpub: xpub),
                network: network
            )
            store.bitcoinWalletStore.add(wallet, makeActive: false)
            store.devices.addBitcoinWallet(deviceId: device.id, walletId: wallet.id)

            status = "Added \(wallet.label) on \(network.displayName)."
            phase = .done
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            phase = .ready
        }
    }
}
