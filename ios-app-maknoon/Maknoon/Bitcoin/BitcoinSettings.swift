// Per-user Bitcoin backend configuration. Persists to UserDefaults JSON.
// Drives `ElectrumClient`, `BitcoinFeeEstimator`, and `BitcoinPriceCache`.

import Foundation
import Observation

@Observable
final class BitcoinSettings {

    /// Per-network Electrum server config. Default is the public
    /// Blockstream endpoint defined in `BitcoinNetwork.defaultElectrumURL`.
    struct ElectrumConfig: Codable, Hashable {
        var url: String
        // SHA-256 of the pinned PEM cert (hex). Empty = trust system CAs.
        var pinnedCertSHA256: String

        static let empty = ElectrumConfig(url: "", pinnedCertSHA256: "")
    }

    private(set) var electrumByNetwork: [BitcoinNetwork: ElectrumConfig] = [:]
    var mempoolURLByNetwork: [BitcoinNetwork: String] = [:]
    /// HTML block-explorer base URL per network. Used by the Addresses
    /// tab "Open in explorer" link. Defaults to mempool.space (same
    /// host as the API), but can be overridden so users can point at a
    /// self-hosted mempool / Esplora HTML frontend or a different
    /// explorer entirely (e.g. blockstream.info).
    var explorerURLByNetwork: [BitcoinNetwork: String] = [:]
    var coinGeckoBaseURL: String = "https://api.coingecko.com/api/v3"
    var fiatCode: String = "usd"

    // Persistence root under "networks.bitcoin.*" so when Lightning,
    // Ethereum, and Solana ship they get sibling namespaces.
    // Previous "btc.settings.v1" data is intentionally orphaned.
    private static let storeKey = "networks.bitcoin.settings.v1"

    init() {
        load()
    }

    /// Resolve the Electrum URL for a given network: user override if set,
    /// otherwise the public default.
    func electrumURL(for network: BitcoinNetwork) -> String {
        let cfg = electrumByNetwork[network] ?? .empty
        return cfg.url.isEmpty ? network.defaultElectrumURL : cfg.url
    }

    func mempoolURL(for network: BitcoinNetwork) -> String {
        return mempoolURLByNetwork[network] ?? network.defaultMempoolURL
    }

    /// HTML explorer base URL. Falls back to the configured mempool
    /// URL (mempool.space serves both the JSON API and the HTML
    /// frontend at the same host), then to the public default.
    func explorerURL(for network: BitcoinNetwork) -> String {
        if let override = explorerURLByNetwork[network], !override.isEmpty {
            return override
        }
        return mempoolURL(for: network)
    }

    /// Build a tappable URL for an address page on the configured
    /// explorer. mempool.space + most Esplora-compatible frontends
    /// expose `<base>/address/<bech32>`.
    func explorerAddressURL(_ address: String, on network: BitcoinNetwork) -> URL? {
        let base = explorerURL(for: network).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/address/\(address)")
    }

    /// Build a tappable URL for a transaction page on the configured
    /// explorer.
    func explorerTxURL(_ txid: String, on network: BitcoinNetwork) -> URL? {
        let base = explorerURL(for: network).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/tx/\(txid)")
    }

    func setElectrum(_ cfg: ElectrumConfig, for network: BitcoinNetwork) {
        electrumByNetwork[network] = cfg
        persist()
    }

    func setMempool(_ url: String, for network: BitcoinNetwork) {
        mempoolURLByNetwork[network] = url
        persist()
    }

    func setExplorerURL(_ url: String, for network: BitcoinNetwork) {
        explorerURLByNetwork[network] = url
        persist()
    }

    func resetToDefaults() {
        electrumByNetwork = [:]
        mempoolURLByNetwork = [:]
        explorerURLByNetwork = [:]
        coinGeckoBaseURL = "https://api.coingecko.com/api/v3"
        fiatCode = "usd"
        persist()
    }

    // MARK: -- persistence

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        electrumByNetwork = [:]
        mempoolURLByNetwork = [:]
        explorerURLByNetwork = [:]
        coinGeckoBaseURL = "https://api.coingecko.com/api/v3"
        fiatCode = "usd"
        load()
    }

    private struct Snapshot: Codable {
        var electrumByNetwork: [String: ElectrumConfig]
        var mempoolURLByNetwork: [String: String]
        var explorerURLByNetwork: [String: String]?
        var coinGeckoBaseURL: String
        var fiatCode: String
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        electrumByNetwork = Dictionary(
            uniqueKeysWithValues: snap.electrumByNetwork.compactMap {
                guard let net = BitcoinNetwork(rawValue: $0.key) else { return nil }
                return (net, $0.value)
            }
        )
        mempoolURLByNetwork = Dictionary(
            uniqueKeysWithValues: snap.mempoolURLByNetwork.compactMap {
                guard let net = BitcoinNetwork(rawValue: $0.key) else { return nil }
                return (net, $0.value)
            }
        )
        explorerURLByNetwork = Dictionary(
            uniqueKeysWithValues: (snap.explorerURLByNetwork ?? [:]).compactMap {
                guard let net = BitcoinNetwork(rawValue: $0.key) else { return nil }
                return (net, $0.value)
            }
        )
        coinGeckoBaseURL = snap.coinGeckoBaseURL
        fiatCode = snap.fiatCode
    }

    func persist() {
        let snap = Snapshot(
            electrumByNetwork: Dictionary(
                uniqueKeysWithValues: electrumByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            mempoolURLByNetwork: Dictionary(
                uniqueKeysWithValues: mempoolURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            explorerURLByNetwork: Dictionary(
                uniqueKeysWithValues: explorerURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            coinGeckoBaseURL: coinGeckoBaseURL,
            fiatCode: fiatCode
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
