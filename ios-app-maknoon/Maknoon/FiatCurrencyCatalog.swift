// Curated list of fiat currencies Maknoon can render reference
// prices in. The codes here are the lowercase strings CoinGecko's
// /simple/price endpoint expects (e.g. "usd", "eur", "aed"). The
// human-readable names and currency symbols come from Locale so
// we don't have to maintain a translation table.

import Foundation

enum FiatCurrencyCatalog {

    /// Supported codes. Source list, not the display order. The
    /// Settings picker sorts these alphabetically by ISO code via
    /// `sortedCodes` so the user can scan a long list without
    /// hunting through an arbitrary "popularity" order.
    static let codes: [String] = [
        "usd", "eur", "gbp", "jpy", "chf",
        "aud", "cad", "nzd", "cny", "hkd", "sgd",
        "krw", "inr", "aed", "sar", "qar",
        "bhd", "kwd", "omr", "ils",
        "brl", "mxn", "ars", "clp", "cop", "pen",
        "zar", "ngn", "egp",
        "myr", "idr", "php", "thb", "vnd",
        "try", "rub", "uah",
        "pln", "czk", "huf", "ron",
        "sek", "nok", "dkk", "isk",
    ]

    /// Alphabetised view of `codes` for UI lists.
    static var sortedCodes: [String] {
        codes.sorted()
    }

    /// Compact picker label: `USD ($), US Dollar`. Sticks the
    /// symbol right after the code so the user can disambiguate at
    /// a glance even when several currencies share a symbol (USD,
    /// AUD, CAD all show `$`, KWD vs DZD both show "د.ك"/"د.ج",
    /// etc).
    static func pickerLabel(_ code: String) -> String {
        let upper = code.uppercased()
        let sym = symbol(code)
        let symPart = sym == upper ? "" : " (\(sym))"
        return "\(upper)\(symPart), \(displayName(code))"
    }

    /// Localized currency name (e.g. "US Dollar", "Emirati Dirham").
    /// Falls back to the uppercase code when Locale doesn't recognise
    /// the currency (shouldn't happen for any entry in `codes`).
    static func displayName(_ code: String) -> String {
        let upper = code.uppercased()
        return Locale.current.localizedString(forCurrencyCode: upper) ?? upper
    }

    /// Currency symbol if the system locale has one (`$`, `€`, etc.),
    /// otherwise the ISO code in upper-case. Used for compact balance
    /// captions where the full name is too long.
    static func symbol(_ code: String) -> String {
        let upper = code.uppercased()
        let locale = Locale(identifier: "en_US@currency=\(upper)")
        return locale.currencySymbol ?? upper
    }

    /// Format an amount in the requested fiat using the user's
    /// current locale's number formatting (digit grouping, decimal
    /// separator) but always with the target currency's symbol.
    /// Decimals default to the currency's standard fractional unit
    /// (2 for most, 0 for JPY/KRW, 3 for BHD/KWD/OMR).
    static func format(_ amount: Decimal, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code.uppercased()
        f.locale = Locale.current
        return f.string(from: NSDecimalNumber(decimal: amount))
            ?? "\(amount) \(code.uppercased())"
    }
}
