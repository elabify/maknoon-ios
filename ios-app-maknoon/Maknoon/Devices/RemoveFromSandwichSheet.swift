// Authorize a step-up tap before removing a device from the Identity
// Sandwich. Without this gate, a drive-by attacker with an unlocked
// phone could silently strip enrolled devices by tapping "Remove"
// repeatedly. The wrap-envelope edit cost nothing on the multi-
// device branch.
//
// Any currently-enrolled device can authorize the removal:
//
//   - Removing your own device (most common): pick the device-being-
//     removed as the authorizer. One tap, done.
//   - Removing a lost / damaged device: pick a different enrolled
//     device. The "any one of N enrolled devices unlocks" property
//     extends to "any one of N enrolled devices can demote another".
//
// The authorization proof is a successful open of the authorizing
// device's OWN wrap blob: the only way to produce that signature is
// to hold the device and pass its PIN (YubiKey) or button press
// (Ledger / Trezor) right now.

import SwiftUI

struct RemoveFromSandwichSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deviceToRemove: RegisteredDevice
    /// Called with the demotion result on success (true if the last
    /// enrolled device was removed); called with nil on cancel.
    let onCompletion: (IdentitySandwich.DemotionResult?) -> Void

    @State private var authorizingDeviceId: UUID?
    @State private var inFlight: Bool = false
    @State private var error: String?
    @State private var showPINPrompt: Bool = false
    @State private var pin: String = ""
    @State private var pendingAuthorizerId: UUID? = nil
    /// Populated when a Ledger / Trezor authorizer row is tapped.
    /// Drives the pre-tap "open the Ethereum app" readiness sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?

    /// Rows in the picker: one per enrolled device that carries a CEK
    /// wrap. Includes the device being removed so the common single-
    /// device case still surfaces a sensible authorizer choice.
    private struct EnrolledRow: Identifiable {
        let device: RegisteredDevice
        var id: UUID { device.id }
    }

    private var enrolledRows: [EnrolledRow] {
        store.devices.devices
            .filter { $0.promotions.identity?.hasSecondFactorWrap == true }
            .map { EnrolledRow(device: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Removing **\(deviceToRemove.label)** as a second factor requires confirmation from one of your enrolled devices. Tap whichever you have on hand. The device you tap will be asked to authorize the removal in real time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Authorize with") {
                    if enrolledRows.isEmpty {
                        Text("No enrolled devices found. The wrap envelope appears empty.")
                            .font(.callout).foregroundStyle(.red)
                    } else {
                        ForEach(enrolledRows) { row in
                            authorizerRow(row)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Authorize removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCompletion(nil)
                        dismiss()
                    }
                    .disabled(inFlight)
                }
            }
            .sheet(isPresented: $showPINPrompt) {
                PINEntrySheet(
                    title: "YubiKey PIN",
                    message: "Enter your YubiKey FIDO2 PIN to authorize.",
                    pin: $pin,
                    onSubmit: {
                        if let id = pendingAuthorizerId,
                           let row = enrolledRows.first(where: { $0.device.id == id }) {
                            pendingAuthorizerId = nil
                            Task { await authorizeAndDemote(via: row) }
                        }
                    },
                    onCancel: {
                        pendingAuthorizerId = nil
                        pin = ""
                    }
                )
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: {
                        guard let id = pendingAuthorizerId,
                              let row = enrolledRows.first(where: { $0.device.id == id })
                        else { return }
                        pendingAuthorizerId = nil
                        Task { await authorizeAndDemote(via: row) }
                    },
                    onCancel: { pendingAuthorizerId = nil }
                )
            }
        }
    }

    private func authorizerRow(_ row: EnrolledRow) -> some View {
        let isActive = authorizingDeviceId == row.device.id
        return Button {
            if row.device.kind == .yubikey {
                pin = ""
                // Only prompt for the PIN if this key was enrolled PIN-protected;
                // a no-PIN key authorizes with the tap alone.
                if row.device.promotions.identity?.pinProtected ?? true {
                    pendingAuthorizerId = row.device.id
                    showPINPrompt = true
                } else {
                    pendingAuthorizerId = nil
                    Task { await authorizeAndDemote(via: row) }
                }
            } else if HardwareOperationPurpose.shouldPresent(for: row.device.kind) {
                pendingAuthorizerId = row.device.id
                pendingReadyOp = PendingHardwareOperation(
                    device: row.device,
                    purpose: .identitySandwichDemote
                )
            } else {
                Task { await authorizeAndDemote(via: row) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.device.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.device.label).font(.callout.weight(.semibold))
                        if row.device.id == deviceToRemove.id {
                            Text("(being removed)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tertiary)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(row.device.kind.displayName) · \(row.device.serialDisplay)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isActive && inFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inFlight && !isActive)
    }

    @MainActor
    private func authorizeAndDemote(via row: EnrolledRow) async {
        authorizingDeviceId = row.device.id
        inFlight = true
        error = nil
        defer {
            inFlight = false
            authorizingDeviceId = nil
        }
        do {
            guard let promo = row.device.promotions.identity, promo.hasSecondFactorWrap,
                  let saltHex = promo.deviceSaltHex else {
                throw IdentityWrapError.openFailed("This device's second-factor enrollment is from an older version and can't authorize a removal. Pick a different enrolled device, or restore from your encrypted backup.")
            }
            let deviceSalt = bytesFromHexLocal(saltHex)
            let secret: Data
            switch row.device.kind {
            case .yubikey:
                secret = try await YubiKeyClient.shared.recomputeHMACSecretOverNFC(
                    credentialIdHex: promo.credentialIdHex,
                    salt: deviceSalt,
                    deviceSerial: row.device.serial,
                    pin: pin.isEmpty ? nil : pin
                )
                pin = ""
            case .ledger, .trezor:
                let hwKind: HardwareWalletKind = row.device.kind == .ledger ? .ledger : .trezor
                let hardware = HardwareWalletFactory.make(kind: hwKind)
                let identifiedSerial = try await hardware.identifyDevice()
                guard identifiedSerial == row.device.serial else {
                    throw IdentityWrapError.deviceSerialMismatch(
                        expected: row.device.serial,
                        actual: identifiedSerial
                    )
                }
                let challenge = SecondFactorSignature.challenge(deviceSalt: deviceSalt)
                let sig = try await hardware.signMessage(challenge)
                secret = SecondFactorSignature.secret(fromSignature: sig)
            case .seedsigner:
                throw HardwareWalletError.transport("SeedSigner cannot be a second factor and so cannot authorize a removal.")
            }
            // Count the devices that will still carry a CEK wrap once the
            // removed device's wrap fields are cleared. Zero means this
            // was the last enrolled device (second factor turns off).
            let remaining = store.devices.devices.filter {
                $0.id != deviceToRemove.id && $0.promotions.identity?.hasSecondFactorWrap == true
            }.count
            let result = try IdentitySandwich.removeSecondFactor(
                authorizingDevice: row.device,
                authorizingSecret: secret,
                remainingWrappedDevicesAfterRemoval: remaining
            )
            // Clear the removed device's identity promotion record (drops
            // its deviceSaltHex / wrappedCekHex along with the rest).
            store.devices.setIdentityPromotion(deviceId: deviceToRemove.id, promotion: nil)
            onCompletion(result)
            dismiss()
        } catch {
            self.error = userFacingYubiKeyMessage(for: error)
        }
    }
}
