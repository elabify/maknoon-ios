// Cold-launch hardware-unlock screen.
//
// Shown when the second factor (ADR-0032 CEK scheme) is ON and the app
// has just launched. Lists every enrolled device that carries a CEK
// wrap; the user picks whichever one is at hand, and Maknoon recomputes
// that device's secret, unwraps the shared CEK, opens the sealed
// entropy, and rebuilds the wallet. OR-of-N: any single enrolled device
// can unlock; no quorum or threshold.
//
// Clean-cut migration (ADR-0032): if the second factor is ON but no
// enrolled device carries a v2 CEK wrap, the enrollment is from an older
// build that this version cannot unlock. We surface a restore-from-
// backup banner instead of any legacy unlock path.
//
// The view is intentionally not dismissable: closing it would strand
// the app in a half-loaded state. A "Reset wallet" escape hatch is
// exposed in case every enrolled device is genuinely lost; resetting
// wipes the wallet and routes back to OnboardingView so the user can
// restore from their backup / paper seed.

import SwiftUI

struct HardwareUnlockView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The enrolled devices that carry a CEK wrap (any one unlocks).
    /// Empty in the clean-cut migration state.
    let enrollments: [RegisteredDevice]

    @State private var unlockingDeviceId: UUID?
    @State private var lastError: String?
    @State private var showResetConfirm: Bool = false
    @State private var secondsRemaining: Int = 0
    @State private var countdownTask: Task<Void, Never>?
    /// PIN prompt for YubiKey FIDO2 unlock. Captured before the NFC
    /// scan so iOS's NFC sheet has the screen to itself.
    @State private var showYubiKeyPINPrompt = false
    @State private var yubiKeyPin: String = ""
    @State private var pendingYubiKeyRow: UUID? = nil
    /// Populated when a Ledger / Trezor enrolled row is tapped.
    /// Drives the pre-tap "open the Ethereum app" readiness sheet
    /// before Maknoon opens BLE.
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var pendingUnlockRow: UUID? = nil

    private struct EnrolledRow: Identifiable {
        let device: RegisteredDevice
        var id: UUID { device.id }
    }

    private var rows: [EnrolledRow] {
        enrollments.map { EnrolledRow(device: $0) }
    }

    /// Clean-cut migration: second factor on, but nothing this build can
    /// unlock. Driven by `store.secondFactorNeedsMigration`, with the
    /// empty-enrollments case as a defensive fallback.
    private var needsMigration: Bool {
        store.secondFactorNeedsMigration || enrollments.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if needsMigration {
                        migrationBanner
                    } else {
                        deviceList
                        if let lastError {
                            Text(lastError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 16)
                        }
                        explainer
                    }
                    escape
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Identity locked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Reset wallet?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset and restore from backup", role: .destructive) {
                resetWallet()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes your locked keys, every registered device, every credential, and every chain wallet. After reset you can restore from your encrypted backup or your 24-word paper seed and re-register your security keys. Only do this if every enrolled security key is lost.")
        }
        .alert("YubiKey PIN", isPresented: $showYubiKeyPINPrompt) {
            SecureField("PIN", text: $yubiKeyPin)
            Button("Continue") {
                guard let pendingId = pendingYubiKeyRow,
                      let row = rows.first(where: { $0.device.id == pendingId })
                else { return }
                pendingYubiKeyRow = nil
                Task { await unlock(with: row) }
            }
            Button("Cancel", role: .cancel) {
                pendingYubiKeyRow = nil
                yubiKeyPin = ""
            }
        } message: {
            Text("Enter your YubiKey's FIDO2 PIN to unlock.")
        }
        .sheet(item: $pendingReadyOp) { op in
            DeviceReadyConfirmationSheet(
                device: op.device,
                purpose: op.purpose,
                onContinue: {
                    guard let pendingId = pendingUnlockRow,
                          let row = rows.first(where: { $0.device.id == pendingId })
                    else { return }
                    pendingUnlockRow = nil
                    Task { await unlock(with: row) }
                },
                onCancel: { pendingUnlockRow = nil }
            )
        }
    }

    // MARK: -- subviews

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text("Hardware unlock required")
                .font(.title2.weight(.semibold))
            Text(headlineCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var headlineCopy: String {
        if needsMigration {
            return "Your security key enrollment is from an older version and can't be used to unlock on this build."
        }
        if enrollments.count == 1 {
            return "Your keys are protected by a security key. Connect it and confirm to unlock."
        }
        return "Your keys are protected by \(enrollments.count) security keys. Connect any one and confirm to unlock."
    }

    /// Clean-cut migration banner (ADR-0032). No legacy unlock path is
    /// offered; the user restores from their encrypted backup (which has
    /// the entropy, second factor off) then re-adds their security key.
    private var migrationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Update your security key", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Your security key enrollment is from an older version. Restore from your encrypted backup to continue, then re-add your security key.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var deviceList: some View {
        VStack(spacing: 10) {
            ForEach(rows) { row in
                enrolledRow(row)
            }
            if let activeDev = activeUnlockDevice {
                deviceConfirmationHint(for: activeDev.kind)
            }
        }
        .padding(.horizontal, 16)
    }

    private var activeUnlockDevice: RegisteredDevice? {
        guard let id = unlockingDeviceId else { return nil }
        return store.devices.find(id: id)
    }

    @ViewBuilder
    private func deviceConfirmationHint(for kind: DeviceKind) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text("Look at your \(kind.displayName)")
                    .font(.caption.weight(.semibold))
                Text(confirmationBody(for: kind))
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

    @MainActor
    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        secondsRemaining = seconds
        countdownTask = Task { @MainActor in
            for s in stride(from: seconds - 1, through: 0, by: -1) {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
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

    private func confirmationBody(for kind: DeviceKind) -> String {
        switch kind {
        case .ledger:
            return "Ethereum app is asking you to sign a wrap message. Right button to scroll, both buttons together to approve. Times out after ~30s of no input."
        case .trezor:
            return "Approve the wrap signature on your Trezor's touchscreen. Times out after ~30s of no input."
        case .yubikey:
            return "Tap the YubiKey when it flashes. iOS holds the NFC session open for ~60s."
        case .seedsigner:
            return "SeedSigner is Bitcoin-only and can't unlock your wallet."
        }
    }

    /// Picks the per-device countdown ceiling. Ledger BLE APDUs time
    /// out at 30s (LedgerBLE.swift), Trezor's BLE-style supervision
    /// times out on the same order, and iOS holds the NFC session for
    /// the YubiKey path open for ~60s. A single hard-coded 60s misled
    /// the user when the Ledger dropped at 30s while the on-screen
    /// timer still showed 30s remaining.
    private func countdownSeconds(for kind: DeviceKind) -> Int {
        switch kind {
        case .ledger, .trezor: return 30
        case .yubikey:         return 60
        case .seedsigner:      return 0
        }
    }

    private func enrolledRow(_ row: EnrolledRow) -> some View {
        let dev = row.device
        let isUnlocking = unlockingDeviceId == dev.id
        let isDisabled = unlockingDeviceId != nil && !isUnlocking
        return Button {
            if dev.kind == .yubikey {
                yubiKeyPin = ""
                // Prompt for the PIN only when this key was enrolled PIN-protected
                // (recorded at enrollment). A no-PIN key unlocks with the tap alone.
                if dev.promotions.identity?.pinProtected ?? true {
                    pendingYubiKeyRow = dev.id
                    showYubiKeyPINPrompt = true
                } else {
                    Task { await unlock(with: row) }
                }
            } else if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingUnlockRow = dev.id
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .identitySandwichUnlock
                )
            } else {
                Task { await unlock(with: row) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: dev.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.indigo)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.label)
                        .font(.callout.weight(.semibold))
                    Text(subtitle(for: row))
                        .font(.caption).foregroundStyle(.secondary)
                    if let enrolledAt = dev.promotions.identity?.enrolledAt {
                        Text("Enrolled \(formatRelative(enrolledAt))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isUnlocking {
                    ProgressView().controlSize(.small)
                } else if !isDisabled {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isDisabled && !isUnlocking ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func subtitle(for row: EnrolledRow) -> String {
        "\(row.device.kind.displayName) · \(row.device.serialDisplay)"
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How this works", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            Text("Any single enrolled device unlocks your wallet; you don't need all of them. The wrap key never leaves the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var escape: some View {
        VStack(spacing: 6) {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset wallet (every device permanently lost)", systemImage: "trash")
            }
            .font(.caption)
            Text("Only do this if every enrolled security key is gone. You'll need your encrypted backup or 24-word paper seed to restore.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 24)
    }

    // MARK: -- behaviour

    @MainActor
    private func unlock(with row: EnrolledRow) async {
        let dev = row.device
        guard let promo = dev.promotions.identity, promo.hasSecondFactorWrap,
              let saltHex = promo.deviceSaltHex else {
            lastError = "This device's second-factor enrollment is incomplete. Restore from your encrypted backup, then re-add it."
            return
        }
        let deviceSalt = bytesFromHexLocal(saltHex)
        unlockingDeviceId = dev.id
        lastError = nil
        startCountdown(seconds: countdownSeconds(for: dev.kind))
        defer { stopCountdown() }
        do {
            let secret: Data
            switch dev.kind {
            case .yubikey:
                // YubiKey FIDO2 hmac-secret over NFC. The salt fed to
                // the YubiKey IS the deviceSalt now (ADR-0032).
                secret = try await YubiKeyClient.shared.recomputeHMACSecretOverNFC(
                    credentialIdHex: promo.credentialIdHex,
                    salt: deviceSalt,
                    deviceSerial: dev.serial,
                    pin: yubiKeyPin.isEmpty ? nil : yubiKeyPin
                )
                yubiKeyPin = ""
            case .ledger, .trezor, .seedsigner:
                let hardware = HardwareWalletFactory.make(kind: hardwareKind(for: dev.kind))
                let identifiedSerial = try await hardware.identifyDevice()
                guard identifiedSerial == dev.serial else {
                    throw IdentityWrapError.deviceSerialMismatch(
                        expected: dev.serial,
                        actual: identifiedSerial
                    )
                }
                let challenge = SecondFactorSignature.challenge(deviceSalt: deviceSalt)
                let sig = try await hardware.signMessage(challenge)
                secret = SecondFactorSignature.secret(fromSignature: sig)
            }
            let sandwich = try IdentitySandwich.loadWithSecondFactor(device: dev, secret: secret)
            store.adopt(sandwich)
            store.showHardwareUnlock = false
            dismiss()
        } catch {
            lastError = userFacingYubiKeyMessage(for: error)
        }
        unlockingDeviceId = nil
    }

    @MainActor
    private func resetWallet() {
        try? IdentitySandwich.wipe()
        store.clearSandwich()
    }

    private func hardwareKind(for kind: DeviceKind) -> HardwareWalletKind {
        switch kind {
        case .yubikey:    return .mock  // YubiKey unlock is queued; reaches this only via orphan registry.
        case .ledger:     return .ledger
        case .trezor:     return .trezor
        case .seedsigner: return .mock  // SeedSigner never wraps identity, unreachable in practice.
        }
    }

    private func formatRelative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
