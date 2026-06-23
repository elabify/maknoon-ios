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

    /// Overridable third-party price-data endpoints (#61/#63), so a user can
    /// point spot-price + FX lookups at a self-hosted proxy or paid gateway
    /// instead of the public defaults. Empty falls back to the default. Mirrors
    /// Android FiatPreferences.coinGeckoBaseURL / fxBaseURL.
    var coinGeckoBaseURL: String {
        didSet { persist() }
    }
    var fxBaseURL: String {
        didSet { persist() }
    }

    static let defaultCoinGecko = "https://api.coingecko.com/api/v3"
    static let defaultFX = "https://open.er-api.com/v6/latest/USD"

    private static let codeKey = "app.fiatCurrencyCode"
    private static let enabledKey = "app.fiatReferenceEnabled"
    private static let coinGeckoKey = "app.priceCoinGeckoBaseURL"
    private static let fxKey = "app.priceFxBaseURL"

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
        self.coinGeckoBaseURL = UserDefaults.standard.string(forKey: Self.coinGeckoKey)
            ?? Self.defaultCoinGecko
        self.fxBaseURL = UserDefaults.standard.string(forKey: Self.fxKey)
            ?? Self.defaultFX
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
        coinGeckoBaseURL = UserDefaults.standard.string(forKey: Self.coinGeckoKey) ?? Self.defaultCoinGecko
        fxBaseURL = UserDefaults.standard.string(forKey: Self.fxKey) ?? Self.defaultFX
    }

    /// The effective endpoint, falling back to the public default when the
    /// override has been cleared to empty.
    var effectiveCoinGeckoBaseURL: String {
        let t = coinGeckoBaseURL.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? Self.defaultCoinGecko : t
    }
    var effectiveFxBaseURL: String {
        let t = fxBaseURL.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? Self.defaultFX : t
    }

    private func persist() {
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        UserDefaults.standard.set(showReferencePrices, forKey: Self.enabledKey)
        UserDefaults.standard.set(coinGeckoBaseURL, forKey: Self.coinGeckoKey)
        UserDefaults.standard.set(fxBaseURL, forKey: Self.fxKey)
    }
}
