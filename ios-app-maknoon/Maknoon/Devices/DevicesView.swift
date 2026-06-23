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
    @State private var showAddDevice = false
    @State private var registerError: String?

    var body: some View {
        Form {
            registeredDevicesSection
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddDevice) {
            NavigationStack {
                AddHardwareDeviceFlow(onFinished: { _ in showAddDevice = false })
                    .environment(store)
                    .navigationTitle("Register device")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel") { showAddDevice = false }
                        }
                    }
            }
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
                showAddDevice = true
            } label: {
                Label("Register device…", systemImage: "plus.circle")
            }
            if let registerError {
                Text(registerError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Registered devices")
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
                    if !dev.promotions.solanaWalletIds.isEmpty {
                        Text("Solana").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.teal.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if !dev.promotions.tronWalletIds.isEmpty {
                        Text("Tron").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.red.opacity(0.18))
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
