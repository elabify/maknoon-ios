// Wei is a 256-bit unsigned integer; Swift has no native UInt256.
// We carry it as a hex string (the form RPC returns) and provide
// view-friendly conversions to ether (Decimal) and to the
// chain-specific ticker. Phase 2 added `bigEndianBytes` for the
// TWC protobuf signing path, which expects unpadded big-endian
// Data for chainID / nonce / gas / value fields.

import Foundation

struct EthereumWeiValue: Codable, Hashable, Sendable {
    /// Lower-case hex, no `0x` prefix. Empty string never happens; a
    /// pure-zero value canonicalises to "0".
    let hex: String

    init(hex: String) throws {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        if s.isEmpty { s = "0" }
        guard s.allSatisfy({ $0.isHexDigit }) else {
            throw EthereumRPCClient.Error.malformedResponse("Bad wei hex '\(hex)'")
        }
        // Drop redundant leading zeros for stable equality. "00" → "0".
        var stripped = s.lowercased()
        while stripped.count > 1 && stripped.first == "0" { stripped.removeFirst() }
        self.hex = stripped
    }

    static let zero = (try? EthereumWeiValue(hex: "0")) ?? EthereumWeiValue(unsafeRawHex: "0")
    private init(unsafeRawHex s: String) { self.hex = s }

    /// Construct from an unsigned integer. Convenient for nonce and
    /// chainID which RPC returns as small values.
    init(uint64 v: UInt64) {
        try! self.init(hex: String(v, radix: 16))
    }

    /// Big-endian byte representation with leading zeros stripped, as
    /// required by Trust Wallet Core's Ethereum protobuf fields
    /// (chainID, nonce, gas*, transfer.amount). An exact zero is a
    /// single 0x00 byte rather than the empty Data.
    var bigEndianBytes: Data {
        var s = hex
        if s.count % 2 == 1 { s = "0" + s }
        var bytes: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return Data([0]) }
            bytes.append(b)
            idx = next
        }
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        return Data(bytes)
    }

    /// Sum of two wei values. Wraps through Decimal which holds up to
    /// 38 significant digits, more than enough for amount + maxFee ×
    /// gasLimit (typical values stay well under 10^27).
    static func + (lhs: EthereumWeiValue, rhs: EthereumWeiValue) -> EthereumWeiValue {
        return EthereumWeiValue(decimal: lhs.decimal + rhs.decimal)
    }

    /// Product of two wei values (maxFeePerGas × gasLimit). Same
    /// precision caveat as +.
    static func * (lhs: EthereumWeiValue, rhs: EthereumWeiValue) -> EthereumWeiValue {
        return EthereumWeiValue(decimal: lhs.decimal * rhs.decimal)
    }

    static func > (lhs: EthereumWeiValue, rhs: EthereumWeiValue) -> Bool {
        return lhs.decimal > rhs.decimal
    }

    static func < (lhs: EthereumWeiValue, rhs: EthereumWeiValue) -> Bool {
        return lhs.decimal < rhs.decimal
    }

    /// Decimal-ether (user input) → wei. Truncates anything beyond 18
    /// decimal places. Returns nil on negative or non-numeric input.
    static func fromEther(_ etherString: String) -> EthereumWeiValue? {
        let trimmed = etherString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amt = Decimal(string: trimmed), amt >= 0 else { return nil }
        let multiplier = pow(Decimal(10), 18)
        var product = amt * multiplier
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .down)
        return EthereumWeiValue(decimal: rounded)
    }

    /// Generic "human → raw-units" parse. Token-aware send flows use
    /// this with `decimals = token.decimals` (USDC=6, DAI=18, etc).
    /// Returns nil on negative / non-numeric input.
    static func fromUnits(_ str: String, decimals: Int) -> EthereumWeiValue? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amt = Decimal(string: trimmed), amt >= 0 else { return nil }
        let multiplier = pow(Decimal(10), decimals)
        var product = amt * multiplier
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .down)
        return EthereumWeiValue(decimal: rounded)
    }

    /// Inverse of fromUnits: raw → human-Decimal for display.
    func units(decimals: Int) -> Decimal {
        return self.decimal / pow(Decimal(10), decimals)
    }

    /// Human-readable display in arbitrary-decimal token units.
    func displayUnits(ticker: String, decimals: Int, maxDecimals: Int = 6) -> String {
        let u = units(decimals: decimals)
        var rounded = Decimal()
        var src = u
        NSDecimalRound(&rounded, &src, maxDecimals, .plain)
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxDecimals
        f.decimalSeparator = "."
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        let n = NSDecimalNumber(decimal: rounded)
        return "\(f.string(from: n) ?? "0") \(ticker)"
    }

    /// Decimal-gwei → wei. Gas tier values come from RPC in gwei; the
    /// UI also shows gwei. Round trip preserved exactly because 10^9
    /// fits Decimal precision.
    static func fromGwei(_ gweiString: String) -> EthereumWeiValue? {
        let trimmed = gweiString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amt = Decimal(string: trimmed), amt >= 0 else { return nil }
        let multiplier = pow(Decimal(10), 9)
        var product = amt * multiplier
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .down)
        return EthereumWeiValue(decimal: rounded)
    }

    /// Integer wei as a Decimal. Loses precision above ~2^113 wei but
    /// real ETH balances and fee math stay well below that.
    var decimal: Decimal {
        var dec = Decimal(0)
        for ch in hex {
            guard let v = ch.hexDigitValue else { continue }
            dec = dec * 16 + Decimal(v)
        }
        return dec
    }

    /// Convert to ether as a Decimal. Same precision caveats as
    /// `decimal`; safe for display.
    var ether: Decimal {
        return decimal / pow(Decimal(10), 18)
    }

    /// Convert to gwei (1 gwei = 10^9 wei). Used for the gas tier UI.
    var gwei: Decimal {
        return decimal / pow(Decimal(10), 9)
    }

    /// Human-readable display, trims trailing zeros, caps decimals.
    func display(ticker: String, maxDecimals: Int = 8) -> String {
        let e = ether
        var rounded = Decimal()
        var src = e
        NSDecimalRound(&rounded, &src, maxDecimals, .plain)
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxDecimals
        f.decimalSeparator = "."
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        let n = NSDecimalNumber(decimal: rounded)
        return "\(f.string(from: n) ?? "0") \(ticker)"
    }

    func displayGwei(maxDecimals: Int = 3) -> String {
        var rounded = Decimal()
        var src = gwei
        NSDecimalRound(&rounded, &src, maxDecimals, .plain)
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxDecimals
        return f.string(from: NSDecimalNumber(decimal: rounded)) ?? "0"
    }

    /// Decimal → hex. Routes through a base-10 string so the
    /// conversion is exact (no rounding artefacts). Decimal's own
    /// stringValue is canonical for integer values.
    init(decimal d: Decimal) {
        if d <= 0 { self.hex = "0"; return }
        var rounded = Decimal()
        var src = d
        NSDecimalRound(&rounded, &src, 0, .down)
        let str = NSDecimalNumber(decimal: rounded).stringValue
        let bytes = Self.base10ToBase256(str)
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        var stripped = h
        while stripped.count > 1 && stripped.first == "0" { stripped.removeFirst() }
        self.hex = stripped
    }

    /// Base-10 digit string → big-endian base-256 byte array. Long
    /// division: repeatedly divide the digit array by 256, collect
    /// remainders. Output bytes are most-significant-first.
    private static func base10ToBase256(_ str: String) -> [UInt8] {
        var digits: [UInt8] = str.compactMap { ch in
            guard let v = ch.wholeNumberValue, (0...9).contains(v) else { return nil }
            return UInt8(v)
        }
        if digits.isEmpty || digits.allSatisfy({ $0 == 0 }) { return [0] }
        var bytes: [UInt8] = []
        while !digits.isEmpty {
            var newDigits: [UInt8] = []
            var carry: UInt32 = 0
            for d in digits {
                let cur = carry * 10 + UInt32(d)
                let q = cur / 256
                carry = cur % 256
                if !newDigits.isEmpty || q > 0 {
                    newDigits.append(UInt8(q))
                }
            }
            bytes.append(UInt8(carry))
            digits = newDigits
        }
        return bytes.reversed()
    }
}
