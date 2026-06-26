// A fresh device-owner-authentication gate (Face ID / Touch ID / passcode) for
// sensitive actions that do NOT read the Keychain master material, i.e. the
// custodial Lightning send path (LNDHub, no sandwich seed). For seed-backed
// signing / sending use `IdentitySandwich.recoveryMaterialFresh`, which ties the
// prompt to the actual key read. See ADR-0045 (Authorization invariant): every
// software-wallet signature or broadcast must pass a fresh gate at invocation.

import Foundation
import LocalAuthentication

enum LocalAuth {
    /// Prompt for device-owner auth; returns true on success, false on
    /// cancel/error. If the device has no biometric/passcode configured (cannot
    /// evaluate), returns true so the user is not locked out, matching the app's
    /// existing convention (MiniApp / passport gates).
    static func authorize(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
