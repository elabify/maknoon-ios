// Minimal bech32 codec — just what LNURL decoding needs.
// LNURLs are bech32-encoded with HRP "lnurl" and a checksum.
// The decoded data bytes are an ASCII URL (after 5→8 bit
// regrouping).
//
// Spec reference: BIP-173 (bech32) + LUD-01 (LNURL).
// We support up to 4096-char codes (LNURL doesn't enforce a
// limit; the 90-char BIP-173 limit is irrelevant here).

import Foundation

enum Bech32 {
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private static let generator: [UInt32] = [
        0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3,
    ]

    static func decode(_ raw: String) -> (hrp: String, data: [UInt8])? {
        let lower = raw.lowercased()
        let upper = raw.uppercased()
        if raw != lower && raw != upper { return nil }
        guard let separator = lower.lastIndex(of: "1") else { return nil }
        let hrpEnd = lower.distance(from: lower.startIndex, to: separator)
        guard hrpEnd >= 1 else { return nil }
        let hrp = String(lower[lower.startIndex..<separator])
        let dataPart = String(lower[lower.index(after: separator)...])
        guard dataPart.count >= 6 else { return nil }

        var values: [UInt8] = []
        for ch in dataPart {
            guard let idx = charset.firstIndex(of: ch) else { return nil }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }
        guard verifyChecksum(hrp: hrp, data: values) else { return nil }
        // Drop the 6-character checksum suffix.
        let payload = Array(values.dropLast(6))
        return (hrp, payload)
    }

    /// 5-bit → 8-bit regroup. Used after `decode(...)` to recover
    /// the underlying byte string from a bech32 payload.
    static func convertBits(_ data: [UInt8], from fromBits: Int, to toBits: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var out: [UInt8] = []
        let maxv = (1 << toBits) - 1
        for value in data {
            guard value >> fromBits == 0 else { return nil }
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (toBits - bits)) & maxv)) }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(value)
            for i in 0..<5 {
                if (top >> i) & 1 != 0 { chk ^= generator[i] }
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var values: [UInt8] = []
        for ch in hrp.unicodeScalars { values.append(UInt8(ch.value >> 5)) }
        values.append(0)
        for ch in hrp.unicodeScalars { values.append(UInt8(ch.value & 0x1f)) }
        return values
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        return polymod(hrpExpand(hrp) + data) == 1
    }
}
