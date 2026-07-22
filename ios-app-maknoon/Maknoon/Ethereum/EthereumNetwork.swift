// Curated EVM network catalog. Mainnet + the top L2s by TVL +
// Hyperliquid EVM (included regardless of ranking per product
// requirements). All entries share BIP44 coin type 60 because they
// are EVM-compatible; per-chain config (RPC, explorer, chain id)
// is what makes them distinct.
//
// Adding a new EVM chain is a one-case addition here plus per-case
// defaults below. Non-EVM chains (Tron, Solana) live in their own
// modules later.

import Foundation

enum EthereumNetwork: String, Codable, CaseIterable, Sendable {
    // ── L1 + L2 mainnets ──────────────────────────────────────
    case mainnet           // Ethereum mainnet
    case arbitrum          // Arbitrum One
    case optimism          // OP Mainnet
    case base              // Base
    case polygon           // Polygon PoS
    case bnb               // BNB Smart Chain
    case avalanche         // Avalanche C-Chain
    case scroll            // Scroll
    case linea             // Linea
    case zksync            // zkSync Era
    case mantle            // Mantle
    case polygonZkEvm      // Polygon zkEVM
    // ── Required regardless of TVL rank ───────────────────────
    case hyperliquid       // Hyperliquid EVM (L1, EVM-compatible)
    // ── Testnets ──────────────────────────────────────────────
    case sepolia
    case arbitrumSepolia
    case baseSepolia
    case optimismSepolia
    /// ADI Chain testnet. EVM-compatible L2 built on ZKsync's
    /// Atlas + Airbender stacks; sponsored by the Abu Dhabi-based
    /// ADI Foundation and slated to host the regulated AED "LARA"
    /// stablecoin. Mainnet not public yet.
    case adiTestnet

    /// Display ordering used by every Picker / list in the app.
    /// Ethereum mainnet is always first; everything else is sorted
    /// alphabetically by displayName so the picker scans cleanly.
    /// Sepolia and other testnets are interleaved alphabetically
    /// too (callers that want testnets separate can filter on
    /// `isTestnet`).
    static var displayOrdered: [EthereumNetwork] {
        let mainnet: EthereumNetwork = .mainnet
        let rest = EthereumNetwork.allCases
            .filter { $0 != mainnet }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return [mainnet] + rest
    }

    /// EIP-155 chain id. Used in transaction signing and shown on
    /// the per-network settings page.
    var chainId: UInt64 {
        switch self {
        case .mainnet:           return 1
        case .optimism:          return 10
        case .bnb:               return 56
        case .polygon:           return 137
        case .zksync:            return 324
        case .hyperliquid:       return 999
        case .polygonZkEvm:      return 1101
        case .mantle:            return 5000
        case .base:              return 8453
        case .arbitrum:          return 42161
        case .avalanche:         return 43114
        case .linea:             return 59144
        case .scroll:            return 534352
        case .sepolia:           return 11155111
        case .arbitrumSepolia:   return 421614
        case .baseSepolia:       return 84532
        case .optimismSepolia:   return 11155420
        case .adiTestnet:        return 99999
        }
    }

    var displayName: String {
        switch self {
        case .mainnet:           return "Ethereum"
        case .arbitrum:          return "Arbitrum One"
        case .optimism:          return "OP Mainnet"
        case .base:              return "Base"
        case .polygon:           return "Polygon"
        case .bnb:               return "BNB Smart Chain"
        case .avalanche:         return "Avalanche"
        case .scroll:            return "Scroll"
        case .linea:             return "Linea"
        case .zksync:            return "zkSync Era"
        case .mantle:            return "Mantle"
        case .polygonZkEvm:      return "Polygon zkEVM"
        case .hyperliquid:       return "Hyperliquid EVM"
        case .sepolia:           return "Sepolia"
        case .arbitrumSepolia:   return "Arbitrum Sepolia"
        case .baseSepolia:       return "Base Sepolia"
        case .optimismSepolia:   return "OP Sepolia"
        case .adiTestnet:        return "ADI Testnet"
        }
    }

    /// Native-coin ticker for balance display.
    var ticker: String {
        switch self {
        case .mainnet, .arbitrum, .optimism, .base, .scroll, .linea,
             .zksync, .polygonZkEvm, .sepolia, .arbitrumSepolia,
             .baseSepolia, .optimismSepolia:
            return "ETH"
        case .polygon:           return "MATIC"
        case .bnb:               return "BNB"
        case .avalanche:         return "AVAX"
        case .mantle:            return "MNT"
        case .hyperliquid:       return "HYPE"
        case .adiTestnet:        return "ADI"
        }
    }

    /// Trust Wallet `blockchains/<slug>` folder name for this
    /// chain. Used to build the default token-logo URL pattern
    /// `https://raw.githubusercontent.com/trustwallet/assets/master/
    /// blockchains/{slug}/assets/{address}/logo.png`. Nil for
    /// chains Trust Wallet's repo doesn't have a folder for
    /// (testnets without bridged asset coverage, custom chains).
    /// The token-row's fallback monogram still renders for nil.
    var trustWalletSlug: String? {
        switch self {
        case .mainnet:           return "ethereum"
        case .arbitrum:          return "arbitrum"
        case .optimism:          return "optimism"
        case .base:              return "base"
        case .polygon:           return "polygon"
        case .bnb:               return "smartchain"
        case .avalanche:         return "avalanchec"
        case .scroll:            return "scroll"
        case .linea:             return "linea"
        case .zksync:            return "zksync"
        case .mantle:            return "mantle"
        case .polygonZkEvm:      return "polygonzkevm"
        case .hyperliquid:       return nil
        case .sepolia, .arbitrumSepolia, .baseSepolia, .optimismSepolia,
             .adiTestnet:        return nil
        }
    }

    /// CoinGecko asset id for the network's native coin. Drives
    /// the fiat reference caption shown next to native balances
    /// and amounts. Returns nil for testnets (no fiat conversion)
    /// and for assets we haven't added to AssetPriceCache yet.
    var coinGeckoAssetId: String? {
        if isTestnet { return nil }
        switch self {
        case .mainnet, .arbitrum, .optimism, .base, .scroll, .linea,
             .zksync, .polygonZkEvm:
            return "ethereum"
        case .polygon:     return "polygon-ecosystem-token" // POL (ex-MATIC); the old matic-network id is dead

        case .bnb:         return "binancecoin"
        case .avalanche:   return "avalanche-2"
        case .mantle:      return "mantle"
        case .hyperliquid: return "hyperliquid"
        case .sepolia, .arbitrumSepolia, .baseSepolia, .optimismSepolia,
             .adiTestnet:
            return nil
        }
    }

    /// True for testnets. Used by the UI to badge them and avoid
    /// defaulting fiat conversion on testnet balances.
    var isTestnet: Bool {
        switch self {
        case .sepolia, .arbitrumSepolia, .baseSepolia, .optimismSepolia,
             .adiTestnet:
            return true
        default: return false
        }
    }

    /// L1 / L2 / L1-EVM-compatible classification (for badges).
    var classification: Classification {
        switch self {
        case .mainnet:                                  return .l1
        case .bnb, .avalanche, .hyperliquid:            return .l1Evm
        case .arbitrum, .optimism, .base, .scroll,
             .linea, .zksync, .mantle, .polygonZkEvm:   return .l2
        case .polygon:                                  return .sidechain
        case .sepolia, .arbitrumSepolia,
             .baseSepolia, .optimismSepolia,
             .adiTestnet:                               return .testnet
        }
    }

    enum Classification: String, Sendable {
        case l1         // Ethereum
        case l1Evm      // Other EVM L1s (BNB, Avalanche, Hyperliquid)
        case l2         // Rollups / L2s
        case sidechain  // Polygon PoS
        case testnet
    }

    /// Public JSON-RPC endpoint that works without an API key. Picked
    /// for reliability: Cloudflare and PublicNode are operated by
    /// long-running CDN-tier teams; the chain-team L2 endpoints come
    /// directly from the chains themselves. Users can override per
    /// network in EthereumSettings to point at a paid provider
    /// (Alchemy, Infura, Ankr, QuickNode) if they hit rate caps.
    var defaultRPCURL: String {
        switch self {
        case .mainnet:           return "https://ethereum.publicnode.com"
        case .arbitrum:          return "https://arb1.arbitrum.io/rpc"
        case .optimism:          return "https://mainnet.optimism.io"
        case .base:              return "https://mainnet.base.org"
        case .polygon:           return "https://polygon-bor-rpc.publicnode.com"
        case .bnb:               return "https://bsc-rpc.publicnode.com"
        case .avalanche:         return "https://api.avax.network/ext/bc/C/rpc"
        case .scroll:            return "https://rpc.scroll.io"
        case .linea:             return "https://rpc.linea.build"
        case .zksync:            return "https://mainnet.era.zksync.io"
        case .mantle:            return "https://rpc.mantle.xyz"
        case .polygonZkEvm:      return "https://zkevm-rpc.com"
        case .hyperliquid:       return "https://rpc.hyperliquid.xyz/evm"
        case .sepolia:           return "https://ethereum-sepolia.publicnode.com"
        case .arbitrumSepolia:   return "https://sepolia-rollup.arbitrum.io/rpc"
        case .baseSepolia:       return "https://sepolia.base.org"
        case .optimismSepolia:   return "https://sepolia.optimism.io"
        case .adiTestnet:        return "https://rpc.ab.testnet.adifoundation.ai/"
        }
    }

    /// HTML block-explorer base URL. Used by the Addresses + tx-row
    /// "open in explorer" affordances.
    var defaultExplorerURL: String {
        switch self {
        case .mainnet:           return "https://etherscan.io"
        case .arbitrum:          return "https://arbiscan.io"
        case .optimism:          return "https://optimistic.etherscan.io"
        case .base:              return "https://basescan.org"
        case .polygon:           return "https://polygonscan.com"
        case .bnb:               return "https://bscscan.com"
        case .avalanche:         return "https://snowtrace.io"
        case .scroll:            return "https://scrollscan.com"
        case .linea:             return "https://lineascan.build"
        case .zksync:            return "https://explorer.zksync.io"
        case .mantle:            return "https://mantlescan.xyz"
        case .polygonZkEvm:      return "https://zkevm.polygonscan.com"
        case .hyperliquid:       return "https://hyperevmscan.io"
        case .sepolia:           return "https://sepolia.etherscan.io"
        case .arbitrumSepolia:   return "https://sepolia.arbiscan.io"
        case .baseSepolia:       return "https://sepolia.basescan.org"
        case .optimismSepolia:   return "https://sepolia-optimism.etherscan.io"
        case .adiTestnet:        return "https://explorer.ab.testnet.adifoundation.ai"
        }
    }

    /// Block-explorer API base URL for tx history. Defaults to
    /// Blockscout instances because they accept the Etherscan-style
    /// query shape (`?module=account&action=txlist`) WITHOUT
    /// requiring an API key, much friendlier than Etherscan v2's
    /// "register for a free key" gate. Users who want Etherscan-
    /// branded data can override the per-network URL in Settings
    /// to `https://api.etherscan.io/v2/api` and add their own key.
    ///
    /// Returns nil for chains that don't have a known Blockscout
    /// deployment (Hyperliquid EVM today). For those the holder app
    /// falls back to RPC-only history fetching, which is more
    /// limited.
    var defaultExplorerAPIURL: String? {
        switch self {
        case .mainnet:           return "https://eth.blockscout.com/api"
        case .arbitrum:          return "https://arbitrum.blockscout.com/api"
        case .optimism:          return "https://optimism.blockscout.com/api"
        case .base:              return "https://base.blockscout.com/api"
        case .polygon:           return "https://polygon.blockscout.com/api"
        case .bnb:               return "https://blockscout.bnbchain.org/api"
        case .avalanche:         return "https://snowtrace.io/api"
        case .scroll:            return "https://scroll.blockscout.com/api"
        case .linea:             return "https://explorer.linea.build/api"
        case .zksync:            return "https://zksync.blockscout.com/api"
        case .mantle:            return "https://explorer.mantle.xyz/api"
        case .polygonZkEvm:      return "https://zkevm.blockscout.com/api"
        case .sepolia:           return "https://eth-sepolia.blockscout.com/api"
        case .arbitrumSepolia:   return "https://sepolia-explorer.arbitrum.io/api"
        case .baseSepolia:       return "https://base-sepolia.blockscout.com/api"
        case .optimismSepolia:   return "https://optimism-sepolia.blockscout.com/api"
        // ADI Testnet runs a ZKsync-Era-style explorer. The SPA at
        // explorer.ab.testnet.adifoundation.ai serves only HTML;
        // its Etherscan-compatible API is on a sibling subdomain.
        case .adiTestnet:        return "https://explorer-api.ab.testnet.adifoundation.ai/api"
        case .hyperliquid:       return nil
        }
    }
}
