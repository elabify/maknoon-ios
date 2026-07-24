// Cross-network address mismatch detection. Pure and unit-testable.
//
// A recipient address pasted or scanned into the wrong send screen (e.g. a
// Bitcoin address into an Ethereum send) is never intentional and, if it slips
// past, sends funds somewhere unrecoverable. Each send screen already validates
// the recipient against its own network; this classifier adds an explicit,
// friendly cross-network block: it recognises an address that clearly belongs
// to a DIFFERENT network so the screen can refuse it and name the network it
// looks like.
//
// Classification is deliberately conservative: only unambiguous prefixes/shapes
// are recognised (EVM 0x, Tron T-base58, Bitcoin bech32). A bare base58 string
// that could be either Solana or a legacy Bitcoin address is left unclassified
// so the guard never produces a false "wrong network" on a valid address.

import Foundation

enum AddressFamily: String {
    case ethereum
    case tron
    case bitcoin

    var displayName: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .tron: return "Tron"
        case .bitcoin: return "Bitcoin"
        }
    }
}

enum AddressNetworkGuard {
    private static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// Best-effort family of `address` by unambiguous prefix/shape, or nil when
    /// it is not clearly one of the recognised families.
    static func detect(_ address: String) -> AddressFamily? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return nil }

        // EVM: 0x + 40 hex.
        if a.count == 42, a.lowercased().hasPrefix("0x") {
            let hex = a.dropFirst(2)
            if hex.allSatisfy({ $0.isHexDigit }) { return .ethereum }
        }

        // Tron: base58check, 'T' + 33 base58 chars (34 total).
        if a.count == 34, a.hasPrefix("T"), a.allSatisfy({ base58.contains($0) }) {
            return .tron
        }

        // Bitcoin: bech32 / bech32m (segwit). Legacy base58 (1.../3...) is
        // intentionally not classified because it overlaps Solana base58.
        let lower = a.lowercased()
        if lower.hasPrefix("bc1") || lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1") {
            return .bitcoin
        }

        return nil
    }

    /// Returns the family `address` looks like when that differs from the
    /// screen's `current` network family (so the send can be blocked and the
    /// mismatch named), else nil. `current` is nil for networks not covered by
    /// the classifier (e.g. Solana), so any recognised family is a mismatch.
    static func crossNetworkMismatch(_ address: String, current: AddressFamily?) -> AddressFamily? {
        guard let d = detect(address) else { return nil }
        return d == current ? nil : d
    }
}
