// Custom + alternative BIP32 derivation paths for hardware wallets.
//
// By default each chain derives at one fixed path (see `standard…`).
// Some wallets use other conventions (notably Ledger Live's Solana
// `m/44'/501'/{account}'` with no trailing `0'`), so a user importing
// such a seed onto Maknoon would land on a different address. These
// helpers let the add/discover flows offer a custom path and sweep the
// well-known alternatives. Hardware-only: software wallets and the
// identity-sandwich attestation keep their fixed paths.

import Foundation
import SwiftUI

enum BIP32Path {

    enum ParseError: LocalizedError {
        case empty
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "Enter a derivation path."
            case .malformed(let s): return "Not a valid derivation path: \(s)"
            }
        }
    }

    /// Parse "m/44'/501'/0'" into the BIP32 `address_n` components
    /// (hardened markers `'` or `h`/`H` set the 0x80000000 bit). Used to
    /// validate a user-entered path and to derive software addresses.
    static func parse(_ input: String) throws -> [UInt32] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        var body = trimmed
        if body.hasPrefix("m/") || body.hasPrefix("M/") { body.removeFirst(2) }
        if body == "m" || body == "M" { body = "" }
        guard !body.isEmpty else { throw ParseError.empty }

        var out: [UInt32] = []
        for raw in body.split(separator: "/", omittingEmptySubsequences: false) {
            let comp = raw.trimmingCharacters(in: .whitespaces)
            guard !comp.isEmpty else { throw ParseError.malformed(input) }
            var digits = comp
            var hardened = false
            if let last = comp.last, last == "'" || last == "h" || last == "H" {
                hardened = true
                digits = String(comp.dropLast())
            }
            guard let idx = UInt32(digits), idx < 0x8000_0000 else {
                throw ParseError.malformed(input)
            }
            out.append(hardened ? idx | 0x8000_0000 : idx)
        }
        return out
    }

    /// True if `input` parses to a valid path.
    static func isValid(_ input: String) -> Bool {
        (try? parse(input)) != nil
    }

    // MARK: -- standard paths (pre-fill the Advanced field)

    static func standardEthereum(account: UInt32) -> String { "m/44'/60'/\(account)'/0/0" }
    static func standardSolana(account: UInt32) -> String { "m/44'/501'/\(account)'/0'" }
    static func standardTron(account: UInt32) -> String { "m/44'/195'/\(account)'/0/0" }
    /// Bitcoin account-level path; `purpose` selects the script type
    /// (84 native segwit by default). `coinType` 0 mainnet / 1 testnet.
    static func standardBitcoin(account: UInt32, coinType: UInt32, purpose: UInt32 = 84) -> String {
        "m/\(purpose)'/\(coinType)'/\(account)'"
    }

    // MARK: -- Bitcoin script type from path purpose

    enum BitcoinScriptType {
        case legacy        // BIP44, pkh, "1…"
        case nestedSegwit  // BIP49, sh(wpkh), "3…"
        case nativeSegwit  // BIP84, wpkh, "bc1q…"
    }

    /// Map a parsed path's purpose (first component, hardened) to its
    /// script type. Defaults to native segwit for anything unrecognized
    /// so callers never silently mis-derive. Returns nil for taproot
    /// (BIP86), which is intentionally unsupported.
    static func bitcoinScriptType(forPath path: String) -> BitcoinScriptType? {
        guard let comps = try? parse(path), let first = comps.first else {
            return .nativeSegwit
        }
        switch first & ~0x8000_0000 {
        case 44: return .legacy
        case 49: return .nestedSegwit
        case 84: return .nativeSegwit
        case 86: return nil // taproot — not supported
        default: return .nativeSegwit
        }
    }

    // MARK: -- well-known alternatives for the discover sweep

    /// Per-chain alternative path templates with `{account}` placeholder,
    /// in priority order. The standard path is included first so a sweep
    /// can iterate this whole list. For Bitcoin, `{coin}` is also
    /// substituted (0 mainnet / 1 testnet).
    enum Chain { case ethereum, solana, tron, bitcoin }

    static func alternativeTemplates(_ chain: Chain) -> [String] {
        switch chain {
        case .ethereum:
            return [
                "m/44'/60'/{account}'/0/0",   // Ledger Live (our default)
                "m/44'/60'/0'/0/{account}",   // MetaMask / MEW / Trust
                "m/44'/60'/{account}'",       // Ledger legacy
                "m/44'/60'/0'/{account}",     // MEW / MyCrypto legacy
            ]
        case .solana:
            return [
                "m/44'/501'/{account}'/0'",   // Phantom / Solflare / Trust (our default)
                "m/44'/501'/{account}'",      // Ledger Live
                "m/44'/501'/0'/{account}'",   // older 4th-level variant
            ]
        case .tron:
            return [
                "m/44'/195'/{account}'/0/0",  // Ledger / TronLink / Trust (our default)
                "m/44'/195'/{account}'",      // TIP-01
                "m/44'/195'/0'/0/{account}",  // SDK / exchange variant
            ]
        case .bitcoin:
            return [
                "m/84'/{coin}'/{account}'",   // BIP84 native segwit (our default)
                "m/49'/{coin}'/{account}'",   // BIP49 nested segwit
                "m/44'/{coin}'/{account}'",   // BIP44 legacy
            ]
        }
    }

    /// Fill a template's `{account}` (and Bitcoin `{coin}`) placeholders.
    static func fill(_ template: String, account: UInt32, coinType: UInt32 = 0) -> String {
        template
            .replacingOccurrences(of: "{account}", with: String(account))
            .replacingOccurrences(of: "{coin}", with: String(coinType))
    }
}

/// Reusable "Advanced → custom derivation path" disclosure for the
/// hardware add flows (both Ledger and Trezor). Blank = standard path.
struct DerivationPathAdvancedField: View {
    /// The chain's standard path for the chosen account, shown as the
    /// placeholder/hint.
    let standardPath: String
    @Binding var useCustom: Bool
    @Binding var customPath: String

    var body: some View {
        DisclosureGroup("Advanced") {
            Toggle("Use a custom derivation path", isOn: $useCustom)
            if useCustom {
                TextField(standardPath, text: $customPath)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(isProblem ? .red : .secondary)
            }
        }
    }

    private var trimmed: String { customPath.trimmingCharacters(in: .whitespaces) }
    private var isProblem: Bool { !trimmed.isEmpty && !BIP32Path.isValid(trimmed) }
    private var hint: String {
        if trimmed.isEmpty {
            return "Leave blank to use the standard path \(standardPath)."
        }
        return BIP32Path.isValid(trimmed)
            ? "Will derive at \(trimmed)."
            : "Not a valid BIP32 path."
    }

    /// Resolve to a path override: nil when off or blank (= standard).
    static func resolve(useCustom: Bool, customPath: String) -> String? {
        guard useCustom else { return nil }
        let t = customPath.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
