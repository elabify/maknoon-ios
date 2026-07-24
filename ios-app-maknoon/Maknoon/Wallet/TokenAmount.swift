// Exact decimal-amount to base-unit conversion, shared across the Solana and
// Tron send paths. Pure and unit-testable.
//
// The user enters an amount in whole token units (e.g. "1443.927713" USDC).
// The transaction needs that value as an integer number of base units, scaled
// by 10^decimals. Doing this with a binary `Double` (Double(amount) * pow(10,
// decimals)) loses precision: many decimal fractions are not representable in
// binary, and values past 2^53 significant bits drop low digits, so a large or
// high-decimal amount can scale to the WRONG integer. This does string math on
// the decimal digits instead, so the result is always exact and matches the
// Android BigDecimal / string path byte-for-byte (see amount-scaling-kat.json).
//
// Contract: reject (nil) malformed input, negatives, more than one dot, or more
// fractional digits than the token supports. We never silently truncate
// sub-unit precision, i.e. "0.1234567" for a 6-decimal token is refused, not
// rounded, so the user cannot unknowingly send a different amount than typed.

import Foundation

enum TokenAmount {
    /// Convert a whole-unit decimal `amount` string to an exact base-unit
    /// integer string, scaling by 10^`decimals`. Returns nil on malformed
    /// input or fractional precision finer than `decimals`.
    static func baseUnits(_ amount: String, decimals: Int) -> String? {
        guard decimals >= 0 else { return nil }
        let t = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }

        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { return nil }

        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        guard isAllASCIIDigits(whole) else { return nil }

        let fracRaw = parts.count == 2 ? String(parts[1]) : ""
        guard isAllASCIIDigits(fracRaw) else { return nil }
        if fracRaw.count > decimals { return nil }

        let frac = decimals == 0
            ? ""
            : fracRaw.padding(toLength: decimals, withPad: "0", startingAt: 0)

        let combined = whole + frac
        let trimmed = String(combined.drop { $0 == "0" })
        return trimmed.isEmpty ? "0" : trimmed
    }

    /// Same as `baseUnits` but returns a `UInt64` (nil if out of range), for
    /// callers whose base-unit type is UInt64 (Solana lamports / SPL raw).
    static func baseUnitsUInt64(_ amount: String, decimals: Int) -> UInt64? {
        guard let s = baseUnits(amount, decimals: decimals) else { return nil }
        return UInt64(s)
    }

    private static func isAllASCIIDigits(_ s: String) -> Bool {
        // Empty string counts as "all digits" (the no-fraction case handles it).
        s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
