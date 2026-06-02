// Shared parser for the standard "TokenList" JSON schema used by
// CoinGecko, Uniswap, Trust Wallet, Jupiter, and most other public
// token registries. The shape is:
//
//   { "name": "...",
//     "tokens": [
//       { "chainId": 1,
//         "address": "0x...",
//         "name": "USD Coin",
//         "symbol": "USDC",
//         "decimals": 6,
//         "logoURI": "..." }
//     ] }
//
// Different chains use the `address` field differently (EVM hex,
// Solana base58 mint, Tron base58check). The caller provides a
// `normalize` closure to canonicalise the address (e.g. lowercase
// for EVM); per-chain catalogs build their own `Entry` types on top
// of the parser's `TokenListEntry`.

import Foundation

enum TokenListParseError: LocalizedError {
    case missingTokensArray

    var errorDescription: String? {
        switch self {
        case .missingTokensArray: return "Catalog JSON did not include a `tokens` array."
        }
    }
}

/// One parsed entry from a TokenList JSON. Chain-agnostic; the
/// caller post-processes (filter by chainId, normalise address).
struct TokenListEntry: Sendable, Hashable {
    let chainId: Int?
    let address: String
    let symbol: String
    let name: String
    let decimals: UInt8
    let logoURI: String?
}

enum TokenListParser {
    /// Decode a TokenList JSON payload. The optional `normalize`
    /// closure lets per-chain callers lowercase EVM addresses or
    /// otherwise canonicalise. Malformed rows are silently skipped
    /// so a single bad entry doesn't reject the whole catalog.
    static func parse(data: Data, normalize: (String) -> String) throws -> [TokenListEntry] {
        struct Envelope: Decodable {
            let tokens: [Row]?
        }
        struct Row: Decodable {
            let chainId: AnyOptionalInt?
            let address: String?
            let name: String?
            let symbol: String?
            let decimals: AnyOptionalInt?
            let logoURI: String?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let rows = env.tokens else {
            throw TokenListParseError.missingTokensArray
        }
        var out: [TokenListEntry] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let addr = row.address?.trimmingCharacters(in: .whitespaces), !addr.isEmpty,
                  let sym = row.symbol,
                  let nm = row.name,
                  let d = row.decimals?.value
            else { continue }
            out.append(TokenListEntry(
                chainId: row.chainId?.value,
                address: normalize(addr),
                symbol: sym,
                name: nm,
                decimals: UInt8(clamping: d),
                logoURI: row.logoURI
            ))
        }
        return out
    }
}

/// Tolerant decoder for JSON fields that may arrive as either an
/// Int or a String (CoinGecko + TronScan both vary on this).
struct AnyOptionalInt: Decodable, Hashable, Sendable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = nil; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let s = try? c.decode(String.self), let i = Int(s) { self.value = i; return }
        self.value = nil
    }
}
