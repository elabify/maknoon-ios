// Pre-sign "Prepare Device" coordinator for mini-app hardware signing.
//
// A mini-app bridge handler (pool-access grant, web3 personal_sign /
// signTypedData / sendTransaction) can't present SwiftUI itself, so before it
// opens BLE to a Ledger / Trezor it hands the device + purpose here and
// suspends on a continuation. MiniAppHostView observes `active` and shows the
// shared DeviceReadyConfirmationSheet, exactly as the in-app send and
// WalletConnect flows do. This gives the user a chance to wake the device, open
// the right app, and (for a Trezor host-entry hidden wallet) type the
// hidden-wallet passphrase BEFORE the BLE timer starts.
//
// Without this step a hidden Trezor wallet either throws immediately
// ("Enter this hidden wallet's passphrase to sign.", from resolveChoice with a
// nil passphrase) or, for an on-device-passphrase wallet, blocks forever on a
// device response the user was never told to give. The typed passphrase is
// returned to the handler and never stored.

import SwiftUI

@MainActor
@Observable
final class MiniAppHardwareSignCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let device: RegisteredDevice
        let purpose: HardwareOperationPurpose
        /// True only for a Trezor host-entry hidden wallet: the sheet shows the
        /// passphrase field and requires it before Continue.
        let requiresPassphrase: Bool
    }

    private(set) var active: Request?
    /// True once the user tapped Continue and the BLE signature is in flight. The
    /// sheet stays up (showing a "waiting for your device" spinner) through this
    /// phase, so the mini-app's own progress text is not revealed until the
    /// signature is actually done. Cleared by `finish()`.
    private(set) var isSigning = false
    private var continuation: CheckedContinuation<String?, Error>?
    private var typedPassphrase: String?

    /// Present the ready sheet and await the user. Returns the hidden-wallet
    /// passphrase the user typed (nil when the wallet needs none). Throws
    /// `MiniAppBridgeError.userRejected()` on Cancel / swipe-dismiss. On return
    /// the sheet is still up in its signing phase; the caller MUST call `finish()`
    /// (e.g. in a defer) once the sign completes or fails.
    func present(
        device: RegisteredDevice,
        purpose: HardwareOperationPurpose,
        requiresPassphrase: Bool
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.typedPassphrase = nil
            self.isSigning = false
            self.active = Request(
                device: device, purpose: purpose, requiresPassphrase: requiresPassphrase)
        }
    }

    /// The sheet reports the typed passphrase just before Continue.
    func setPassphrase(_ p: String) { typedPassphrase = p }

    /// Continue: resume the caller with the collected passphrase (nil when none
    /// required) and switch the sheet to its signing phase. The sheet stays up
    /// (the caller dismisses it via `finish()` after the sign).
    func confirm() {
        let cont = continuation
        continuation = nil
        let pass = typedPassphrase
        isSigning = true
        cont?.resume(returning: pass)
    }

    /// Dismiss the sheet after the sign completes or fails.
    func finish() {
        active = nil
        isSigning = false
    }

    /// Cancel / dismiss (only reachable before Continue; disabled while signing).
    func cancel() {
        let cont = continuation
        continuation = nil
        active = nil
        isSigning = false
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}
