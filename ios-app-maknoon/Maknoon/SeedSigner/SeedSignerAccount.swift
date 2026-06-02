// Parser for the account information SeedSigner exports as part of
// the pairing handshake. Two formats are accepted because both are
// what SeedSigner prints to its screen at different points in the
// user flow:
//
//   1. A Specter-style descriptor with key origin:
//        wpkh([abcd1234/84'/0'/0']xpubFooBar/0/*)
//
//   2. Just an xpub line with the master fingerprint and derivation
//      path on its own lines (BlueWallet "cosigner" export shape).
//
// We pull out three things: the 4-byte master fingerprint, the
// derivation path, and the account-level xpub. From those three we
// can build a BDK descriptor and register the device. No private
// keys ever appear in any of the supported formats.

import Foundation

struct SeedSignerAccount: Hashable, Sendable {
    /// Lowercase hex, 8 characters.
    let masterFingerprintHex: String
    /// Derivation path in the form "m/84'/0'/0'" (no leading or
    /// trailing slashes). "m/" prefix is included so the user sees
    /// what was parsed.
    let derivationPath: String
    /// `xpub…` / `tpub…` / `ypub…` / `zpub…` / `vpub…` as printed.
    /// SeedSigner usually emits xpub or tpub.
    let xpub: String

    enum ParseError: LocalizedError {
        case unrecognized
        case missingXpub
        case missingFingerprint

        var errorDescription: String? {
            switch self {
            case .unrecognized:       return "Couldn't recognize that as a SeedSigner account. Paste either a descriptor like wpkh([abcd1234/84h/0h/0h]xpub…/0/*) or the cosigner block."
            case .missingXpub:        return "No xpub found in the input."
            case .missingFingerprint: return "No master fingerprint found in the input."
            }
        }
    }

    static func parse(_ raw: String) throws -> SeedSignerAccount {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ParseError.unrecognized }

        if let descriptor = try? parseDescriptor(s) { return descriptor }
        if let cosigner = try? parseCosigner(s) { return cosigner }
        throw ParseError.unrecognized
    }

    // MARK: -- descriptor form

    private static func parseDescriptor(_ s: String) throws -> SeedSignerAccount {
        // Find the [fingerprint/derivation]xpub pattern inside parens.
        // The bracket can use either ' or h (BIP-380 hardened notation).
        let pattern = #"\[([0-9a-fA-F]{8})((?:/[0-9]+['h]?)*)\]([xtyzv]pub[0-9A-HJ-NP-Za-km-z]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 4,
              let fpRange = Range(match.range(at: 1), in: s),
              let pathRange = Range(match.range(at: 2), in: s),
              let xpubRange = Range(match.range(at: 3), in: s)
        else { throw ParseError.unrecognized }

        let fp = String(s[fpRange]).lowercased()
        let path = "m\(String(s[pathRange]))"  // path captures /84'/0'/0', prepend "m"
        let xpub = String(s[xpubRange])
        return SeedSignerAccount(
            masterFingerprintHex: fp,
            derivationPath: path.replacingOccurrences(of: "h", with: "'"),
            xpub: xpub
        )
    }

    // MARK: -- cosigner form

    private static func parseCosigner(_ s: String) throws -> SeedSignerAccount {
        // BlueWallet-style: a block with "Master fingerprint", "Path",
        // and an xpub line. Tolerant to whitespace / colons. Some
        // SeedSigner exports also include a "Format" label which we
        // ignore.
        let lines = s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        var fingerprint: String?
        var path: String?
        var xpub: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("fingerprint") {
                if let v = extractHexAfter(line: line, count: 8) {
                    fingerprint = v.lowercased()
                }
            } else if lower.contains("path") || lower.contains("derivation") {
                if let v = extractPath(line) {
                    path = v
                }
            } else if let kind = ["xpub", "tpub", "ypub", "zpub", "vpub"].first(where: { lower.contains($0) }) {
                if let token = line.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
                    .first(where: { $0.lowercased().hasPrefix(kind) }) {
                    xpub = String(token)
                }
            }
        }
        guard let xpub else { throw ParseError.missingXpub }
        guard let fingerprint else { throw ParseError.missingFingerprint }
        return SeedSignerAccount(
            masterFingerprintHex: fingerprint,
            derivationPath: path ?? "m/84'/0'/0'",
            xpub: xpub
        )
    }

    private static func extractHexAfter(line: String, count: Int) -> String? {
        let hex = line.filter { $0.isHexDigit }
        guard hex.count >= count else { return nil }
        return String(hex.suffix(count))
    }

    private static func extractPath(_ line: String) -> String? {
        // Pull a token starting with m/ or M/ or just numeric segments.
        let scalars = "0123456789'h/m"
        guard let i = line.firstIndex(where: { $0 == "m" || $0 == "M" || $0 == "/" }) else { return nil }
        var path = ""
        for ch in line[i...] {
            if scalars.contains(ch.lowercased()) || ch == "'" {
                path.append(ch)
            } else if ch.isWhitespace && !path.isEmpty {
                break
            } else if !path.isEmpty {
                break
            }
        }
        return path.isEmpty ? nil : path.replacingOccurrences(of: "h", with: "'")
    }
}
