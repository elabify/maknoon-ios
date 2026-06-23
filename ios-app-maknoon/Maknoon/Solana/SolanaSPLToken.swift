// SPL token model. Mirrors `EthereumToken`'s role: persistable
// metadata for one fungible token the user wants to track in their
// dashboard. The mint address is the canonical identity (a base58-
// encoded 32-byte Solana pubkey, the same shape as a wallet address).
//
// Unlike Ethereum where the curated list is in-tree, Solana tokens
// are sourced from Jupiter's verified registry at runtime (see
// `SolanaTokenCatalog`). The `source` field tracks where each
// installed token came from so the UI can render trust signals.

import Foundation

/// Where an installed token's metadata originated.
enum SolanaTokenSource: String, Codable, Sendable, Hashable {
    /// Auto-installed after matching the user's wallet activity
    /// against the cached Jupiter verified list.
    case jupiter
    /// Pulled from the on-chain Metaplex Token Metadata Program when
    /// the mint had no Jupiter entry but the user explicitly added
    /// it. Trustworthy for symbol/name/decimals but not curated.
    case metaplex
    /// User typed in decimals + symbol manually. No trust anchor;
    /// surface clearly in the UI ("Custom").
    case custom
}

/// One SPL token the user has installed for a given Solana cluster.
/// Persisted under SolanaSPLTokenStore. Equality is by (network, mint)
/// because the same SPL mint can theoretically exist on multiple
/// clusters (though most don't; mainnet USDC and devnet USDC are
/// distinct mints, for instance).
struct SolanaSPLToken: Codable, Identifiable, Hashable, Sendable {
    /// Cluster this token lives on. SPL tokens are per-cluster: the
    /// USDC mint on mainnet is a different mint than the USDC mint
    /// on devnet.
    let network: SolanaNetwork
    /// Base58 SPL mint pubkey, the canonical identifier.
    let mint: String
    /// Display symbol (e.g. "USDC"). Pulled from catalog or user
    /// input; not validated against on-chain metadata at runtime.
    var symbol: String
    /// Human-readable name (e.g. "USD Coin").
    var name: String
    /// Token decimals. SPL tokens encode this in the mint account
    /// itself; values typically 0-9. Critical for amount display.
    let decimals: UInt8
    /// Optional logo URL, supplied by the catalog. Lets the row
    /// render an icon next to the symbol.
    var logoURI: String?
    /// Provenance, drives the UI's trust indicator.
    var source: SolanaTokenSource

    var id: String { "\(network.rawValue):\(mint)" }

    init(
        network: SolanaNetwork,
        mint: String,
        symbol: String,
        name: String,
        decimals: UInt8,
        logoURI: String? = nil,
        source: SolanaTokenSource
    ) {
        self.network = network
        self.mint = mint
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.logoURI = logoURI
        self.source = source
    }

    /// CoinGecko asset id derived from the token symbol. Used by
    /// the send view to display fiat captions and to enable the
    /// fiat-input denomination picker. Returns nil for tokens we
    /// don't have a price feed for. The UI hides the fiat option
    /// in that case. Same pattern as `EthereumToken.coinGeckoId`.
    var coinGeckoId: String? {
        switch symbol.uppercased() {
        case "USDC":  return "usd-coin"
        case "USDT":  return "tether"
        case "DAI":   return "dai"
        case "WBTC":  return "bitcoin"
        case "WETH":  return "ethereum"
        case "BONK":  return "bonk"
        case "JUP":   return "jupiter-exchange-solana"
        case "PYTH":  return "pyth-network"
        case "JTO":   return "jito-governance-token"
        default:      return nil
        }
    }

    /// Format a raw token-account amount (the on-chain integer) for
    /// display, applying decimals. Trims trailing zeros so a USDC
    /// balance of `100000000` renders as "100" not "100.000000".
    func format(rawAmount: UInt64) -> String {
        let s = String(rawAmount)
        let d = Int(decimals)
        if d == 0 { return s }
        let padded = String(repeating: "0", count: max(0, d + 1 - s.count)) + s
        let split = padded.index(padded.endIndex, offsetBy: -d)
        var whole = String(padded[..<split])
        var frac = String(padded[split...])
        if whole.isEmpty { whole = "0" }
        // Drop leading zeros from whole (other than the single 0).
        while whole.count > 1 && whole.first == "0" { whole.removeFirst() }
        // Trim trailing zeros from fractional part.
        while frac.last == "0" { frac.removeLast() }
        return frac.isEmpty ? whole : "\(whole).\(frac)"
    }
}
