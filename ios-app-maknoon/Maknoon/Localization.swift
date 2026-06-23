// Runtime-language-aware string lookup.
//
// SwiftUI `Text("literal")` / `LocalizedStringKey` resolve against the
// `.environment(\.locale, ...)` we set in MaknoonApp, so they update live once the
// view rebuilds (see the `.id(prefs.language)` re-root in MaknoonApp). But
// `String(localized:)` and `NSLocalizedString` resolve against the PROCESS bundle,
// which is bootstrapped from `AppleLanguages` at launch and does NOT change until
// the app restarts. Enum / model label getters that return a `String` (rendered via
// `Text(someString)`) therefore go stale after a language switch.
//
// `Loc.t` fixes that: it resolves the key against the user's chosen-language `.lproj`
// bundle (the String Catalog compiles to `<lang>.lproj/Localizable.strings`), so the
// returned String is in the selected language immediately. The `.id` re-root re-runs
// the getters, so the new value propagates without a restart. Falls back to the
// process bundle for "Use phone setting" (empty code) or a missing `.lproj`.

import Foundation

enum Loc {
    /// The selected app-language code ("en" | "ar" | "zh-Hans"), or "" for
    /// "Use phone setting". Mirrors DisplayPreferences' persisted key.
    private static let languageDefaultsKey = "display.language"

    static func t(_ key: String) -> String {
        let lang = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? ""
        if !lang.isEmpty,
           let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return String(localized: String.LocalizationValue(key))
    }
}
