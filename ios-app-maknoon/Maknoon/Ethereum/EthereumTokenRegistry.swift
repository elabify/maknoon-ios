// Remote-backed verified token directory for Ethereum + EVM
// sidechains. Parallels `SolanaTokenCatalog` and `TronTokenCatalog`:
// fetched at runtime from a TokenList URL the user can override in
// Ethereum Settings, cached locally, refreshed weekly. The trust
// model is uniform across chains: only verified contracts auto-
// install; everything else surfaces as "unknown, add manually?".
//
// The default points at Uniswap's multi-chain default token list,
// which includes mainnet plus every major EVM L2 we support
// (Arbitrum, Optimism, Polygon, Base, etc.). The schema is the
// standard TokenList format where each token carries a `chainId`,
// so we keep entries grouped per network for the auto-discover
// lookup.
//
// Legacy `EthereumTokenCatalog.reputable(for:)` stays in tree as an
// offline fallback so a user with no network on first launch still
// gets sensible token detection.

import Foundation
import Observation

@Observable
final class EthereumTokenRegistry {
    private(set) var lastFetched: Date?
    /// Entries grouped by `(EthereumNetwork, lowercased contract)`.
    /// Lowercased lookup matches the existing
    /// `EthereumToken.contractAddress` normalisation.
    private(set) var entries: [EthereumNetwork: [String: Entry]] = [:]
    private(set) var refreshing: Bool = false
    private(set) var lastError: String?

    struct Entry: Codable, Hashable, Sendable {
        let contract: String       // lowercased 0x...
        let symbol: String
        let name: String
        let decimals: UInt8
        let logoURI: String?
    }

    /// Uniswap's default token list. Multi-chain, standard
    /// TokenList format, stable URL, no API key. Users can override
    /// in Ethereum Settings.
    static let defaultCatalogURL = "https://tokens.uniswap.org"

    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private static let cacheKey = "networks.ethereum.tokens.catalog.v1"
    private static let lastFetchKey = "networks.ethereum.tokens.catalogFetch.v1"

    init() {
        load()
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        lastFetched = nil
        entries = [:]
        lastError = nil
        load()
    }

    /// Total entry count across every chain in the cached catalog.
    /// Used by Settings to surface "X verified tokens cached".
    var totalEntries: Int {
        entries.values.reduce(0) { $0 + $1.count }
    }

    /// Catalog lookup. Case-insensitive contract match within the
    /// given network's slice of the catalog.
    func find(network: EthereumNetwork, contract: String) -> Entry? {
        entries[network]?[contract.lowercased()]
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
            LogStore.shared.warn("ethereum.tokens", "catalog URL malformed: \(catalogURL)")
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
                LogStore.shared.warn("ethereum.tokens", "catalog HTTP \(http.statusCode) from \(url.absoluteString)")
                return
            }
            let decoded = try TokenListParser.parse(data: data) { $0.lowercased() }
            var grouped: [EthereumNetwork: [String: Entry]] = [:]
            for token in decoded {
                guard let cid = token.chainId,
                      let net = network(forChainId: cid)
                else { continue }
                grouped[net, default: [:]][token.address] = Entry(
                    contract: token.address,
                    symbol: token.symbol,
                    name: token.name,
                    decimals: token.decimals,
                    logoURI: token.logoURI
                )
            }
            self.entries = grouped
            self.lastFetched = Date()
            self.lastError = nil
            persist(data: data)
            LogStore.shared.info(
                "ethereum.tokens",
                "catalog refreshed: \(totalEntries) tokens across \(grouped.count) chains from \(url.host ?? "?")"
            )
        } catch {
            lastError = "Refresh failed: \(error.localizedDescription)"
            LogStore.shared.warn("ethereum.tokens", "catalog refresh failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        entries = [:]
        lastFetched = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.lastFetchKey)
    }

    // MARK: -- helpers

    /// Map TokenList chainId → EthereumNetwork. Returns nil for
    /// chains Maknoon doesn't support; those entries are dropped
    /// silently during ingest.
    private func network(forChainId chainId: Int) -> EthereumNetwork? {
        for n in EthereumNetwork.allCases where n.chainId == chainId {
            return n
        }
        return nil
    }

    // MARK: -- persistence

    private func persist(data: Data) {
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        if let last = lastFetched {
            UserDefaults.standard.set(last, forKey: Self.lastFetchKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? TokenListParser.parse(data: data, normalize: { $0.lowercased() }) {
            var grouped: [EthereumNetwork: [String: Entry]] = [:]
            for token in decoded {
                guard let cid = token.chainId,
                      let net = network(forChainId: cid)
                else { continue }
                grouped[net, default: [:]][token.address] = Entry(
                    contract: token.address,
                    symbol: token.symbol,
                    name: token.name,
                    decimals: token.decimals,
                    logoURI: token.logoURI
                )
            }
            self.entries = grouped
        }
        self.lastFetched = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date
    }
}
