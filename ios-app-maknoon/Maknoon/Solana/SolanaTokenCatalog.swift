// Remote-backed verified-token directory for Solana.
//
// Maknoon does NOT ship a hardcoded SPL token list. Instead it pulls
// a verified-tokens registry at runtime, caches the JSON in
// UserDefaults, and refreshes weekly. The catalog is the trust anchor
// for the auto-discover path in `SolanaSPLTokenStore`: when a wallet
// holds SPL token accounts, each mint is matched against the catalog
// and only verified hits are auto-installed. Unknown mints surface
// to the user as "Unknown token, add manually?" so airdrop spam
// doesn't appear on the dashboard by default.
//
// The catalog URL is user-overridable in Solana Settings so a user
// running a hardened build can swap to a self-hosted mirror or pin
// to a frozen snapshot. The schema parsed is the standard Uniswap
// "TokenList" format that CoinGecko, Trust Wallet, Jupiter, and
// most other registries publish, with one entry per token carrying
// `address`, `name`, `symbol`, `decimals`, and `logoURI`.

import Foundation
import Observation

@Observable
final class SolanaTokenCatalog {
    private(set) var lastFetched: Date?
    private(set) var entriesByMint: [String: Entry] = [:]
    private(set) var refreshing: Bool = false
    /// Last refresh's error message, or nil if the most recent
    /// attempt succeeded (or hasn't happened yet). Surfaces to the
    /// Settings view so a user tapping "Refresh now" actually sees
    /// the failure mode instead of a silent "Not yet fetched".
    private(set) var lastError: String?

    struct Entry: Codable, Hashable, Sendable {
        let address: String      // SPL mint pubkey, base58
        let symbol: String
        let name: String
        let decimals: UInt8
        let logoURI: String?
    }

    /// CoinGecko's Solana TokenList. Standard schema, stable URL,
    /// no API key required. Users can override in Solana Settings.
    static let defaultCatalogURL = "https://tokens.coingecko.com/solana/all.json"

    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private static let cacheKey = "networks.solana.tokens.catalog.v1"
    private static let lastFetchKey = "networks.solana.tokens.catalogFetch.v1"

    init() {
        load()
    }

    func find(mint: String) -> Entry? {
        entriesByMint[mint]
    }

    @MainActor
    func refreshIfStale(catalogURL: String) async {
        if let last = lastFetched, Date().timeIntervalSince(last) < Self.staleAfter {
            return
        }
        await refresh(catalogURL: catalogURL)
    }

    @MainActor
    func refresh(catalogURL: String) async {
        guard let url = URL(string: catalogURL) else {
            lastError = "Catalog URL malformed: \(catalogURL)"
            LogStore.shared.warn("solana.tokens", "catalog URL malformed: \(catalogURL)")
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "No HTTP response from \(url.host ?? "?")."
                LogStore.shared.warn("solana.tokens", "no HTTP response from \(url.absoluteString)")
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode) from \(url.host ?? "?")."
                LogStore.shared.warn("solana.tokens", "catalog HTTP \(http.statusCode) from \(url.absoluteString)")
                return
            }
            let decoded = try TokenListParser.parse(data: data) { addr in addr }
            var map: [String: Entry] = [:]
            map.reserveCapacity(decoded.count)
            for entry in decoded {
                map[entry.address] = Entry(
                    address: entry.address,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI
                )
            }
            self.entriesByMint = map
            self.lastFetched = Date()
            self.lastError = nil
            persist(data: data)
            LogStore.shared.info("solana.tokens", "catalog refreshed: \(decoded.count) tokens from \(url.host ?? "?")")
        } catch {
            lastError = "Refresh failed: \(error.localizedDescription)"
            LogStore.shared.warn("solana.tokens", "catalog refresh failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        entriesByMint = [:]
        lastFetched = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.lastFetchKey)
    }

    // MARK: -- persistence

    private func persist(data: Data) {
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        if let last = lastFetched {
            UserDefaults.standard.set(last, forKey: Self.lastFetchKey)
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        lastFetched = nil
        entriesByMint = [:]
        lastError = nil
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? TokenListParser.parse(data: data, normalize: { $0 }) {
            var map: [String: Entry] = [:]
            for entry in decoded {
                map[entry.address] = Entry(
                    address: entry.address,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI
                )
            }
            self.entriesByMint = map
        }
        self.lastFetched = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date
    }
}
