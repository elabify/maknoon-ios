// Convert a BIP32 / BIP49 / BIP84 extended public key string
// (xpub / ypub / zpub / Ypub / Zpub on mainnet, tpub / upub /
// vpub / Upub / Vpub on testnet/signet) into the canonical
// xpub-or-tpub shape BDK's descriptor parser accepts.
//
// The keys are byte-identical aside from a 4-byte version prefix;
// the slip-132 alternate prefixes are a hint about the intended
// derivation path (BIP49 = nested segwit, BIP84 = native segwit)
// and aren't load-bearing in the descriptor itself, since the
// descriptor's fragment (wpkh / sh-wpkh / pkh) carries that
// information explicitly. We base58check-decode, swap the
// 4-byte version, re-encode.
//
// SeedSigner's BlueWallet export emits a zpub for BIP84 native
// segwit on mainnet (or vpub on testnet). BDK rejects those with
// `DescriptorKeyParseError("Error while parsing xkey.")` until
// they're normalized.

import Foundation
import CryptoKit

enum ExtendedKeyNormalize {

    /// Mainnet BIP32 legacy version bytes (xpub).
    private static let mainnetXpub:  [UInt8] = [0x04, 0x88, 0xB2, 0x1E]
    /// Testnet/signet/regtest BIP32 legacy version bytes (tpub).
    private static let testnetTpub:  [UInt8] = [0x04, 0x35, 0x87, 0xCF]

    /// Mainnet alternates we want to normalize TO xpub.
    private static let mainnetAlternates: [[UInt8]] = [
        [0x04, 0x9D, 0x7C, 0xB2], // ypub  (BIP49)
        [0x04, 0xB2, 0x47, 0x46], // zpub  (BIP84)
        [0x02, 0x95, 0xB4, 0x3F], // Ypub  (BIP49 multisig)
        [0x02, 0xAA, 0x7E, 0xD3], // Zpub  (BIP84 multisig)
    ]

    /// Testnet alternates we want to normalize TO tpub.
    private static let testnetAlternates: [[UInt8]] = [
        [0x04, 0x4A, 0x52, 0x62], // upub  (BIP49)
        [0x04, 0x5F, 0x1C, 0xF6], // vpub  (BIP84)
        [0x02, 0x42, 0x89, 0xEF], // Upub  (BIP49 multisig)
        [0x02, 0x57, 0x54, 0x83], // Vpub  (BIP84 multisig)
    ]

    /// Return `extKey` rewritten to xpub/tpub if it currently uses
    /// a slip-132 alternate prefix. xpub/tpub inputs pass through
    /// unchanged. Returns the input unchanged on any decode error
    /// so the caller hands BDK the original string and BDK
    /// produces a meaningful error message.
    static func toXpubLegacy(_ extKey: String) -> String {
        let trimmed = extKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Base58Check.decode(trimmed), raw.count >= 4 else {
            return extKey
        }
        let prefix = Array(raw.prefix(4))
        let body = Array(raw.dropFirst(4))

        // Decide the canonical version: mainnet alternates → xpub,
        // testnet alternates → tpub. xpub/tpub themselves are
        // already canonical.
        let canonical: [UInt8]
        if prefix == mainnetXpub || prefix == testnetTpub {
            return extKey
        } else if mainnetAlternates.contains(where: { $0 == prefix }) {
            canonical = mainnetXpub
        } else if testnetAlternates.contains(where: { $0 == prefix }) {
            canonical = testnetTpub
        } else {
            // Unknown prefix; leave untouched.
            return extKey
        }
        return Base58Check.encode(canonical + body)
    }
}

/// Minimal Base58Check codec. Just enough for the version-byte
/// swap above; not exposed elsewhere. The standard Bitcoin Base58
/// alphabet + SHA256(SHA256(payload))[0..4] checksum.
enum Base58Check {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let indexOf: [Character: Int] = {
        var d: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { d[c] = i }
        return d
    }()

    /// Decode a Base58Check string into the raw payload (checksum
    /// stripped). Returns nil if the checksum doesn't verify or
    /// the input isn't valid Base58.
    static func decode(_ s: String) -> [UInt8]? {
        guard !s.isEmpty else { return nil }

        // Count leading "1"s, those map to leading zero bytes.
        var zeros = 0
        for ch in s {
            if ch == "1" { zeros += 1 } else { break }
        }

        // Big-int accumulator: process each char as base-58 digit.
        var num: [UInt8] = []
        for ch in s {
            guard let digit = indexOf[ch] else { return nil }
            var carry = digit
            for i in (0..<num.count).reversed() {
                let v = Int(num[i]) * 58 + carry
                num[i] = UInt8(v & 0xFF)
                carry = v >> 8
            }
            while carry > 0 {
                num.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let bytes = [UInt8](repeating: 0, count: zeros) + num

        // Verify the trailing 4-byte SHA-256d checksum.
        guard bytes.count >= 4 else { return nil }
        let payload = Array(bytes.dropLast(4))
        let checksum = Array(bytes.suffix(4))
        let expected = sha256d(payload).prefix(4)
        guard Array(expected) == checksum else { return nil }
        return payload
    }

    /// Encode raw payload bytes into a Base58Check string
    /// (appending the standard checksum).
    static func encode(_ payload: [UInt8]) -> String {
        let checksum = Array(sha256d(payload).prefix(4))
        var bytes = payload + checksum

        // Count leading zero bytes, encode as leading "1"s.
        var zeros = 0
        for b in bytes { if b == 0 { zeros += 1 } else { break } }

        // Big-int divide-by-58 loop produces digits in reverse.
        var digits: [Int] = []
        bytes = Array(bytes.dropFirst(zeros))
        while !bytes.isEmpty {
            var remainder = 0
            var next: [UInt8] = []
            for byte in bytes {
                let acc = remainder * 256 + Int(byte)
                let q = acc / 58
                remainder = acc % 58
                if !next.isEmpty || q > 0 { next.append(UInt8(q)) }
            }
            digits.append(remainder)
            bytes = next
        }
        let body = String(digits.reversed().map { alphabet[$0] })
        return String(repeating: "1", count: zeros) + body
    }

    private static func sha256d(_ data: [UInt8]) -> [UInt8] {
        let first = SHA256.hash(data: data)
        let second = SHA256.hash(data: Data(first))
        return Array(second)
    }
}
