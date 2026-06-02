// Centralised, observable preferences surfaced under Settings → Display:
//   - Theme (Light, Dark, Automatic time-of-day, follow phone)
//   - Auto-Lock idle timeout (30s … 5m, or Never)
//   - In-app language override (follow phone, en, ar, zh-Hans)
//
// All values persist to UserDefaults so they survive app restarts.
// The `usePhoneSetting` default for both theme + language means "do
// nothing special" so we don't override iOS Settings unless the user
// explicitly opted in. AutoLockTimeout defaults to 2 minutes per the
// product spec.

import SwiftUI
import Observation

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case automatic
    case usePhoneSetting

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .light:           return "Light"
        case .dark:            return "Dark"
        case .automatic:       return "Automatic"
        case .usePhoneSetting: return "Use Phone Setting"
        }
    }

    /// Resolve to a SwiftUI ColorScheme. `nil` means "follow system".
    /// For `.automatic` we use a simple 06:00 / 18:00 local-time rule
    /// per product spec (no sunrise/sunset geo lookup, no location
    /// permission). Re-evaluated whenever this method is called.
    func effectiveColorScheme(now: Date = Date()) -> ColorScheme? {
        switch self {
        case .light:           return .light
        case .dark:            return .dark
        case .usePhoneSetting: return nil
        case .automatic:
            let hour = Calendar.current.component(.hour, from: now)
            return (hour >= 6 && hour < 18) ? .light : .dark
        }
    }
}

enum AutoLockTimeout: String, CaseIterable, Identifiable, Sendable {
    case sec30 = "30s"
    case min1  = "1m"
    case min2  = "2m"
    case min3  = "3m"
    case min4  = "4m"
    case min5  = "5m"
    case never

    var id: String { rawValue }

    /// Idle seconds before the app auto-locks. `nil` means Auto-Lock
    /// is disabled and the app never locks itself.
    var seconds: TimeInterval? {
        switch self {
        case .sec30: return 30
        case .min1:  return 60
        case .min2:  return 120
        case .min3:  return 180
        case .min4:  return 240
        case .min5:  return 300
        case .never: return nil
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .sec30: return "30 seconds"
        case .min1:  return "1 minute"
        case .min2:  return "2 minutes"
        case .min3:  return "3 minutes"
        case .min4:  return "4 minutes"
        case .min5:  return "5 minutes"
        case .never: return "Never"
        }
    }
}

/// Language override. `usePhoneSetting` (default) means "respect
/// iOS Settings → General → Language & Region", which is how every
/// other iOS app behaves by default.
///
/// Self-names on non-English options (العربية, 简体中文) so users
/// who don't read English can still recognise their language in the
/// picker.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case usePhoneSetting = ""
    case english = "en"
    case arabic = "ar"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .usePhoneSetting:    return "Use Phone Setting"
        case .english:            return "English"
        case .arabic:             return "العربية"
        case .chineseSimplified:  return "简体中文"
        }
    }

    /// Locale to feed into the SwiftUI environment so `Text("...")`
    /// literals resolve against the right .xcstrings entry. `nil`
    /// means "let SwiftUI pick up the system locale".
    var locale: Locale? {
        switch self {
        case .usePhoneSetting: return nil
        default:               return Locale(identifier: rawValue)
        }
    }

    /// Forced layout direction. Only Arabic flips to RTL; everything
    /// else (including future right-to-left scripts) returns `nil`
    /// and SwiftUI's locale-driven default direction applies.
    var layoutDirection: LayoutDirection? {
        switch self {
        case .arabic: return .rightToLeft
        default:      return nil
        }
    }
}

@MainActor
@Observable
final class DisplayPreferences {
    var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
            refreshResolvedColorScheme()
        }
    }
    var autoLock: AutoLockTimeout {
        didSet { UserDefaults.standard.set(autoLock.rawValue, forKey: Self.autoLockKey) }
    }
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            Self.persistAppleLanguages(for: language)
        }
    }

    /// Mirror our language choice into iOS's `AppleLanguages` preference
    /// list. SwiftUI's `.environment(\.locale, ...)` controls
    /// in-session catalog lookups (`Text("key")` re-resolves on next
    /// render), but the system-level Locale that NSLocalizedString,
    /// NSDateFormatter and friends consult is bootstrapped at app
    /// launch from this defaults key. Writing it here means a hard
    /// app restart picks up the chosen language too, including for
    /// any non-SwiftUI surfaces.
    ///
    /// `usePhoneSetting` removes our override so iOS falls back to
    /// the OS-level Settings → General → Language list.
    private static func persistAppleLanguages(for lang: AppLanguage) {
        let d = UserDefaults.standard
        switch lang {
        case .usePhoneSetting:
            d.removeObject(forKey: "AppleLanguages")
        default:
            d.set([lang.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Cached resolution of `theme.effectiveColorScheme()`. Recomputed
    /// on theme change AND on a periodic 5-minute tick so the
    /// `.automatic` (06:00/18:00) mode picks up the day boundary
    /// without a full app restart.
    var resolvedColorScheme: ColorScheme?

    private static let themeKey    = "display.theme"
    private static let autoLockKey = "display.autoLock"
    private static let languageKey = "display.language"

    private var refreshTimer: Timer?

    init() {
        let d = UserDefaults.standard
        self.theme    = AppTheme(rawValue: d.string(forKey: Self.themeKey)    ?? "") ?? .usePhoneSetting
        self.autoLock = AutoLockTimeout(rawValue: d.string(forKey: Self.autoLockKey) ?? "") ?? .min2
        self.language = AppLanguage(rawValue: d.string(forKey: Self.languageKey) ?? "") ?? .usePhoneSetting
        self.resolvedColorScheme = nil
        refreshResolvedColorScheme()
        startAutomaticRefreshTimer()
    }

    /// Re-read theme / auto-lock / language from UserDefaults after a
    /// backup restore. Reassigning republishes to SwiftUI; the didSet
    /// on each property persists the same value back (idempotent) and
    /// re-applies AppleLanguages for the language case.
    func reload() {
        let d = UserDefaults.standard
        theme    = AppTheme(rawValue: d.string(forKey: Self.themeKey)    ?? "") ?? .usePhoneSetting
        autoLock = AutoLockTimeout(rawValue: d.string(forKey: Self.autoLockKey) ?? "") ?? .min2
        language = AppLanguage(rawValue: d.string(forKey: Self.languageKey) ?? "") ?? .usePhoneSetting
        refreshResolvedColorScheme()
    }

    /// Force a recompute. Useful after returning to foreground in
    /// `.automatic` mode so a long-backgrounded app catches the day
    /// boundary it slept through.
    func refreshResolvedColorScheme() {
        resolvedColorScheme = theme.effectiveColorScheme()
    }

    private func startAutomaticRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshResolvedColorScheme() }
        }
    }
}
