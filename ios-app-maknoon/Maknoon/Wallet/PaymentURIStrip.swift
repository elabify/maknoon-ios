// Reduce a scanned / pasted payment URI to the bare recipient address. Pure and
// unit-testable, shared by the Bitcoin (BIP21), Solana Pay and Tron send
// screens.
//
// For all three schemes the recipient is the URI PATH; query parameters
// (amount, label, spl-token, ...) are handled separately by the send screen.
// So the rule is: trim, drop an optional case-insensitive `<scheme>:` prefix,
// and cut off anything from the first `?`. Unlike EIP-681 there is no function
// call or address query parameter here, so returning the path is correct (this
// is the shape the amount-QR fund-loss bug did NOT have; see EthereumURIParser).
//
// Note the Solana Pay transaction-request form `solana:https://host/...`: the
// path is a URL, so this returns that URL, which then fails address validation
// loudly rather than being sent anywhere.

import Foundation

enum PaymentURIStrip {
    static func strip(_ raw: String, scheme: String) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(scheme):"
        if out.lowercased().hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count))
        }
        if let q = out.firstIndex(of: "?") {
            out = String(out[..<q])
        }
        return out
    }

    static func bitcoin(_ s: String) -> String { strip(s, scheme: "bitcoin") }
    static func solana(_ s: String) -> String { strip(s, scheme: "solana") }
    static func tron(_ s: String) -> String { strip(s, scheme: "tron") }
}
