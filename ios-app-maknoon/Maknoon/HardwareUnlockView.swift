// Cold-launch hardware-unlock screen.
//
// Shown when the Identity Sandwich is hardware-wrapped (one or more
// devices were enrolled in past sessions) and the app has just
// launched. Lists every enrolled device; the user picks whichever
// one is at hand, and Maknoon drives the BLE handshake + wrap
// challenge against that single device. OR-of-N: any single device
// can unlock; no quorum or threshold.
//
// The view is intentionally not dismissable — closing it would
// strand the app in a half-loaded state. A "Reset wallet" escape
// hatch is exposed in case every enrolled device is genuinely
// lost; resetting wipes the sandwich and routes back to
// OnboardingView so the user can restore from their paper seed.

import SwiftUI

struct HardwareUnlockView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let enrollments: [WrappedMaterialPersisted]

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
        let wrap: WrappedMaterialPersisted
        let device: RegisteredDevice?
        var id: UUID { wrap.deviceId }
    }

    private var rows: [EnrolledRow] {
        enrollments.map { w in
            EnrolledRow(wrap: w, device: store.devices.find(id: w.deviceId))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    deviceList
                    if let lastError {
                        Text(lastError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                    }
                    explainer
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
            Button("Reset and restore from paper seed", role: .destructive) {
                resetWallet()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes the locked Identity Sandwich, every registered device, every credential, and every chain wallet. After reset you can restore from your 24-word paper seed and re-register your hardware devices. Only do this if every enrolled device is lost.")
        }
        .alert("YubiKey PIN", isPresented: $showYubiKeyPINPrompt) {
            SecureField("PIN", text: $yubiKeyPin)
            Button("Continue") {
                guard let pendingId = pendingYubiKeyRow,
                      let row = rows.first(where: { $0.wrap.deviceId == pendingId })
                else { return }
                pendingYubiKeyRow = nil
                Task { await unlock(with: row) }
            }
            Button("Cancel", role: .cancel) {
                pendingYubiKeyRow = nil
                yubiKeyPin = ""
            }
        } message: {
            Text("Enter your YubiKey FIDO2 PIN. Leave blank if no PIN is set on the key.")
        }
        .sheet(item: $pendingReadyOp) { op in
            DeviceReadyConfirmationSheet(
                device: op.device,
                purpose: op.purpose,
                onContinue: {
                    guard let pendingId = pendingUnlockRow,
                          let row = rows.first(where: { $0.wrap.deviceId == pendingId })
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
        if enrollments.count == 1 {
            return "Your Identity Sandwich is wrapped by a registered device. Connect it and confirm to unlock."
        }
        return "Your Identity Sandwich is wrapped by \(enrollments.count) registered devices. Connect any one and confirm to unlock."
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
            return "SeedSigner is Bitcoin-only and never unlocks the Identity Sandwich."
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
        let isUnlocking = unlockingDeviceId == row.wrap.deviceId
        let isDisabled = row.device == nil || (unlockingDeviceId != nil && !isUnlocking)
        return Button {
            guard let dev = row.device else { return }
            if dev.kind == .yubikey {
                yubiKeyPin = ""
                pendingYubiKeyRow = row.wrap.deviceId
                showYubiKeyPINPrompt = true
            } else if HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingUnlockRow = row.wrap.deviceId
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .identitySandwichUnlock
                )
            } else {
                Task { await unlock(with: row) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.device?.kind.systemImage ?? "questionmark.circle")
                    .font(.title2)
                    .foregroundStyle(row.device == nil ? Color.secondary : Color.indigo)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.device?.label ?? "Unregistered device")
                        .font(.callout.weight(.semibold))
                    Text(subtitle(for: row))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Wrapped \(formatRelative(row.wrap.wrappedAt))")
                        .font(.caption2).foregroundStyle(.tertiary)
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
        if let dev = row.device {
            return "\(dev.kind.displayName) · \(dev.serialDisplay)"
        }
        return "Serial \(row.wrap.deviceSerial) · registry record missing"
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How this works", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            Text("Any single enrolled device unlocks the Identity Sandwich; you don't need all of them. The wrap key never leaves the device.")
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
            Text("Only do this if every enrolled device is gone. You'll need your 24-word paper seed to restore.")
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
        guard let dev = row.device else { return }
        unlockingDeviceId = row.wrap.deviceId
        lastError = nil
        startCountdown(seconds: countdownSeconds(for: dev.kind))
        defer { stopCountdown() }
        do {
            let sandwich: IdentitySandwich
            switch dev.kind {
            case .yubikey:
                // YubiKey FIDO2 over NFC. iOS shows its native NFC
                // sheet; user taps the YubiKey to the top of the
                // phone. The wrap key is the FIDO2 hmac-secret
                // extension output, which is deterministic per
                // (credential, salt) pair regardless of the FIDO2
                // signature counter.
                guard let promo = dev.promotions.identity else {
                    throw IdentityWrapError.deviceSerialMismatch(
                        expected: "YubiKey enrolled credential id",
                        actual: "no promotion record"
                    )
                }
                guard let wrapped = enrollments.first(where: { $0.deviceId == dev.id }) else {
                    throw IdentityWrapError.deviceSerialMismatch(
                        expected: enrollments.map { $0.deviceSerial }.joined(separator: " or "),
                        actual: dev.serial
                    )
                }
                // v1 enrollments used raw FIDO2 signatures whose
                // counter drift made unlock impossible. Surface a
                // clear "re-enroll required" message instead of
                // attempting an unlock that will always fail.
                if (promo.wrapProtocolVersion ?? 1) < 2 {
                    throw IdentityWrapError.openFailed("This YubiKey enrollment uses the old wrap protocol that cannot reproduce its wrap key. Reset the wallet, restore from your 24-word phrase, then re-enroll this YubiKey to use the new hmac-secret protocol.")
                }
                let secret = try await YubiKeyClient.shared.recomputeHMACSecretOverNFC(
                    credentialIdHex: promo.credentialIdHex,
                    salt: wrapped.salt,
                    deviceSerial: dev.serial,
                    pin: yubiKeyPin.isEmpty ? nil : yubiKeyPin
                )
                yubiKeyPin = ""
                sandwich = try await IdentitySandwich.loadWrappedWithSecret(
                    enrollments: enrollments,
                    device: dev,
                    secret: secret
                )
            case .ledger, .trezor, .seedsigner:
                let hardware = HardwareWalletFactory.make(kind: hardwareKind(for: dev.kind))
                let identifiedSerial = try await hardware.identifyDevice()
                guard identifiedSerial == dev.serial else {
                    throw IdentityWrapError.deviceSerialMismatch(
                        expected: dev.serial,
                        actual: identifiedSerial
                    )
                }
                sandwich = try await IdentitySandwich.loadWrapped(
                    enrollments: enrollments,
                    device: dev,
                    hardware: hardware
                )
            }
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
