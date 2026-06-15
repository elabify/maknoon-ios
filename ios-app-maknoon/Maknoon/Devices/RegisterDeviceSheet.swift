// "Register device" flow. Connects to a device via its vendor
// transport just long enough to read a stable serial, then stores
// the record in DeviceRegistry. Does NOT promote the device into
// anything; that's a separate, user-driven action.

import SwiftUI

struct RegisterDeviceSheet: View {
    let kind: DeviceKind
    let onDone: (Result<RegisteredDevice, Error>) -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .ready
    @State private var serial: String = ""
    @State private var label: String = ""
    @State private var errorText: String?
    /// BLE peripheral identifier captured during identify(); used to
    /// bind subsequent connects to this specific physical device.
    /// Nil for non-BLE transports (YubiKey USB, SeedSigner camera).
    @State private var peripheralUUID: UUID? = nil
    /// Bridges Trezor CodeEntry pairing to a 6-digit code prompt.
    @StateObject private var pairingCoordinator = TrezorPairingCoordinator()

    enum Phase { case ready, connecting, captured }

    /// Which transport the user picked. For YubiKey this is the
    /// only field that distinguishes the two register flows. For
    /// every other kind there's a single transport so the value is
    /// ignored.
    enum Transport { case nfc, usb }
    @State private var transport: Transport = .nfc

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(kind.displayName).font(.callout.weight(.semibold))
                            Text("Maknoon will connect over \(transportName), read the device's stable serial, and record it. The device does not need to be promoted into Identity or any network yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Device")
                }

                switch phase {
                case .ready:    readySection
                case .connecting: connectingSection
                case .captured: capturedSection
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Register device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        cancelInFlight()
                        dismiss()
                    }
                }
            }
            .onDisappear { cancelInFlight() }
            .sheet(isPresented: $pairingCoordinator.awaitingCode) {
                TrezorCodeEntrySheet(
                    onSubmit: { pairingCoordinator.submit($0) },
                    onCancel: { pairingCoordinator.cancel() }
                )
            }
        }
    }

    /// Tear down any in-flight transport call so the underlying
    /// SDK session doesn't keep the YubiKey LED on (or worse,
    /// hang the next attempt because the smart-card transport is
    /// still open).
    private func cancelInFlight() {
        guard phase == .connecting else { return }
        if kind == .yubikey {
            YubiKeyClient.shared.cancel()
        }
        phase = .ready
    }

    private var transportName: String {
        switch kind {
        case .yubikey:    return transport == .nfc ? "NFC" : "USB-C"
        case .ledger:     return "Bluetooth"
        case .trezor:     return "Bluetooth"
        case .seedsigner: return "camera"
        }
    }

    @ViewBuilder
    private var readySection: some View {
        Section {
            instructions
            if kind == .yubikey {
                Button {
                    transport = .nfc
                    Task { await identify() }
                } label: {
                    Label("Tap with NFC", systemImage: "wave.3.right.circle.fill")
                }
                Button {
                    transport = .usb
                    Task { await identify() }
                } label: {
                    Label("Plug in via USB-C", systemImage: "cable.connector")
                }
            } else {
                Button {
                    Task { await identify() }
                } label: {
                    Label("Connect and read serial", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        } header: {
            Text("Steps")
        }
    }

    @ViewBuilder
    private var instructions: some View {
        switch kind {
        case .yubikey:
            Text("Add a YubiKey 5 series (any NFC-capable variant) or 5C. NFC is the recommended path: iOS shows its native NFC sheet, you tap the key to the top of the phone, Maknoon reads the serial. USB-C is a fallback for devices without NFC.").font(.callout)
            Text("Identity Sandwich enrollment (a later step) requires NFC; FIDO2 isn't reachable over USB-C on iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        case .ledger:
            Text("Unlock the Ledger Nano X so we can locally confirm the device serial.").font(.callout)
        case .trezor:
            Text("Unlock your Trezor so Maknoon can read its serial over Bluetooth.").font(.callout)
        case .seedsigner:
            // Routed to SeedSignerPairingSheet directly from
            // DevicesView; this sheet should never present the
            // SeedSigner branch.
            Text("SeedSigner pairing uses the dedicated import screen.").font(.callout)
        }
    }

    private var connectingSection: some View {
        Section {
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting… approve any on-device confirmation prompts.").font(.callout)
            }
        }
    }

    private var capturedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Serial").font(.caption).foregroundStyle(.secondary)
                Text(serial)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            TextField("Label (e.g. \"Vault Ledger\")", text: $label)
            Button {
                let rec = store.devices.register(
                    kind: kind,
                    serial: serial,
                    label: label.trimmingCharacters(in: .whitespaces).isEmpty ? defaultLabel : label,
                    peripheralUUID: peripheralUUID
                )
                onDone(.success(rec))
                dismiss()
            } label: {
                Label("Register", systemImage: "checkmark.circle.fill")
            }
            .disabled(serial.isEmpty)
        } header: {
            Text("Confirm")
        } footer: {
            Text("If you've registered this device before, Maknoon will recognise its serial and just return the existing record without creating a duplicate.")
                .font(.caption)
        }
    }

    private var defaultLabel: String {
        switch kind {
        case .yubikey:    return "YubiKey"
        case .ledger:     return "Ledger"
        case .trezor:     return "Trezor"
        case .seedsigner: return "SeedSigner"
        }
    }

    @MainActor
    private func identify() async {
        phase = .connecting
        errorText = nil
        do {
            switch kind {
            case .yubikey:
                // NFC primary: iOS shows its native NFC sheet,
                // user taps the YubiKey, we read the serial via
                // the Management application over the NFC ISO-7816
                // smart-card session.
                // USB-C fallback: External Accessory connection
                // (com.yubico.ylp); same Management application
                // read, just over USB.
                let s: String
                switch transport {
                case .nfc:
                    s = try await YubiKeyClient.shared.identifySerialOverNFC()
                case .usb:
                    s = try await YubiKeyClient.shared.identifySerial()
                }
                serial = "yk-\(s)"
            case .ledger:
                let wallet = HardwareWalletFactory.make(kind: .ledger)
                let s = try await wallet.identifyDevice()
                serial = s
                peripheralUUID = wallet.currentBLEPeripheralUUID
            case .trezor:
                // Trezor needs THP CodeEntry pairing to reach an
                // encrypted session and read its real device_id; the
                // pairing coordinator surfaces the 6-digit code prompt.
                // On the simulator the factory returns the mock, which
                // has no real serial, so fall back to identifyDevice().
                let wallet = HardwareWalletFactory.make(kind: .trezor)
                if let trezor = wallet as? TrezorBLE {
                    // Reuse the persistent host key + any stored
                    // credential so re-registering a paired device skips
                    // the on-device code; persist the fresh credential
                    // so later identity/signing ops reconnect silently.
                    let hostKey = try TrezorCredentialStore.hostStaticKey()
                    let stored = (try? TrezorCredentialStore.loadCredential()) ?? nil
                    let result = try await trezor.establishPairedSession(
                        hostStaticPriv: hostKey,
                        codeProvider: pairingCoordinator,
                        storedCredential: stored
                    )
                    serial = result.serial
                    peripheralUUID = result.peripheralUUID
                    try? TrezorCredentialStore.saveCredential(result.credential)
                } else {
                    serial = try await wallet.identifyDevice()
                    peripheralUUID = wallet.currentBLEPeripheralUUID
                }
            case .seedsigner:
                throw HardwareWalletError.transport("SeedSigner uses the dedicated pairing screen.")
            }
            label = defaultLabel
            phase = .captured
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            phase = .ready
        }
    }
}
