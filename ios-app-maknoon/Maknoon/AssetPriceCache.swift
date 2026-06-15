 // Per-asset price cache backed by CoinGecko's /simple/price
// endpoint. Aggressively cached (5-min TTL) so we stay under the
// free-tier rate limit, and persists the last successful response
// to UserDefaults so offline launches show stale fiat numbers
// instead of "—".
//
// Crypto is ALWAYS priced in USD (the deep, universally-quoted
// market) and then crossed into the user's display currency via a
// separate USD -> fiat foreign-exchange rate. CoinGecko's direct
// crypto -> local-currency quotes are thin or entirely missing for
// many of the currencies we offer (Gulf riyals, several LatAm and
// frontier currencies), so we never depend on them; the cross via
// USD keeps every currency consistent and well-defined:
//
//     crypto -> USD  (CoinGecko /simple/price?vs_currencies=usd)
//     USD    -> fiat (open.er-api.com daily FX rates)
//
// Every fiat-currency-aware screen in Maknoon reads from this
// single cache. Honors the global `FiatPreferences.showReferencePrices`
// gate: when the user has disabled fiat references, every call
// here returns nil and the cache never fetches.

import Foundation
import Observation

@Observable
final class AssetPriceCache: @unchecked Sendable {

    /// Asset -> fiat -> spot price. Keys are CoinGecko asset ids
    /// (e.g. "bitcoin", "ethereum") and lowercase fiat codes. Only
    /// the "usd" sub-key is populated now that non-USD pricing goes
    /// through the FX cross; the nested shape is kept so older
    /// persisted snapshots decode unchanged.
    private(set) var rates: [String: [String: Double]] = [:]
    private(set) var lastFetchAt: [String: Date] = [:]

    /// USD -> fiat foreign-exchange rates, keyed by lowercase ISO
    /// code (e.g. "aed" -> 3.6725). Populated in one shot from the
    /// FX provider, which returns every currency per request.
    private(set) var fxRates: [String: Double] = [:]
    private(set) var fxFetchedAt: Date?

    /// CoinGecko base URL. Configurable so future paid-tier or
    /// proxy users can point at their own gateway. Default is the
    /// free public endpoint.
    var baseURL: String = "https://api.coingecko.com/api/v3"

    /// Foreign-exchange base URL. open.er-api.com is key-free,
    /// returns USD -> every-ISO-currency in a single document, and
    /// covers the Gulf and frontier currencies CoinGecko omits.
    var fxBaseURL: String = "https://open.er-api.com/v6/latest/USD"

    /// Reference to the global preferences so the cache can short-
    /// circuit every public call when the user disabled fiat
    /// references. Wired by HolderStore at init time.
    private weak var preferences: FiatPreferences?

    private static let ttl: TimeInterval = 5 * 60
    /// FX rates move slowly and the provider refreshes daily, so a
    /// longer TTL keeps us from hammering it.
    private static let fxTTL: TimeInterval = 6 * 60 * 60
    private static let cacheKey = "asset.price.cache.v1"

    /// CoinGecko asset ids we know about. Add to this list when
    /// new assets need spot prices. ERC-20 tokens use their
    /// CoinGecko id, NOT their on-chain contract address.
    static let coinGeckoIds: [String] = [
        "bitcoin", "ethereum",
        // EVM-L1 alts that appear as native coins on the L1s we
        // support under EthereumNetwork.
        "matic-network", "binancecoin", "avalanche-2",
        "mantle", "hyperliquid",
        // Other native chains.
        "solana",
        // Top stablecoins; ERC-20s shown across EVM chains use
        // the same coingecko id regardless of chain.
        "tether", "usd-coin", "dai",
    ]

    init() {
        loadFromDisk()
    }

    func wire(preferences: FiatPreferences) {
        self.preferences = preferences
    }

    /// Latest known price for the asset in the user's selected
    /// fiat. Crypto is priced in USD then crossed to the requested
    /// fiat via the FX rate. Returns nil when fiat references are
    /// disabled, the asset is unknown, we've never successfully
    /// fetched the USD spot, or (for non-USD) we have no FX rate
    /// yet. Kicks off background refreshes when the cache is stale.
    func price(asset: String, fiat: String) -> Double? {
        guard preferences?.showReferencePrices ?? true else { return nil }
        guard let usd = usdPrice(asset: asset) else { return nil }
        let fiatLower = fiat.lowercased()
        if fiatLower == "usd" { return usd }
        guard let fx = fxRate(for: fiatLower) else { return nil }
        return usd * fx
    }

    /// Format a native amount as a fiat caption, e.g.
    /// `"≈ $385.42"`. Returns nil when fiat references are
    /// disabled or we have no price yet.
    func fiatCaption(amount: Decimal, asset: String, fiat: String) -> String? {
        guard let rate = price(asset: asset, fiat: fiat) else { return nil }
        let value = amount * Decimal(rate)
        return "≈ \(FiatCurrencyCatalog.format(value, code: fiat))"
    }

    /// USD -> fiat foreign-exchange rate for the given ISO code.
    /// Returns 1.0 for USD, the cached rate otherwise. Kicks off a
    /// background FX refresh when the cache is stale.
    func fxRate(for fiat: String) -> Double? {
        guard preferences?.showReferencePrices ?? true else { return nil }
        let fiatLower = fiat.lowercased()
        if fiatLower == "usd" { return 1.0 }
        if let at = fxFetchedAt, Date().timeIntervalSince(at) < Self.fxTTL {
            return fxRates[fiatLower]
        }
        Task { @MainActor [weak self] in await self?.refreshFX() }
        return fxRates[fiatLower]
    }

    /// Force a refresh of every known asset's USD spot plus the FX
    /// table. Useful on app launch + on currency change. The `fiat`
    /// argument is retained for call-site compatibility; the FX
    /// provider returns all currencies at once, so it isn't needed
    /// to scope the fetch. No-op when fiat references are disabled.
    func refreshAll(fiat: String) {
        guard preferences?.showReferencePrices ?? true else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for asset in Self.coinGeckoIds {
                await self.refresh(asset: asset)
            }
            await self.refreshFX()
        }
    }

    // MARK: -- internals

    /// Cached USD spot for an asset, kicking off a refresh when
    /// stale. Split out of `price` so both the USD and FX-cross
    /// paths share one fetch.
    private func usdPrice(asset: String) -> Double? {
        let key = "\(asset)|usd"
        if let last = lastFetchAt[key], Date().timeIntervalSince(last) < Self.ttl {
            return rates[asset]?["usd"]
        }
        Task { @MainActor [weak self] in await self?.refresh(asset: asset) }
        return rates[asset]?["usd"]
    }

    private func refresh(asset: String) async {
        let urlString = "\(baseURL)/simple/price?ids=\(asset)&vs_currencies=usd"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let inner = json?[asset] as? [String: Any],
               let value = inner["usd"] as? Double {
                var byFiat = rates[asset] ?? [:]
                byFiat["usd"] = value
                rates[asset] = byFiat
                lastFetchAt["\(asset)|usd"] = Date()
                persistToDisk()
            }
        } catch {
            // Soft-fail; existing cached value (if any) stays in
            // place, the UI shows stale rather than blanking.
        }
    }

    private func refreshFX() async {
        guard let url = URL(string: fxBaseURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // open.er-api.com shape:
            //   { "result": "success", "base_code": "USD",
            //     "rates": { "USD": 1, "AED": 3.6725, ... } }
            guard let ratesObj = json?["rates"] as? [String: Any] else { return }
            var parsed: [String: Double] = [:]
            for (code, value) in ratesObj {
                if let d = (value as? Double) ?? (value as? NSNumber)?.doubleValue {
                    parsed[code.lowercased()] = d
                }
            }
            guard !parsed.isEmpty else { return }
            fxRates = parsed
            fxFetchedAt = Date()
            persistToDisk()
        } catch {
            // Soft-fail; keep the last known FX table.
        }
    }

    // MARK: -- persistence

    private struct Snapshot: Codable {
        let rates: [String: [String: Double]]
        let lastFetchAt: [String: Date]
        // Optional so snapshots written before the FX cross still
        // decode; FX simply re-fetches on first use.
        let fxRates: [String: Double]?
        let fxFetchedAt: Date?
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        rates = snap.rates
        lastFetchAt = snap.lastFetchAt
        fxRates = snap.fxRates ?? [:]
        fxFetchedAt = snap.fxFetchedAt
    }

    private func persistToDisk() {
        let snap = Snapshot(
            rates: rates,
            lastFetchAt: lastFetchAt,
            fxRates: fxRates,
            fxFetchedAt: fxFetchedAt
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}
