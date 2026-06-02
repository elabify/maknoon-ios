// Remote-backed verified TRC-20 catalog. Mirrors
// `SolanaTokenCatalog`: no first-run seed, fetch on first dashboard
// visit, cache locally, refresh weekly, surface fetch errors so a
// broken URL doesn't silently show "Not yet fetched". Parses the
// standard TokenList JSON schema (CoinGecko, Uniswap, Trust Wallet,
// and most other registries publish this shape).

import Foundation
import Observation

@Observable
final class TronTokenCatalog {
    private(set) var lastFetched: Date?
    private(set) var entriesByContract: [String: Entry] = [:]
    private(set) var refreshing: Bool = false
    private(set) var lastError: String?

    struct Entry: Codable, Hashable, Sendable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: UInt8
        let logoURI: String?
    }

    /// CoinGecko's Tron TokenList. Standard schema, stable URL, no
    /// API key required. Users can override in Tron Settings.
    static let defaultCatalogURL = "https://tokens.coingecko.com/tron/all.json"

    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private static let cacheKey = "networks.tron.tokens.catalog.v1"
    private static let lastFetchKey = "networks.tron.tokens.catalogFetch.v1"

    init() {
        load()
    }

    func find(contract: String) -> Entry? {
        entriesByContract[contract]
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
            LogStore.shared.warn("tron.tokens", "catalog URL malformed: \(catalogURL)")
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
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode) from \(url.host ?? "?")."
                LogStore.shared.warn("tron.tokens", "catalog HTTP \(http.statusCode) from \(url.absoluteString)")
                return
            }
            let decoded = try TokenListParser.parse(data: data) { $0 }
            var map: [String: Entry] = [:]
            map.reserveCapacity(decoded.count)
            for entry in decoded {
                map[entry.address] = Entry(
                    contract: entry.address,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI
                )
            }
            self.entriesByContract = map
            self.lastFetched = Date()
            self.lastError = nil
            persist(data: data)
            LogStore.shared.info("tron.tokens", "catalog refreshed: \(decoded.count) tokens from \(url.host ?? "?")")
        } catch {
            lastError = "Refresh failed: \(error.localizedDescription)"
            LogStore.shared.warn("tron.tokens", "catalog refresh failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        entriesByContract = [:]
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
        entriesByContract = [:]
        lastError = nil
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? TokenListParser.parse(data: data, normalize: { $0 }) {
            var map: [String: Entry] = [:]
            for entry in decoded {
                map[entry.address] = Entry(
                    contract: entry.address,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI
                )
            }
            self.entriesByContract = map
        }
        self.lastFetched = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date
    }
}
