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
    /// Shown once, right after enrolling a YubiKey that has no FIDO2 PIN.
    @State private var noPinWarning = false
    @State private var removeAuthForDeviceId: UUID? = nil
    /// When true, the demote sheet was opened by "Remove device" (not the
    /// standalone "Remove from Identity Sandwich"), so on a successful demote we
    /// also forget the device and dismiss (#79).
    @State private var removeDeviceAfterDemote = false
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
        .sheet(isPresented: $showYubiKeyPINPrompt) {
            PINEntrySheet(
                title: "YubiKey PIN",
                message: "If your YubiKey has a FIDO2 PIN, enter it now. Leave blank if the key has no PIN (it will register as a tap-only key).",
                pin: $yubiKeyPin,
                onSubmit: {
                    if let dev = device {
                        Task { await promoteToIdentity(dev) }
                    }
                },
                onCancel: { yubiKeyPin = "" }
            )
        }
        .alert("Registered without a PIN", isPresented: $noPinWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This YubiKey has no FIDO2 PIN, so anyone holding it can unlock your identity with a tap. For a second factor you can rely on, set a PIN on the key (Yubico Authenticator) and re-register it.")
        }
        .sheet(item: removeAuthBinding) { dev in
            RemoveFromSandwichSheet(deviceToRemove: dev) { _ in
                removeAuthForDeviceId = nil
                // If this demote was triggered by "Remove device", finish the
                // job: forget the device and close the detail screen.
                if removeDeviceAfterDemote {
                    removeDeviceAfterDemote = false
                    store.devices.remove(id: dev.id)
                    dismiss()
                }
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
                            Text("Active second factor")
                                .font(.callout.weight(.semibold))
                            Text("Enrolled \(formatRelative(promo.enrolledAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // A YubiKey is identity-only, so its removal is the single
                    // "Remove device" action below (demote + forget). Only the
                    // wallet-capable Ledger/Trezor offer a demote-but-keep here.
                    if dev.kind != .yubikey {
                        Button(role: .destructive) {
                            // Show the step-up auth sheet. Any enrolled
                            // device must tap to authorize the removal,
                            // preventing a drive-by attacker on an
                            // unlocked phone from silently stripping
                            // enrolled devices.
                            removeAuthForDeviceId = dev.id
                        } label: {
                            Label("Remove second factor", systemImage: "minus.circle")
                        }
                        .disabled(promotingIdentity)
                    }
                } else if dev.kind == .yubikey {
                    // YubiKeys enroll automatically at registration (#79); there
                    // is no manual "add" step. A bare YubiKey only appears if a
                    // registration was interrupted -- re-register it.
                    Text("A YubiKey becomes a second factor automatically when you register it. Re-register this key to enroll it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(promotionPrompt(for: dev.kind))
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
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
                            Label(promotingIdentity ? "Promoting…" : "Add device as second factor", systemImage: "shield.lefthalf.filled")
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
                Text("Second factor")
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
            return "SeedSigner is Bitcoin-only and cannot be a second factor. Use a Ledger or YubiKey to protect your wallet."
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
    /// fire. The body itself isn't a real timeout on our side
    /// (signMessage's BLE call has no client-side timeout), but it
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
            return "SeedSigner is Bitcoin-only and never enrolls as a second factor."
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
            return "Add this YubiKey as a second factor. Tap the YubiKey to the top of the iPhone when iOS shows the NFC sheet. Maknoon enrolls a FIDO2 credential and derives a deterministic ECDSA-based wrap key so the YubiKey can re-protect your recovery phrase. NFC tap only takes a second."
        case .ledger:
            return "Add this Ledger as a second factor. Unlock the Ledger and open the ETHEREUM app on the device, then tap Add. Maknoon will reconnect over BLE, confirm the same serial, and sign a one-time wrap challenge whose deterministic signature derives the AES key that seals your BIP39 entropy. Confirm the prompt on the device."
        case .trezor:
            return "Add this Trezor as a second factor. Unlock the device and confirm the wrap signature on-screen."
        case .seedsigner:
            return "SeedSigner is Bitcoin-only and cannot be a second factor."
        }
    }

    // MARK: -- danger zone

    private func dangerSection(_ dev: RegisteredDevice) -> some View {
        Section {
            Button(role: .destructive) {
                if dev.promotions.identity != nil {
                    // Enrolled as an identity factor: removing the device must
                    // first demote it (step-up auth, anti-brick), then forget.
                    removeDeviceAfterDemote = true
                    removeAuthForDeviceId = dev.id
                } else {
                    store.devices.remove(id: dev.id)
                    dismiss()
                }
            } label: {
                Label("Remove device", systemImage: "trash")
            }
        } footer: {
            Text("Removes the device from Maknoon. If it's a second factor, you'll first authorize the removal on the device, then it's dropped as a factor and forgotten. Wallets created from this device stay in the wallet list (watch-only) until you re-register it.")
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
            guard let liveSandwich = store.sandwich else {
                throw SandwichError.masterUnavailable
            }
            // ADR-0032: when the second factor is already on (other
            // devices enrolled), recover the SHARED CEK by tapping an
            // already-enrolled device first, then reuse it for the new
            // device so every device opens the same sealed entropy. The
            // common first-device case has no existing CEK (nil mints a
            // fresh one). This is the simplified, correct two-tap add.
            let existingCek = try await recoverExistingCekIfNeeded(excluding: dev.id)

            // Generate the deviceSalt up-front so the same value drives
            // both the device's deterministic secret and the HKDF wrap
            // key (ADR-0032).
            let deviceSalt = SecondFactorWrap.newDeviceSalt()
            let secret: Data
            var credentialIdHex = dev.serial
            var pinProtected = true
            switch dev.kind {
            case .yubikey:
                // FIDO2 hmac-secret over NFC. The salt IS the deviceSalt.
                let result = try await YubiKeyClient.shared.enrollHMACSecretOverNFC(
                    label: dev.label,
                    salt: deviceSalt,
                    deviceSerial: dev.serial,
                    pin: yubiKeyPin.isEmpty ? nil : yubiKeyPin
                )
                yubiKeyPin = ""
                secret = result.secret
                credentialIdHex = result.credentialIdHex
                pinProtected = result.pinProtected
            case .ledger, .trezor:
                let hardwareKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
                let hardware = HardwareWalletFactory.make(kind: hardwareKind)
                let connectedSerial = try await hardware.identifyDevice()
                guard connectedSerial == dev.serial else {
                    throw IdentityWrapError.deviceSerialMismatch(expected: dev.serial, actual: connectedSerial)
                }
                let challenge = SecondFactorSignature.challenge(deviceSalt: deviceSalt)
                let sig = try await hardware.signMessage(challenge)
                secret = SecondFactorSignature.secret(fromSignature: sig)
            case .seedsigner:
                throw HardwareWalletError.transport("SeedSigner is Bitcoin-only and cannot be a second factor.")
            }

            let seal = try IdentitySandwich.sealForSecondFactorEnroll(
                sandwich: liveSandwich,
                device: dev,
                secret: secret,
                deviceSalt: deviceSalt,
                existingCek: existingCek
            )
            // The plain biometric item is gone after the first
            // enrollment; push the entropy into the live sandwich's
            // session cache so backup / reveal / renewal keep working.
            store.sandwich?.cacheRecoveryMaterial(seal.material)
            store.devices.setIdentityPromotion(
                deviceId: dev.id,
                promotion: RegisteredDevice.IdentityPromotion(
                    credentialIdHex: credentialIdHex,
                    enrolledAt: Date(),
                    wrapProtocolVersion: 2,
                    pinProtected: pinProtected,
                    deviceSaltHex: bytesToHexLocal(deviceSalt),
                    wrappedCekHex: seal.wrappedCekHex
                )
            )
            if dev.kind == .yubikey, !pinProtected {
                noPinWarning = true
            }
        } catch {
            identityError = userFacingYubiKeyMessage(for: error)
        }
    }

    /// Recover the shared CEK from an already-enrolled device so a NEW
    /// device can reuse it (ADR-0032 multi-device OR). Returns nil when
    /// no other device carries a CEK wrap (the first-device case, where
    /// a fresh CEK is minted). Taps one enrolled device.
    @MainActor
    private func recoverExistingCekIfNeeded(excluding newDeviceId: UUID) async throws -> Data? {
        guard try IdentitySandwich.isSecondFactorOn() else { return nil }
        // Fast path: the CEK is cached in-session (the user unlocked or
        // enrolled the first device this session), so we can wrap it for
        // the new device WITHOUT tapping an already-enrolled key. This is
        // the common case and means "add a second factor" taps only the
        // new device, never silently pulls in the Ledger/YubiKey.
        if let cached = store.sandwich?.cachedSecondFactorCek { return cached }
        guard let authorizer = store.devices.devices.first(where: {
            $0.id != newDeviceId && $0.promotions.identity?.hasSecondFactorWrap == true
        }), let promo = authorizer.promotions.identity, let saltHex = promo.deviceSaltHex else {
            // 2FA on but nothing to recover the CEK with (the clean-cut
            // migration state). Cannot add a device here; the user must
            // restore from backup first.
            throw IdentityWrapError.sealFailed("Your existing security key enrollment is from an older version. Restore from your encrypted backup, then add this device.")
        }
        let deviceSalt = bytesFromHexLocal(saltHex)
        let secret: Data
        switch authorizer.kind {
        case .yubikey:
            secret = try await YubiKeyClient.shared.recomputeHMACSecretOverNFC(
                credentialIdHex: promo.credentialIdHex,
                salt: deviceSalt,
                deviceSerial: authorizer.serial,
                pin: yubiKeyPin.isEmpty ? nil : yubiKeyPin
            )
        case .ledger, .trezor:
            let hwKind: HardwareWalletKind = authorizer.kind == .ledger ? .ledger : .trezor
            let hardware = HardwareWalletFactory.make(kind: hwKind)
            let connectedSerial = try await hardware.identifyDevice()
            guard connectedSerial == authorizer.serial else {
                throw IdentityWrapError.deviceSerialMismatch(expected: authorizer.serial, actual: connectedSerial)
            }
            let challenge = SecondFactorSignature.challenge(deviceSalt: deviceSalt)
            let sig = try await hardware.signMessage(challenge)
            secret = SecondFactorSignature.secret(fromSignature: sig)
        case .seedsigner:
            throw HardwareWalletError.transport("SeedSigner cannot recover the second factor.")
        }
        return try IdentitySandwich.recoverCek(device: authorizer, secret: secret)
    }

    private func formatRelative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

