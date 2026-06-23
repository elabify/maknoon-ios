// An ERC-20 token instance pinned to a specific EVM network. A
// single logical asset like "USDC" appears as multiple tokens here,
// one per network (each with its own contract address). Decimals
// are stored explicitly because they don't follow chain rules:
// USDC is 6 across every chain, DAI is 18, WBTC is 8, and the user
// can add arbitrary tokens whose decimals we read from-chain.

import Foundation

struct EthereumToken: Codable, Hashable, Identifiable, Sendable {
    /// Stable id for the store (network + lowercase contract). Two
    /// catalog entries on different networks with the same symbol
    /// (e.g. USDC on Sepolia vs Base) have distinct ids.
    let id: String
    let network: EthereumNetwork
    /// Lowercased 0x-prefixed contract address. Stored canonical
    /// (lowercase) for equality; the UI re-checksums for display.
    let contractAddress: String
    let symbol: String
    let name: String
    let decimals: Int
    /// True for curated entries shipped with the app. User-added
    /// tokens are false; the UI exposes a delete affordance only on
    /// those.
    let curated: Bool

    init(network: EthereumNetwork, contractAddress: String, symbol: String, name: String, decimals: Int, curated: Bool) {
        self.network = network
        self.contractAddress = contractAddress.lowercased()
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.curated = curated
        self.id = "\(network.rawValue):\(self.contractAddress)"
    }

    /// CoinGecko asset id derived from the token symbol. The same
    /// token on different chains shares one CoinGecko id (USDC on
    /// Base, Arbitrum, mainnet all map to "usd-coin"). Returns nil
    /// for tokens we don't have a price feed for yet. The UI
    /// hides the fiat caption in that case.
    var coinGeckoId: String? {
        switch symbol.uppercased() {
        case "USDC":  return "usd-coin"
        case "USDT":  return "tether"
        case "DAI":   return "dai"
        case "WBTC":  return "bitcoin"   // pegged to BTC, close enough for a caption
        case "WETH":  return "ethereum"  // pegged to ETH
        default:      return nil
        }
    }
}
