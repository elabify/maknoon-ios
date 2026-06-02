// User preferences for the fiat reference-price feature: which
// currency to display alongside native amounts, and whether to
// show fiat references AT ALL.
//
// The "show fiat references" toggle is the privacy / data-control
// knob. When off, Maknoon never hits the price oracle, no fiat
// numbers appear anywhere in the UI, and the Currency picker is
// inert. Useful for users who don't want the app phoning a third-
// party CoinGecko endpoint, since there's no self-hosted way to
// pull spot prices today.
//
// Both fields persist via UserDefaults so they survive launches.

import Foundation
import Observation

@Observable
final class FiatPreferences: @unchecked Sendable {

    /// User-selected display currency. Lowercase ISO code matching
    /// CoinGecko's expected query parameter (e.g. "usd", "aed").
    /// Initialized to "usd" on first launch.
    var code: String {
        didSet { persist() }
    }

    /// When false, Maknoon never displays fiat references and
    /// never queries the price oracle. The Currency picker still
    /// shows but is inert (or hidden, depending on the UI surface).
    var showReferencePrices: Bool {
        didSet { persist() }
    }

    private static let codeKey = "app.fiatCurrencyCode"
    private static let enabledKey = "app.fiatReferenceEnabled"

    init() {
        self.code = UserDefaults.standard.string(forKey: Self.codeKey)
            ?? "usd"
        // Default ON. Privacy-conscious users flip it off in
        // Settings; that disables every network request and
        // hides all fiat captions.
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            self.showReferencePrices = UserDefaults.standard.bool(forKey: Self.enabledKey)
        } else {
            self.showReferencePrices = true
        }
    }

    /// Re-read from UserDefaults after a backup restore. The didSet
    /// persistence on each property re-writes the same value read
    /// back, which is idempotent.
    func reload() {
        code = UserDefaults.standard.string(forKey: Self.codeKey) ?? "usd"
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            showReferencePrices = UserDefaults.standard.bool(forKey: Self.enabledKey)
        } else {
            showReferencePrices = true
        }
    }

    private func persist() {
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        UserDefaults.standard.set(showReferencePrices, forKey: Self.enabledKey)
    }
}
