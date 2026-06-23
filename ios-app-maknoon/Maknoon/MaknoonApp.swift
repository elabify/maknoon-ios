// PILOT-ONLY (Phase 0): iOS holder demo. The full M4b super-app per
// ../README.md uses TCA + MusnadSDK; this Phase C cut is the minimum
// surface needed to prove the Swift binding works end-to-end against
// the live Sepolia issuer + verifier at musnad.elabify.com.
// See ADR-0019 §"The supersession map".

import SwiftUI

@main
struct MaknoonApp: App {
    @State private var store = HolderStore()
    @State private var displayPrefs = DisplayPreferences()
    @State private var autoLock = AutoLockManager()
    @State private var bootError: String?

    var body: some Scene {
        WindowGroup {
            ManagedRootView()
                .environment(store)
                .environment(displayPrefs)
                .environment(autoLock)
                .preferredColorScheme(displayPrefs.resolvedColorScheme)
                .environment(\.locale, displayPrefs.language.locale ?? Locale.current)
                .modifier(LanguageLayoutDirectionModifier(language: displayPrefs.language))
                .task {
                    autoLock.configure(timeoutSec: displayPrefs.autoLock.seconds)
                    await bootIdentity()
                }
                .onChange(of: displayPrefs.autoLock) { _, new in
                    autoLock.configure(timeoutSec: new.seconds)
                }
        }
    }

    /// Try to load the Identity Sandwich from Keychain on launch.
    /// Failures are surfaced via `bootError` so the user sees a clear
    /// banner instead of an empty-screen mystery.
    private func bootIdentity() async {
        #if DEBUG
        // ADR-0032: assert the second-factor wrap crypto is still
        // byte-identical to Android before any enroll / unlock is
        // trusted. Cheap, runs once at launch.
        SecondFactorWrap.runParitySelfTest()
        #endif
        wipeStaleKeychainOnFirstLaunchIfNeeded()
        do {
            _ = try store.loadIdentity()
        } catch {
            bootError = "Could not load identity from Keychain: \(error)"
        }
    }

    /// Token under UserDefaults that survives only as long as the
    /// app's container does. iOS wipes UserDefaults on app deletion
    /// but leaves Keychain items intact, so on first launch after a
    /// fresh install this key is absent. When that happens, wipe the
    /// Keychain so we route through OnboardingView cleanly instead
    /// of silently adopting a previous install's identity. The
    /// token is a UUID rather than a bool so reinstall + restore-
    /// from-backup flows are unambiguous in diagnostic logs.
    private static let firstLaunchTokenKey = "maknoon.appInstallToken.v1"

    private func wipeStaleKeychainOnFirstLaunchIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.firstLaunchTokenKey) == nil else {
            return
        }
        do {
            try IdentitySandwich.wipe()
            LogStore.shared.info("launch", "first launch after install detected; wiped stale Keychain items")
        } catch {
            LogStore.shared.warn("launch", "first-launch Keychain wipe failed: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.firstLaunchTokenKey)
    }
}

/// Forced LTR/RTL only when the user explicitly picked Arabic;
/// everything else inherits SwiftUI's locale-driven default. Kept
/// as a modifier so we don't sprinkle conditional environments
/// throughout the App body.
private struct LanguageLayoutDirectionModifier: ViewModifier {
    let language: AppLanguage

    func body(content: Content) -> some View {
        if let direction = language.layoutDirection {
            content.environment(\.layoutDirection, direction)
        } else {
            content
        }
    }
}

/// Holds the auto-lock + privacy-curtain + scene-phase plumbing
/// around the RootView. Pulled out so MaknoonApp.body stays a clean
/// description of "what's wired", and the lock/curtain logic has
/// somewhere isolated to read.
struct ManagedRootView: View {
    @Environment(HolderStore.self) private var store
    @Environment(DisplayPreferences.self) private var prefs
    @Environment(AutoLockManager.self) private var autoLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RootView()
                // Re-root the whole UI when the app language changes so every
                // view (incl. UIKit-bridged navigation titles + tab items, which
                // don't re-resolve on a pure .environment(\.locale) change) rebuilds
                // against the new locale. This is the "soft restart" that makes a
                // language switch apply everywhere without quitting the app. Placed
                // on RootView (not ManagedRootView) so the App-level .task /
                // auto-lock config do not re-run; only the visible UI rebuilds.
                .id(prefs.language)
                // Touch-event tracking is handled by ActivityTrackingHost
                // at the UIKit layer (window.sendEvent override). See
                // ActivityTrackingHost.swift. Doing it here as a
                // SwiftUI simultaneousGesture(DragGesture(minimumDistance: 0))
                // interfered with NavigationStack's back-button tap
                // handling on iOS 26: after certain state changes
                // (e.g. removing a credential) the back arrow stopped
                // responding and the destination view never popped.
                .background(ActivityTrackingHost(onTouch: { autoLock.recordActivity() }))

            // Privacy curtain sits above the live UI but below the
            // lock screen. Hides wallet balances + credential cards
            // from the iOS task-switcher snapshot when the app goes
            // inactive.
            if autoLock.showCurtain && !autoLock.isLocked {
                PrivacyCurtain()
                    .transition(.opacity)
            }

            // Lock screen sits on top of everything when an idle
            // timeout has fired. Driven by AutoLockManager;
            // dismissed only by successful biometric.
            if autoLock.isLocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: autoLock.isLocked)
        .animation(.easeOut(duration: 0.15), value: autoLock.showCurtain)
        .onChange(of: scenePhase) { _, new in
            switch new {
            case .background, .inactive:
                autoLock.appWillResignActive()
                // Theme uses Automatic mode? Refresh now so when we
                // come back, the cached value reflects the right
                // half of the day.
                prefs.refreshResolvedColorScheme()
            case .active:
                autoLock.appDidBecomeActive()
                prefs.refreshResolvedColorScheme()
            @unknown default:
                break
            }
        }
    }
}

/// Routes between OnboardingView and the main ContentView. A
/// hardware-wrapped sandwich no longer blocks app launch; the
/// wallet, credentials browsing, and other non-identity ops stay
/// available. Identity-dependent operations (presenting a
/// credential, renewing a delegation, revealing the recovery
/// phrase) trigger the hardware-unlock sheet on demand from
/// inside ContentView.
struct RootView: View {
    @Environment(HolderStore.self) private var store

    var body: some View {
        // OnboardingView only when there's nothing on disk at all.
        // A wrapped (locked) sandwich is "provisioned": the user
        // already onboarded, they just need to unlock for identity
        // ops.
        if store.isCompletingOnboarding
            || (store.sandwich == nil && !store.isIdentityLocked) {
            // Keep onboarding on screen through the post-identity steps
            // (passport scan, first wallet) even though the sandwich has
            // already been adopted so those steps can sign / create a wallet.
            OnboardingView()
        } else {
            ContentView()
        }
    }
}
