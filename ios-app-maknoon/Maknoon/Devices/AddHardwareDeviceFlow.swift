// Reusable "pick a hardware device, then pair it" flow.
//
// Single source of truth for the vendor list + the routing to each
// vendor's pairing sheet (SeedSigner uses its air-gapped QR sheet;
// Ledger / Trezor / YubiKey use the live-transport RegisterDeviceSheet).
// Used both by Settings, Devices ("Register device…") and by the
// onboarding "First wallet" step, which presents this wrapped in a
// NavigationStack as a sheet.
//
// `kinds` lets the caller scope the list: onboarding passes the
// wallet-capable vendors (Ledger / Trezor / SeedSigner, no YubiKey),
// while Devices passes every registrable kind.

import SwiftUI

struct AddHardwareDeviceFlow: View {
    @Environment(HolderStore.self) private var store

    /// The vendors to offer. Defaults to every registrable kind.
    var kinds: [DeviceKind] = DeviceKind.registrableCases
    /// When true, after a Ledger/Trezor registers we immediately present
    /// the Bitcoin "discover existing wallets" sweep so the user can pull
    /// in wallets they already hold on that device. SeedSigner already
    /// creates its first wallet at pairing time, so it is never swept.
    var autoDiscoverBitcoin: Bool = false
    /// Called when a device finishes pairing successfully (`true`) or
    /// the user backs out without registering one (`false`).
    let onFinished: (_ registered: Bool) -> Void

    @State private var pendingKind: DeviceKind?
    @State private var registerError: String?
    @State private var discoverDevice: RegisteredDevice?
    /// Trezor only: the ready/passphrase-choice sheet shown BEFORE the sweep so a
    /// hidden (passphrase) Trezor is discovered under its passphrase, matching the
    /// normal Devices/per-network flow. Ledger skips this (passphrase on-device).
    @State private var readyDevice: RegisteredDevice?
    @State private var hwPassphrase: HiddenWalletSelection = .standard
    @State private var hwHostPassphrase: String = ""

    var body: some View {
        List {
            Section {
                ForEach(kinds, id: \.self) { kind in
                    Button { pendingKind = kind } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.systemImage)
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(kindHint(kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Connect a supported transport so Maknoon can read the device's serial. Adding it to a network wallet is a separate step from the device's detail screen.")
                    .font(.caption)
            }

            if let registerError {
                Section {
                    Text(registerError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .sheet(item: $pendingKind) { kind in
            routeSheet(for: kind)
        }
        // Trezor: collect the hidden-wallet passphrase choice before the sweep so
        // a hidden Trezor is discovered under its passphrase (ADR-0033), the same
        // as the normal flow. Continue schedules the discovery sweep with the
        // captured bindings; cancel still completes (a device was registered).
        .sheet(item: $readyDevice) { dev in
            DeviceReadyConfirmationSheet(
                device: dev,
                purpose: .bitcoinDiscover(network: .mainnet),
                showsPassphraseSelector: true,
                onContinue: {
                    readyDevice = nil
                    scheduleDiscovery(dev)
                },
                onCancel: {
                    readyDevice = nil
                    onFinished(true)
                },
                onPassphraseSelection: { sel, pass in
                    hwPassphrase = sel
                    hwHostPassphrase = pass
                }
            )
            .environment(store)
        }
        .sheet(item: $discoverDevice, onDismiss: { onFinished(true) }) { dev in
            NavigationStack {
                // The sweep uses the passphrase choice captured just above (Trezor)
                // or the standard wallet (Ledger, whose passphrase lives on-device).
                DiscoverHardwareWalletsView(
                    device: dev,
                    network: .mainnet,
                    hwPassphrase: $hwPassphrase,
                    hwHostPassphrase: $hwHostPassphrase
                )
                    .environment(store)
                    .navigationTitle("Discover wallets")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Present the Bitcoin discovery sweep for a freshly-registered
    /// device. Deferred a beat so the registration sheet finishes
    /// dismissing first, iOS silently drops a sheet presented while
    /// another is mid-dismiss.
    private func scheduleDiscovery(_ device: RegisteredDevice) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            discoverDevice = device
        }
    }

    /// Present the Trezor ready/passphrase-choice sheet, deferred so the
    /// registration sheet finishes dismissing first (same reason as
    /// `scheduleDiscovery`).
    private func scheduleReady(_ device: RegisteredDevice) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            readyDevice = device
        }
    }

    private func kindHint(_ kind: DeviceKind) -> String {
        switch kind {
        case .ledger:     return "Bluetooth hardware wallets"
        case .trezor:     return "Bluetooth hardware wallets"
        case .seedsigner: return "Air-gapped Bitcoin signer paired by scanning QR codes."
        case .yubikey:    return "Security key for hardware second factor."
        }
    }

    @ViewBuilder
    private func routeSheet(for kind: DeviceKind) -> some View {
        if kind == .seedsigner {
            SeedSignerPairingSheet { device in
                pendingKind = nil
                if device != nil { onFinished(true) }
            }
            .environment(store)
        } else {
            RegisterDeviceSheet(kind: kind) { result in
                pendingKind = nil
                switch result {
                case .success(let device):
                    if autoDiscoverBitcoin && device.kind == .trezor {
                        // Collect the hidden-wallet passphrase choice first.
                        scheduleReady(device)
                    } else if autoDiscoverBitcoin && device.kind == .ledger {
                        hwPassphrase = .standard
                        hwHostPassphrase = ""
                        scheduleDiscovery(device)
                    } else {
                        onFinished(true)
                    }
                case .failure(let err):
                    registerError = err.localizedDescription
                }
            }
            .environment(store)
        }
    }
}
