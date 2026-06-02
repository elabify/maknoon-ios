// Vendor-neutral device management.
//
// Top section: "Identity protection." Always shows Secure Enclave
// Signing (the on-device authorization gating every sensitive
// operation, via the user's preferred biometric or passcode). Below
// it, any registered devices that have been promoted into the
// Identity Sandwich.
//
// Second section: "Registered devices." Every device the user has
// registered via the "Register device..." action. Registration is a
// lightweight handshake: we connect just long enough to read the
// device's stable serial and store the record. Adding the device to
// the Identity Sandwich (or to a network wallet) is a separate
// explicit promotion the user performs from the device-detail
// screen and from the network settings pages.

import SwiftUI

struct DevicesView: View {
    @Environment(HolderStore.self) private var store
    @State private var showRegisterPicker = false
    @State private var pendingKind: DeviceKind?
    @State private var registerError: String?

    var body: some View {
        Form {
            identityProtectionSection
            registeredDevicesSection
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Register a hardware device",
            isPresented: $showRegisterPicker,
            titleVisibility: .visible
        ) {
            ForEach(DeviceKind.registrableCases, id: \.self) { kind in
                Button(kind.displayName) { pendingKind = kind }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connect over the device's transport (BLE for Ledger; NFC or USB-C for YubiKey) so Maknoon can read its serial. The device does not need to be promoted into Identity or any network yet, that happens in a separate step.")
        }
        .sheet(item: $pendingKind) { kind in
            if kind == .seedsigner {
                SeedSignerPairingSheet { _ in
                    pendingKind = nil
                }
                .environment(store)
            } else {
                RegisterDeviceSheet(kind: kind) { result in
                    pendingKind = nil
                    if case .failure(let err) = result {
                        registerError = err.localizedDescription
                    }
                }
                .environment(store)
            }
        }
    }

    // MARK: -- identity protection

    private var identityProtectionSection: some View {
        Section {
            // Secure Enclave signing: every sensitive operation gates
            // through the user's configured biometric or passcode.
            HStack {
                Image(systemName: "cpu.fill").foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Secure Enclave Signing").font(.callout.weight(.semibold))
                    Text("Required for every sensitive operation. Authorized by your preferred configured biometric or passcode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Any device that's been promoted into the Identity
            // Sandwich (wraps the BIP39 entropy via FIDO2 hmac-secret).
            let identityDevices = store.devices.devices
                .filter { $0.promotions.identity != nil }
            if identityDevices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("No security keys protect your Identity Sandwich yet", systemImage: "key.fill")
                        .foregroundStyle(.purple)
                    Text("Register a YubiKey or a Ledger (Security Key app), then add it from the device's detail screen below to require a second factor on every Identity Sandwich unlock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(identityDevices) { dev in
                    HStack {
                        Image(systemName: dev.kind.systemImage).foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(dev.label).font(.callout.weight(.semibold))
                            Text("\(dev.kind.displayName) - \(dev.serialDisplay)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Identity protection")
        } footer: {
            Text("Secure Enclave signing unlocks the post-quantum master key locally via your preferred configured biometric or passcode. Registered security keys add a hardware second factor that wraps the BIP39 entropy via a FIDO2 hmac-secret challenge-response.")
                .font(.caption)
        }
    }

    // MARK: -- registered devices

    private var registeredDevicesSection: some View {
        Section {
            if store.devices.devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "key.radiowaves.forward")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text("No devices registered yet")
                        .font(.callout.weight(.semibold))
                    Text("Tap Register device to identify a YubiKey or Ledger. Adding it to Identity or to a specific network is a separate step from the device's detail screen.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ForEach(store.devices.devices) { dev in
                    NavigationLink {
                        DeviceDetailView(deviceId: dev.id)
                            .environment(store)
                    } label: {
                        deviceRow(dev)
                    }
                }
            }
            Button {
                showRegisterPicker = true
            } label: {
                Label("Register device…", systemImage: "plus.circle")
            }
            if let registerError {
                Text(registerError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Registered devices")
        } footer: {
            Text("Registration is a lightweight handshake that records the device's stable serial so Maknoon can recognise it on every reconnect. Promotion into Identity or a network requires opening the relevant on-device app and explicitly approving.")
                .font(.caption)
        }
    }

    private func deviceRow(_ dev: RegisteredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: dev.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.label).font(.callout.weight(.semibold))
                Text("\(dev.kind.displayName) - \(dev.serialDisplay)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if dev.promotions.identity != nil {
                        Text("Identity").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if !dev.promotions.bitcoinWalletIds.isEmpty {
                        Text("Bitcoin").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if !dev.promotions.ethereumWalletIds.isEmpty {
                        Text("Ethereum").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// Make DeviceKind itself usable as a sheet `item:` parameter so
// `.sheet(item: $pendingKind)` works without an extra wrapper.
extension DeviceKind: Identifiable {
    var id: String { rawValue }
}
