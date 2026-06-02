// Two views of the same per-network token data:
//
//   • `firstRunSeed(for:)` — tight set installed automatically on a
//     fresh app launch. Just USDC for every chain that ships it.
//     Avoids spamming the user's token list with stuff they don't
//     hold.
//
//   • `reputable(for:)` — broader set used by the auto-discover
//     code path: when a user's wallet has on-chain ERC-20 activity
//     against a contract that matches an entry here, the token is
//     auto-installed. Keep entries here verified against the chain's
//     official Etherscan-family explorer; this list IS Maknoon's
//     trust anchor for "this contract really is USDC".
//
// All addresses are lowercased (the `EthereumToken` init normalises
// them anyway). Auto-discover lookup hashes by (network, contract)
// so order in these arrays doesn't matter.

import Foundation

enum EthereumTokenCatalog {

    /// First-run seed. Intentionally small.
    static func firstRunSeed(for network: EthereumNetwork) -> [EthereumToken] {
        // Hand-pick: just USDC on every chain that has an official
        // Circle deployment. Sepolia uses the Circle test USDC.
        return reputable(for: network).filter { $0.symbol == "USDC" }
    }

    /// Reputable token list used by auto-discover. ~5-15 entries
    /// per major chain. Adding a new entry: paste the contract from
    /// the chain's Etherscan and double-check the symbol matches.
    static func reputable(for network: EthereumNetwork) -> [EthereumToken] {
        switch network {
        case .mainnet:
            return [
                .init(network: .mainnet, contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
                .init(network: .mainnet, contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7", symbol: "USDT", name: "Tether USD", decimals: 6, curated: true),
                .init(network: .mainnet, contractAddress: "0x6b175474e89094c44da98b954eedeac495271d0f", symbol: "DAI",  name: "Dai Stablecoin", decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", symbol: "WETH", name: "Wrapped Ether", decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", symbol: "WBTC", name: "Wrapped Bitcoin", decimals: 8, curated: true),
                .init(network: .mainnet, contractAddress: "0x514910771af9ca656af840dff83e8264ecf986ca", symbol: "LINK", name: "Chainlink", decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", symbol: "UNI",  name: "Uniswap", decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9", symbol: "AAVE", name: "Aave",     decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x9f8f72aa9304c8b593d555f12ef6589cc3a579a2", symbol: "MKR",  name: "Maker",    decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x4d224452801aced8b2f0aebe155379bb5d594381", symbol: "APE",  name: "ApeCoin",  decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce", symbol: "SHIB", name: "Shiba Inu",decimals: 18, curated: true),
                .init(network: .mainnet, contractAddress: "0x6982508145454ce325ddbe47a25d4ec3d2311933", symbol: "PEPE", name: "Pepe",     decimals: 18, curated: true),
            ]
        case .arbitrum:
            return [
                .init(network: .arbitrum, contractAddress: "0xaf88d065e77c8cc2239327c5edb3a432268e5831", symbol: "USDC", name: "USD Coin",       decimals: 6,  curated: true),
                .init(network: .arbitrum, contractAddress: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", symbol: "USDT", name: "Tether USD",     decimals: 6,  curated: true),
                .init(network: .arbitrum, contractAddress: "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", symbol: "DAI",  name: "Dai Stablecoin", decimals: 18, curated: true),
                .init(network: .arbitrum, contractAddress: "0x82af49447d8a07e3bd95bd0d56f35241523fbab1", symbol: "WETH", name: "Wrapped Ether",  decimals: 18, curated: true),
                .init(network: .arbitrum, contractAddress: "0x912ce59144191c1204e64559fe8253a0e49e6548", symbol: "ARB",  name: "Arbitrum",       decimals: 18, curated: true),
                .init(network: .arbitrum, contractAddress: "0xf97f4df75117a78c1a5a0dbb814af92458539fb4", symbol: "LINK", name: "Chainlink",      decimals: 18, curated: true),
            ]
        case .optimism:
            return [
                .init(network: .optimism, contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85", symbol: "USDC", name: "USD Coin",       decimals: 6,  curated: true),
                .init(network: .optimism, contractAddress: "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58", symbol: "USDT", name: "Tether USD",     decimals: 6,  curated: true),
                .init(network: .optimism, contractAddress: "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", symbol: "DAI",  name: "Dai Stablecoin", decimals: 18, curated: true),
                .init(network: .optimism, contractAddress: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped Ether",  decimals: 18, curated: true),
                .init(network: .optimism, contractAddress: "0x4200000000000000000000000000000000000042", symbol: "OP",   name: "Optimism",       decimals: 18, curated: true),
            ]
        case .base:
            return [
                .init(network: .base, contractAddress: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", symbol: "USDC", name: "USD Coin",      decimals: 6,  curated: true),
                .init(network: .base, contractAddress: "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", symbol: "USDT", name: "Tether USD",    decimals: 6,  curated: true),
                .init(network: .base, contractAddress: "0x4200000000000000000000000000000000000006", symbol: "WETH", name: "Wrapped Ether", decimals: 18, curated: true),
                .init(network: .base, contractAddress: "0x50c5725949a6f0c72e6c4a641f24049a917db0cb", symbol: "DAI",  name: "Dai Stablecoin", decimals: 18, curated: true),
            ]
        case .polygon:
            return [
                .init(network: .polygon, contractAddress: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", symbol: "USDC", name: "USD Coin (native)", decimals: 6,  curated: true),
                .init(network: .polygon, contractAddress: "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", symbol: "USDT", name: "Tether USD",        decimals: 6,  curated: true),
                .init(network: .polygon, contractAddress: "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063", symbol: "DAI",  name: "Dai Stablecoin",    decimals: 18, curated: true),
                .init(network: .polygon, contractAddress: "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619", symbol: "WETH", name: "Wrapped Ether",     decimals: 18, curated: true),
                .init(network: .polygon, contractAddress: "0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6", symbol: "WBTC", name: "Wrapped Bitcoin",   decimals: 8,  curated: true),
            ]
        case .bnb:
            return [
                .init(network: .bnb, contractAddress: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", symbol: "USDC", name: "USD Coin (Binance-Peg)",  decimals: 18, curated: true),
                .init(network: .bnb, contractAddress: "0x55d398326f99059ff775485246999027b3197955", symbol: "USDT", name: "Tether USD (Binance-Peg)",decimals: 18, curated: true),
                .init(network: .bnb, contractAddress: "0xe9e7cea3dedca5984780bafc599bd69add087d56", symbol: "BUSD", name: "Binance USD",             decimals: 18, curated: true),
            ]
        case .avalanche:
            return [
                .init(network: .avalanche, contractAddress: "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", symbol: "USDC", name: "USD Coin",       decimals: 6,  curated: true),
                .init(network: .avalanche, contractAddress: "0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7", symbol: "USDT", name: "Tether USD",     decimals: 6,  curated: true),
            ]
        case .scroll:
            return [
                .init(network: .scroll, contractAddress: "0x06efdbff2a14a7c8e15944d1f4a48f9f95f663a4", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
            ]
        case .linea:
            return [
                .init(network: .linea, contractAddress: "0x176211869ca2b568f2a7d4ee941e073a821ee1ff", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
            ]
        case .zksync:
            return [
                .init(network: .zksync, contractAddress: "0x1d17cbcf0d6d143135ae902365d2e5e2a16538d4", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
            ]
        case .mantle:
            return [
                .init(network: .mantle, contractAddress: "0x09bc4e0d864854c6afb6eb9a9cdf58ac190d0df9", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
            ]
        case .polygonZkEvm:
            return [
                .init(network: .polygonZkEvm, contractAddress: "0xa8ce8aee21bc2a48a5ef670afcc9274c7bbbc035", symbol: "USDC", name: "USD Coin", decimals: 6, curated: true),
            ]
        case .hyperliquid:
            return []
        case .sepolia:
            return [
                // Circle's official Sepolia testnet USDC. Faucet:
                // https://faucet.circle.com/
                .init(network: .sepolia, contractAddress: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238", symbol: "USDC", name: "USD Coin (Sepolia)", decimals: 6, curated: true),
                // Chainlink LINK testnet token. Faucet:
                // https://faucets.chain.link/sepolia
                .init(network: .sepolia, contractAddress: "0x779877a7b0d9e8603169ddbd7836e478b4624789", symbol: "LINK", name: "Chainlink Token",    decimals: 18, curated: true),
            ]
        case .arbitrumSepolia, .baseSepolia, .optimismSepolia:
            return []
        case .adiTestnet:
            // LARA AED-pegged stablecoin will live here once the
            // ERC-20 contract address is published on the ADI
            // testnet explorer. Until then no curated tokens; users
            // can still add custom ERC-20s through Add Token.
            return []
        }
    }

    /// Auto-discover lookup. Case-insensitive contract match within
    /// the given network's reputable list. Returns nil for unknown
    /// contracts (those are surfaced to the user as "unknown token —
    /// add as custom?" rather than auto-installed).
    static func find(network: EthereumNetwork, contract: String) -> EthereumToken? {
        let needle = contract.lowercased()
        return reputable(for: network).first { $0.contractAddress == needle }
    }

    /// Legacy alias used by `EthereumTokenStore` first-run seed.
    /// Kept as a thin wrapper so older callers that consumed
    /// `defaults(for:)` don't need updating.
    static func defaults(for network: EthereumNetwork) -> [EthereumToken] {
        return firstRunSeed(for: network)
    }
}
