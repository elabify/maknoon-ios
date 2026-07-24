// EIP-681 / bare-address payment URI parser. Pure and testable.
//
// A token-payment QR looks like:
//   ethereum:0x<TOKEN>@<chainId>/transfer?address=0x<RECIPIENT>&uint256=<amt>
// where the URI target is the TOKEN CONTRACT and the real recipient
// is the `address=` query parameter. Naively stripping the prefix and
// chopping at `?`/`@` returns the contract, so a token transfer would
// be built as transfer(<contract>, amount) and the tokens would go to
// the contract instead of the recipient. This parser keeps the two
// apart: the recipient is always the wallet address, the token
// contract (when present) is reported separately.
//
// A plain send QR looks like:
//   ethereum:0x<RECIPIENT>            (native, no function)
//   ethereum:0x<RECIPIENT>?value=<wei>
// or just a bare 0x address / ENS name, all of which resolve to a
// recipient with no token contract.

import Foundation

enum EthereumURIParser {

    struct Parsed {
        /// The wallet address funds should go to. For a bare address
        /// or ENS name this is that string; for a token transfer it is
        /// the `address=` query parameter, never the contract.
        let recipient: String
        /// The ERC-20 contract when this is a `transfer` request, else nil.
        let tokenContract: String?
        /// Raw integer base-unit amount (query `uint256` for tokens,
        /// `value` in wei for native), when present.
        let amountBaseUnits: String?
    }

    static func parse(_ raw: String) -> Parsed {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop a leading `ethereum:` (case-insensitive) scheme.
        var body = cleaned
        if body.lowercased().hasPrefix("ethereum:") {
            body = String(body.dropFirst("ethereum:".count))
        }

        // Split the query string off at the first `?`.
        var query: [String: String] = [:]
        if let q = body.firstIndex(of: "?") {
            let queryString = String(body[body.index(after: q)...])
            body = String(body[..<q])
            query = parseQuery(queryString)
        }

        // From the part before `?`: peel off `/function` at the first
        // `/`, then drop any `@chainId` at the first `@`. What remains
        // is the target.
        var function: String?
        if let slash = body.firstIndex(of: "/") {
            function = String(body[body.index(after: slash)...])
            body = String(body[..<slash])
        }
        if let at = body.firstIndex(of: "@") {
            body = String(body[..<at])
        }
        let target = body

        if function == "transfer" {
            // Token transfer request: recipient is the address param,
            // the target is the token contract.
            return Parsed(
                recipient: query["address"] ?? "",
                tokenContract: target,
                amountBaseUnits: query["uint256"]
            )
        }

        // Bare address / native send: the target is the recipient.
        return Parsed(
            recipient: target,
            tokenContract: nil,
            amountBaseUnits: query["value"]
        )
    }

    /// Parse `k=v&k2=v2` into a dictionary, percent-decoding values.
    static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let value = rawValue.removingPercentEncoding ?? rawValue
            out[String(key)] = value
        }
        return out
    }
}

/// Safety guard for token sends. Pure + unit-testable (the send view computes
/// its inputs and calls this). Sending an ERC-20 to a contract address (its own
/// contract, another token's contract, or any address that has bytecode) sends
/// the tokens to that contract rather than a person, so the send path blocks it.
/// Native ETH sends to a contract are legitimate and never blocked here.
enum EthereumSendGuard {
    /// - recipient: the resolved 0x recipient address.
    /// - isTokenSend: true when an ERC-20 token (not native ETH) is selected.
    /// - selectedTokenContract: the selected token's own contract, if any.
    /// - knownTokenContracts: every ERC-20 contract configured for this (wallet, chain).
    /// - recipientHasCode: eth_getCode found bytecode at the recipient.
    static func blocksTokenSend(
        recipient: String,
        isTokenSend: Bool,
        selectedTokenContract: String?,
        knownTokenContracts: [String],
        recipientHasCode: Bool
    ) -> Bool {
        guard isTokenSend else { return false }
        let r = recipient.lowercased()
        guard !r.isEmpty else { return false }
        if let sel = selectedTokenContract?.lowercased(), r == sel { return true }
        if knownTokenContracts.contains(where: { $0.lowercased() == r }) { return true }
        return recipientHasCode
    }
}
