// Per-device settings page. Reached from the Devices tab.
//
// Sections:
//   - Device info (kind, serial, label, registered date)
//   - Identity Sandwich promotion (toggle on/off; gated on the
//     device kind supporting the .identity capability)
//   - Per-network usage summary, with quick links to the network
//     settings pages where the actual "Add wallet from this device"
//     action lives
//   - Remove device (also clears every promotion)

import SwiftUI

struct DeviceDetailView: View {
    let deviceId: UUID
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var renameDraft: String = ""
    @State private var renaming = false
    @State private var promotingIdentity = false
    @State private var identityError: String?
    @State private var secondsRemaining: Int = 0
    @State private var countdownTask: Task<Void, Never>?
    /// PIN prompt for YubiKeys whose FIDO2 applet has a clientPin
    /// set. Required before makeCredential / getAssertion. Empty
    /// string means "no PIN" (we skip verifyPin).
    @State private var showYubiKeyPINPrompt = false
    @State private var yubiKeyPin: String = ""
    @State private var removeAuthForDeviceId: UUID? = nil
    /// Populated when the user taps "Add device to Identity Sandwich"
    /// for a Ledger / Trezor. Drives the pre-tap "open the Ethereum
    /// app" readiness sheet before Maknoon opens BLE for the wrap
    /// signature.
    @State private var pendingReadyOp: PendingHardwareOperation?

    private var device: RegisteredDevice? {
        store.devices.find(id: deviceId)
    }

    var body: some View {
        Form {
            if let dev = device {
                infoSection(dev)
                identitySection(dev)
                dangerSection(dev)
            } else {
                Text("Device no longer registered.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(device?.label ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let dev = device { renameDraft = dev.label }
        }
        .alert("YubiKey PIN", isPresented: $showYubiKeyPINPrompt) {
            SecureField("PIN", text: $yubiKeyPin)
            Button("Continue") {
                if let dev = device {
                    Task { await promoteToIdentity(dev) }
                }
            }
            Button("Cancel", role: .cancel) {
                yubiKeyPin = ""
            }
        } message: {
            Text("Enter your YubiKey FIDO2 PIN. Leave blank if no PIN is set on the key.")
        }
        .sheet(item: removeAuthBinding) { dev in
            RemoveFromSandwichSheet(deviceToRemove: dev) { _ in
                removeAuthForDeviceId = nil
            }
            .environment(store)
        }
        .sheet(item: $pendingReadyOp) { op in
            DeviceReadyConfirmationSheet(
                device: op.device,
                purpose: op.purpose,
                onContinue: { Task { await promoteToIdentity(op.device) } },
                onCancel: {}
            )
        }
    }

    /// Binding that lets `.sheet(item:)` present the removal-auth
    /// flow keyed on the device-to-remove. Kept as a computed
    /// property because the type-checker chokes on the inline form
    /// (it has to resolve `RegisteredDevice` + `Binding` + closure
    /// captures + `find(id:)` overload all at once).
    private var removeAuthBinding: Binding<RegisteredDevice?> {
        Binding(
            get: {
                guard let id = removeAuthForDeviceId else { return nil }
                return store.devices.find(id: id)
            },
            set: { newValue in
                if newValue == nil { removeAuthForDeviceId = nil }
            }
        )
    }

    // MARK: -- info

    private func infoSection(_ dev: RegisteredDevice) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: dev.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.kind.displayName).font(.callout.weight(.semibold))
                    Text("Registered \(formatRelative(dev.registeredAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Serial").font(.caption).foregroundStyle(.secondary)
                Text(dev.serial)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if renaming {
                TextField("Label", text: $renameDraft)
                HStack {
                    Button("Save") {
                        store.devices.rename(id: dev.id, to: renameDraft.trimmingCharacters(in: .whitespaces))
                        renaming = false
                    }
                    Button("Cancel", role: .cancel) {
                        renameDraft = dev.label
                        renaming = false
                    }
                }
            } else {
                Button {
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        } header: {
            Text("Device info")
        }
    }

    // MARK: -- identity promotion

    @ViewBuilder
    private func identitySection(_ dev: RegisteredDevice) -> some View {
        if dev.kind.capabilities.contains(.identity) {
            Section {
                if let promo = dev.promotions.identity {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Active second factor for the Identity Sandwich")
                                .font(.callout.weight(.semibold))
                            Text("Enrolled \(formatRelative(promo.enrolledAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        // Show the step-up auth sheet. Any enrolled
                        // device must tap to authorize the removal,
                        // preventing a drive-by attacker on an
                        // unlocked phone from silently stripping
                        // enrolled devices.
                        removeAuthForDeviceId = dev.id
                    } label: {
                        Label("Remove from Identity Sandwich", systemImage: "minus.circle")
                    }
                    .disabled(promotingIdentity)
                } else {
                    Text(promotionPrompt(for: dev.kind))
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        if dev.kind == .yubikey {
                            yubiKeyPin = ""
                            showYubiKeyPINPrompt = true
                        } else if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                            pendingReadyOp = PendingHardwareOperation(
                                device: dev,
                                purpose: .identitySandwichEnroll
                            )
                        } else {
                            Task { await promoteToIdentity(dev) }
                        }
                    } label: {
                        HStack {
                            if promotingIdentity { ProgressView().controlSize(.small) }
                            Label(promotingIdentity ? "Promoting…" : "Add device to Identity Sandwich", systemImage: "shield.lefthalf.filled")
                        }
                    }
                    .disabled(promotingIdentity)
                }
                if promotingIdentity {
                    deviceConfirmationHint(for: dev.kind)
                }
                if let identityError {
                    Text(identityError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Identity Sandwich")
            } footer: {
                Text(promotionFooter(for: dev.kind)).font(.caption)
            }
        }
    }

    private func promotionFooter(for kind: DeviceKind) -> String {
        switch kind {
        case .yubikey:
            // YubiKey is the only kind that needs the NFC reader
            // entitlement (and the External Accessory protocol for
            // USB-C), which both require the paid Apple Developer
            // Program.
            return "YubiKey enrollment uses NFC or USB-C and requires the paid Apple Developer Program for NFC reader and accessory entitlements. On a free Personal Team sideload this step surfaces a clear entitlement-missing error."
        case .ledger, .trezor:
            // BLE-driven FIDO2 enrollment doesn't need any of those
            // entitlements. The codepath is implemented over the
            // device's existing BLE transport; it's currently a
            // skeleton pending hardware iteration.
            return "Enrollment runs over the device's existing Bluetooth transport. No additional iOS entitlements are required."
        case .seedsigner:
            return "SeedSigner is Bitcoin-only and cannot participate in the Identity Sandwich. Use a Ledger or YubiKey to wrap the identity."
        }
    }

    /// In-flight device-confirmation hint. Critical for hardware
    /// flows: without this, the iPhone spinner sits while the
    /// device is asking the user to confirm with physical button
    /// presses. The visible countdown matches the Ledger's internal
    /// sign-prompt timeout so the user knows how much time they
    /// have to scroll + approve before the device drops the BLE
    /// link.
    @ViewBuilder
    private func deviceConfirmationHint(for kind: DeviceKind) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text("Look at your \(kind.displayName)")
                    .font(.caption.weight(.semibold))
                Text(confirmationHintBody(for: kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if secondsRemaining > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text("Approve within \(secondsRemaining)s")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondsRemaining < 15 ? Color.red : Color.orange)
                }
            }
        }
        .padding(10)
        .background(Color.indigo.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Start a one-second-tick countdown bound to `secondsRemaining`.
    /// Cancels any prior countdown so a quick retry doesn't double-
    /// fire. The body itself isn't a real timeout on our side —
    /// signMessage's BLE call has no client-side timeout — but it
    /// matches the Ledger's internal sign-prompt timeout so the
    /// user knows how much real time is left.
    @MainActor
    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        secondsRemaining = seconds
        countdownTask = Task { @MainActor in
            for s in stride(from: seconds - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch { return }
                secondsRemaining = s
            }
        }
    }

    @MainActor
    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        secondsRemaining = 0
    }

    private func confirmationHintBody(for kind: DeviceKind) -> String {
        switch kind {
        case .ledger:
            return "The Ethereum app is asking you to sign a wrap message. Press the right button on the Ledger to scroll through, then press both buttons together on 'Approve'. The wallet times out after ~30s of no input."
        case .trezor:
            return "Confirm the wrap signature on your Trezor's touchscreen. The device times out after ~30s of no input."
        case .yubikey:
            return "Tap the YubiKey when it flashes. iOS holds the NFC session open for ~60s."
        case .seedsigner:
            return "SeedSigner is Bitcoin-only and never enrolls in the Identity Sandwich."
        }
    }

    /// Device-aware countdown ceiling. Ledger and Trezor BLE APDUs
    /// time out at ~30s (LedgerBLE.swift); iOS keeps an NFC session
    /// open for ~60s. A single hard-coded 60s misled users when the
    /// Ledger dropped at 30s while the on-screen timer still showed
    /// 30s remaining.
    private func countdownSeconds(for kind: DeviceKind) -> Int {
        switch kind {
        case .ledger, .trezor: return 30
        case .yubikey:         return 60
        case .seedsigner:      return 0
        }
    }

    /// Per-kind instructions for "open the right on-device app" so
    /// the user knows what to do before tapping Promote. The actual
    /// FIDO2 hmac-secret enrollment is the same code path for every
    /// kind (YubiKitFIDO2 in the future); only the on-device app the
    /// user opens differs.
    private func promotionPrompt(for kind: DeviceKind) -> String {
        switch kind {
        case .yubikey:
            return "Add this YubiKey to the Identity Sandwich. Tap the YubiKey to the top of the iPhone when iOS shows the NFC sheet. Maknoon enrolls a FIDO2 credential and derives a deterministic ECDSA-based wrap key so the YubiKey can re-protect your recovery phrase. NFC tap only takes a second."
        case .ledger:
            return "Add this Ledger to the Identity Sandwich. Unlock the Ledger and open the ETHEREUM app on the device, then tap Add. Maknoon will reconnect over BLE, confirm the same serial, and sign a one-time wrap challenge whose deterministic signature derives the AES key that seals your BIP39 entropy. Confirm the prompt on the device."
        case .trezor:
            return "Add this Trezor to the Identity Sandwich. Unlock the device and confirm the wrap signature on-screen."
        case .seedsigner:
            return "SeedSigner is Bitcoin-only and cannot wrap the Identity Sandwich."
        }
    }

    // MARK: -- danger zone

    private func dangerSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Button(role: .destructive) {
                store.devices.remove(id: dev.id)
                dismiss()
            } label: {
                Label("Remove device", systemImage: "trash")
            }
        } footer: {
            Text("Removes the device from Maknoon. Wallets created from this device on any network stay in the wallet list (you can still see them in watch-only mode), but signing on those wallets fails until you re-register the device.")
                .font(.caption)
        }
    }

    // MARK: -- helpers

    @MainActor
    private func promoteToIdentity(_ dev: RegisteredDevice) async {
        promotingIdentity = true
        identityError = nil
        startCountdown(seconds: countdownSeconds(for: dev.kind))
        defer {
            promotingIdentity = false
            stopCountdown()
        }
        do {
            switch dev.kind {
            case .yubikey:
                // YubiKey FIDO2 hmac-pattern over NFC. Generate the
                // wrap salt up-front so the same value drives both
                // the YubiKey's deterministic ECDSA signature (via
                // a salt-derived clientDataHash) and our HKDF wrap
                // key derivation. iOS shows its native NFC sheet;
                // the user taps the YubiKey to the top of the
                // phone.
                var saltBytes = [UInt8](repeating: 0, count: 32)
                let status = SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes)
                guard status == errSecSuccess else {
                    throw IdentityWrapError.sealFailed("SecRandomCopyBytes failed: \(status)")
                }
                let salt = Data(saltBytes)
                // Use the FIDO2 hmac-secret extension as the wrap-key
                // source. Raw getAssertion signatures (the previous
                // path) are non-deterministic across calls because
                // the authData signature counter increments, which
                // broke every unlock. hmac-secret produces a
                // deterministic per-(credential, salt) output so the
                // wrap key reproduces on every unlock.
                let result = try await YubiKeyClient.shared.enrollHMACSecretOverNFC(
                    label: dev.label,
                    salt: salt,
                    deviceSerial: dev.serial,
                    pin: yubiKeyPin.isEmpty ? nil : yubiKeyPin
                )
                yubiKeyPin = ""
                guard let liveSandwich = store.sandwich else {
                    throw SandwichError.masterUnavailable
                }
                let promotion = try await IdentitySandwich.promoteWithSecret(
                    sandwich: liveSandwich,
                    device: dev,
                    secret: result.secret,
                    salt: salt
                )
                // The biometric Keychain item is gone if this was the
                // first enrolled device. Push the just-read entropy
                // into the live sandwich's session cache so backup /
                // reveal phrase / delegation renewal keep working
                // in this session.
                store.sandwich?.cacheRecoveryMaterial(promotion.material)
                store.devices.setIdentityPromotion(
                    deviceId: dev.id,
                    promotion: RegisteredDevice.IdentityPromotion(
                        credentialIdHex: result.credentialIdHex,
                        enrolledAt: promotion.wrapped.wrappedAt,
                        wrapProtocolVersion: 2
                    )
                )
            case .ledger, .trezor:
                try await promoteViaPersonalSign(dev)
            case .seedsigner:
                throw HardwareWalletError.transport("SeedSigner is Bitcoin-only and cannot wrap the Identity Sandwich.")
            }
        } catch {
            identityError = userFacingYubiKeyMessage(for: error)
        }
    }

    @MainActor
    private func promoteViaPersonalSign(_ dev: RegisteredDevice) async throws {
        let hardwareKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
        let hardware = HardwareWalletFactory.make(kind: hardwareKind)
        // Confirm the connected device is the same one we registered.
        let connectedSerial = try await hardware.identifyDevice()
        guard connectedSerial == dev.serial else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: dev.serial,
                actual: connectedSerial
            )
        }
        // Wrap. The HardwareWallet implementation owns the personal
        // _sign APDU; on simulator the MockHardwareWallet returns a
        // deterministic SHA-based pseudo-sig so the flow runs end
        // to end.
        guard let liveSandwich = store.sandwich else {
            throw SandwichError.masterUnavailable
        }
        let promotion = try await IdentitySandwich.promoteToHardware(
            sandwich: liveSandwich,
            device: dev,
            hardware: hardware
        )
        // Cache the just-read entropy on the live sandwich so
        // in-session reveal / backup / delegation renewal calls
        // survive the biometric-Keychain-item deletion that fires
        // on first hardware enrollment.
        store.sandwich?.cacheRecoveryMaterial(promotion.material)
        store.devices.setIdentityPromotion(
            deviceId: dev.id,
            promotion: RegisteredDevice.IdentityPromotion(
                credentialIdHex: promotion.wrapped.deviceSerial,
                enrolledAt: promotion.wrapped.wrappedAt
            )
        )
    }

    private func formatRelative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

