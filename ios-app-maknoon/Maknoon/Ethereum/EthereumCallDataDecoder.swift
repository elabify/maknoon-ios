// Best-effort decode of EVM calldata for the mini-app approval sheet, so a user
// sees "Approve token spend / Amount 100000000" instead of raw hex before they
// sign. Only the selectors a retail swap flow needs are decoded (ERC-20
// approve / transfer); anything else returns nil and the sheet shows the raw
// calldata under a clearly-labeled "advanced" view. The wallet never
// blind-signs silently: unknown calldata is still surfaced verbatim.

import Foundation

enum EthereumCallDataDecoder {
    struct Decoded {
        /// One-line human summary, e.g. "Approve token spend".
        let summary: String
        /// Ordered labeled fields shown in the sheet.
        let fields: [(String, String)]
    }

    /// Decode `data` sent to `to`. Returns nil for unrecognized selectors.
    static func decode(to: String, data: Data) -> Decoded? {
        guard data.count >= 4 else { return nil }
        let selector = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        let args = data.dropFirst(4)
        switch selector {
        case "095ea7b3": // approve(address,uint256)
            guard let (spender, amount) = addressAndUint(args) else { return nil }
            return Decoded(summary: "Approve token spend",
                           fields: [("Token", to), ("Spender", spender), ("Amount", amount)])
        case "a9059cbb": // transfer(address,uint256)
            guard let (recipient, amount) = addressAndUint(args) else { return nil }
            return Decoded(summary: "Token transfer",
                           fields: [("Token", to), ("To", recipient), ("Amount", amount)])
        default:
            return nil
        }
    }

    /// (address in first word, uint256 in second word as a decimal string).
    private static func addressAndUint(_ args: Data) -> (String, String)? {
        guard args.count >= 64 else { return nil }
        let a = Array(args)
        let address = "0x" + a[12..<32].map { String(format: "%02x", $0) }.joined()
        let amount = decimalString(bigEndian: Array(a[32..<64]))
        return (address, amount)
    }

    /// 32-byte big-endian unsigned integer -> base-10 string (no BigInt dep).
    private static func decimalString(bigEndian bytes: [UInt8]) -> String {
        var digits = [0] // little-endian base-10 digits
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                let v = digits[i] * 256 + carry
                digits[i] = v % 10
                carry = v / 10
            }
            while carry > 0 { digits.append(carry % 10); carry /= 10 }
        }
        return String(digits.reversed().map { Character("\($0)") })
    }
}
