// Whole-app auto-lock + screen-curtain.
//
// Behaviour (per product spec):
//   - Tracks `lastActivityAt`. A simultaneous gesture on the root
//     view bumps it on every touch / drag / tap.
//   - When `now - lastActivityAt >= timeoutSec`, sets `isLocked = true`.
//     The app root then overlays a full-screen LockScreen until the
//     user re-authenticates with LAContext (Face ID / Touch ID /
//     passcode). On success, lastActivityAt resets to now and the
//     lock screen drops.
//   - On `UIApplication.willResignActiveNotification` (entering
//     background OR the app switcher), raises a privacy curtain so
//     the iOS task-switcher preview shows the Maknoon logo on a
//     plain background instead of the live wallet UI.
//   - On `didBecomeActiveNotification`, if the idle timeout has
//     elapsed during background, locks immediately. Otherwise the
//     curtain drops and the user resumes where they left off.
//
// Separate from the Identity Sandwich biometric (which gates master-key
// unwrap). This is "presence verification": a light-weight check
// that the device is still in the authorised user's hands.

import Foundation
import Observation
import LocalAuthentication

@MainActor
@Observable
final class AutoLockManager {
    /// True while the lock screen is covering the app.
    var isLocked: Bool = false

    /// True while the privacy curtain is over the UI (app is
    /// inactive / backgrounded). Independent of `isLocked`: the
    /// curtain hides UI from the task switcher even when the user
    /// hasn't been gone long enough to require a re-auth.
    var showCurtain: Bool = false

    /// Most recent user interaction. Tap, drag, scroll. NOT updated
    /// when the user is in the lock screen itself, that would
    /// defeat the timer.
    private var lastActivityAt: Date = Date()

    /// Idle threshold; `nil` disables auto-lock entirely (the user
    /// picked "Never"). Updated from DisplayPreferences via
    /// `configure(timeoutSec:)` on every preference change.
    private var timeoutSec: TimeInterval?

    /// Polling timer; ticks every 5s so we don't spin a wakelock
    /// while the screen is on.
    private var timer: Timer?

    /// Locks immediately on the next active transition if true. Set
    /// when scene phase goes to background. The rule is "if you've
    /// been gone past the threshold, we lock on return."
    private var enteredBackgroundAt: Date?

    init() {}

    /// Apply the user's preference. Restarts the polling timer to
    /// reflect the new value. Safe to call repeatedly.
    func configure(timeoutSec: TimeInterval?) {
        self.timeoutSec = timeoutSec
        // Reset baseline whenever the configuration changes so the
        // user doesn't immediately get locked out by stale timestamps.
        self.lastActivityAt = Date()
        timer?.invalidate()
        timer = nil
        guard timeoutSec != nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 1
        timer = t
    }

    /// Bump the activity timestamp. Called from a global gesture on
    /// the root view (see ContentView).
    func recordActivity() {
        guard !isLocked else { return }
        lastActivityAt = Date()
    }

    /// App is going inactive: app switcher, lock screen, incoming
    /// call. Raise the curtain.
    func appWillResignActive() {
        enteredBackgroundAt = Date()
        showCurtain = true
    }

    /// App is back to foreground. Decide whether to lock based on
    /// how long we were gone.
    func appDidBecomeActive() {
        defer { enteredBackgroundAt = nil }
        if let timeout = timeoutSec {
            // Two checks: in-foreground idle, AND backgrounded idle.
            // Either trips the lock.
            let now = Date()
            let foregroundElapsed = now.timeIntervalSince(lastActivityAt)
            let backgroundElapsed = enteredBackgroundAt.map { now.timeIntervalSince($0) } ?? 0
            if foregroundElapsed >= timeout || backgroundElapsed >= timeout {
                isLocked = true
                // Curtain stays up; LockScreen renders on top.
                return
            }
        }
        // No lock needed. Drop the curtain.
        if !isLocked { showCurtain = false }
    }

    /// Called from LockScreen on successful re-authentication.
    func unlock() {
        isLocked = false
        showCurtain = false
        lastActivityAt = Date()
    }

    /// Surface the user's choice via system biometric prompt.
    /// Returns true on success, false on any failure (including
    /// user cancellation). The caller chooses what to do next; for
    /// our usage that's "retry button" rather than auto-quit.
    func attemptUnlock() async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard ctx.canEvaluatePolicy(policy, error: &error) else { return false }
        do {
            let reason = Loc.t("Unlock Maknoon")
            let ok = try await ctx.evaluatePolicy(policy, localizedReason: reason)
            if ok { unlock() }
            return ok
        } catch {
            return false
        }
    }

    private func tick() {
        guard let timeout = timeoutSec, !isLocked else { return }
        if Date().timeIntervalSince(lastActivityAt) >= timeout {
            isLocked = true
            showCurtain = true
        }
    }
}
