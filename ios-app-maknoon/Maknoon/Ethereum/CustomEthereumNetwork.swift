// User-defined EVM network — chain id, RPC URL, explorer URL,
// optional Etherscan-family API URL + key. Lets users target niche
// L2s, sidechains, or self-hosted devnets that aren't in the
// shipped catalog.
//
// Held separately from the `EthereumNetwork` enum so adding a
// custom network doesn't require changing built-in-network code
// paths. The wallet's `currentNetworkByWallet` map uses
// `EthereumNetworkID` so a wallet can be pointed at either a
// built-in case or a custom-network UUID.

import Foundation
import Observation

struct CustomEthereumNetwork: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var chainId: UInt64
    var ticker: String
    var rpcURL: String
    var explorerURL: String
    var explorerAPIURL: String?
    var explorerAPIKey: String?
    var isTestnet: Bool

    init(
        id: UUID = UUID(),
        name: String,
        chainId: UInt64,
        ticker: String,
        rpcURL: String,
        explorerURL: String,
        explorerAPIURL: String? = nil,
        explorerAPIKey: String? = nil,
        isTestnet: Bool = false
    ) {
        self.id = id
        self.name = name
        self.chainId = chainId
        self.ticker = ticker
        self.rpcURL = rpcURL
        self.explorerURL = explorerURL
        self.explorerAPIURL = explorerAPIURL
        self.explorerAPIKey = explorerAPIKey
        self.isTestnet = isTestnet
    }
}

@Observable
final class CustomNetworkStore: @unchecked Sendable {
    private(set) var networks: [CustomEthereumNetwork] = []

    private static let storeKey = "networks.ethereum.custom.v1"

    init() { load() }

    func add(_ network: CustomEthereumNetwork) {
        networks.append(network)
        persist()
    }

    func update(_ network: CustomEthereumNetwork) {
        guard let idx = networks.firstIndex(where: { $0.id == network.id }) else { return }
        networks[idx] = network
        persist()
    }

    func remove(id: UUID) {
        networks.removeAll { $0.id == id }
        persist()
    }

    func find(id: UUID) -> CustomEthereumNetwork? {
        return networks.first { $0.id == id }
    }

    // MARK: -- persistence

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        networks = []
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([CustomEthereumNetwork].self, from: data) {
            networks = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(networks) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

/// Identifier that points at either a built-in network case or a
/// custom-network UUID. Wallet "currently viewed" state uses this
/// instead of `EthereumNetwork` so both kinds can be selected.
enum EthereumNetworkID: Codable, Hashable, Sendable {
    case builtin(EthereumNetwork)
    case custom(UUID)

    /// Stable string id for picker tagging, persistence keys, and
    /// logging. Format: `"builtin:<rawValue>"` or `"custom:<uuid>"`.
    var stableId: String {
        switch self {
        case .builtin(let n):  return "builtin:\(n.rawValue)"
        case .custom(let id):  return "custom:\(id.uuidString)"
        }
    }
}

/// Pre-resolved network properties. Built once per access via
/// `EthereumWalletStore.resolved(networkID:)`. Lets every consumer
/// (views, signing, RPC, explorer) read the same field names
/// regardless of whether the source is a built-in case or a
/// user-defined custom network.
struct ResolvedNetwork: Hashable {
    let networkID: EthereumNetworkID
    let chainId: UInt64
    let displayName: String
    let ticker: String
    let isTestnet: Bool
    let rpcURL: String
    let explorerURL: String
    let explorerAPIURL: String?
    let explorerAPIKey: String?

    /// True when the underlying ID is a built-in catalog case.
    /// Used by views that want to gate UI on "custom networks
    /// don't get a curated token list" etc.
    var isBuiltin: Bool {
        if case .builtin = networkID { return true }
        return false
    }

    /// CoinGecko asset id for the native coin, mirrored from the
    /// built-in EthereumNetwork case. Returns nil for testnets +
    /// custom networks (we don't know what token the user has set
    /// up, and CoinGecko id isn't a thing on the custom-network
    /// editor screen).
    var coinGeckoAssetId: String? {
        guard !isTestnet else { return nil }
        if case .builtin(let net) = networkID {
            return net.coinGeckoAssetId
        }
        return nil
    }
}
