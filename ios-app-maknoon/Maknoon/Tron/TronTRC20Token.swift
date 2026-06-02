// TRC-20 token model. Mirrors `SolanaSPLToken` and `EthereumToken`:
// per-(network, contract) persistable metadata, decimals-aware
// formatter, source provenance.

import Foundation

enum TronTokenSource: String, Codable, Sendable, Hashable {
    /// Auto-installed after matching the user's wallet activity
    /// against the cached TronScan verified list.
    case tronscan
    /// User typed in decimals + symbol manually. No trust anchor;
    /// surface clearly in the UI ("Custom").
    case custom
}

struct TronTRC20Token: Codable, Identifiable, Hashable, Sendable {
    let network: TronNetwork
    /// Base58 T-prefixed contract address.
    let contract: String
    var symbol: String
    var name: String
    let decimals: UInt8
    var logoURI: String?
    var source: TronTokenSource

    var id: String { "\(network.rawValue):\(contract)" }

    init(
        network: TronNetwork,
        contract: String,
        symbol: String,
        name: String,
        decimals: UInt8,
        logoURI: String? = nil,
        source: TronTokenSource
    ) {
        self.network = network
        self.contract = contract
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.logoURI = logoURI
        self.source = source
    }

    /// CoinGecko asset id derived from the token symbol. nil when
    /// we don't have a price feed; the send view hides the fiat
    /// denomination picker for tokens that return nil.
    var coinGeckoId: String? {
        switch symbol.uppercased() {
        case "USDT":  return "tether"
        case "USDC":  return "usd-coin"
        case "USDD":  return "usdd"
        case "TUSD":  return "true-usd"
        case "BTT":   return "bittorrent"
        case "WIN":   return "wink"
        case "JST":   return "just"
        case "SUN":   return "sun-token"
        default:      return nil
        }
    }

    /// Format a raw amount string (the on-chain integer as base-10
    /// decimal) for display. TRC-20 amounts can exceed UInt64 so the
    /// input is a string, processed digit-by-digit.
    func format(rawAmountDecimal: String) -> String {
        let s = rawAmountDecimal.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber }) else { return "0" }
        let d = Int(decimals)
        if d == 0 { return s }
        let padded = String(repeating: "0", count: max(0, d + 1 - s.count)) + s
        let split = padded.index(padded.endIndex, offsetBy: -d)
        var whole = String(padded[..<split])
        var frac = String(padded[split...])
        if whole.isEmpty { whole = "0" }
        while whole.count > 1 && whole.first == "0" { whole.removeFirst() }
        while frac.last == "0" { frac.removeLast() }
        return frac.isEmpty ? whole : "\(whole).\(frac)"
    }
}
