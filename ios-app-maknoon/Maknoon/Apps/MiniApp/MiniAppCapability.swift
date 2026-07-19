// Single source of truth for mini-app capabilities: the things a app can
// ask the host to do. Each capability token (the same string a namespace
// handler declares as `requiredPermission`) has a consent tier, a
// human-facing label + reason, and an SF Symbol for the install/settings UI.
//
// Tiers:
//   .auto    : always available, low-risk; not declared, not shown, no consent
//              (storage, fiat, device, haptics, biometric gate).
//   .install : must be declared and SHOWN at install for the user to accept;
//              granted for the app's lifetime (addressBook, wallet read,
//              share, clipboard).
//   .perUse  : declared at install AND prompted natively every time it runs
//              (identity disclosure, payments, signing, camera scan, NFC tap).
//
// Trust: the host mediates all of these; raw sensors/keys never reach JS.

import Foundation

enum CapabilityTier: String, Sendable {
    case auto
    case install
    case perUse
}

struct MiniAppCapabilitySpec: Sendable, Identifiable {
    let token: String
    let tier: CapabilityTier
    let label: String
    let reason: String          // default reason; a catalog entry may override
    let icon: String            // SF Symbol
    var id: String { token }
}

enum MiniAppCapabilityRegistry {
    /// Known declarable capabilities (tier .install / .perUse). Tokens not in
    /// this map are treated as `.auto` (no declaration or consent needed).
    static let specs: [String: MiniAppCapabilitySpec] = [
        "identity": .init(token: "identity", tier: .perUse,
                          label: "Verify Credentials",
                          reason: "Receive a customer's credentials and perform checks on them.",
                          icon: "person.text.rectangle"),
        "payment": .init(token: "payment", tier: .perUse,
                         label: "Payments",
                         reason: "Make a payment to a receiving address.",
                         icon: "creditcard"),
        // Hierarchical per-network wallet capabilities (ADR-0057). The dotted
        // token is `wallet.<network>.<capability>`; granularity is per-network
        // (Ethereum covers all EVM chains). read is install-tier (silent RPC
        // reads + connect + chain switch); write/sign are perUse (a native
        // approval sheet runs for each). Bitcoin/Solana are reserved by the ADR.
        "wallet.ethereum.read": .init(token: "wallet.ethereum.read", tier: .install,
                     label: "Ethereum: Network Access",
                     reason: "Read Ethereum network state (balances, gas, contract reads) and switch chains.",
                     icon: "network"),
        "wallet.ethereum.write": .init(token: "wallet.ethereum.write", tier: .perUse,
                     label: "Ethereum: Write Transactions",
                     reason: "Submit Ethereum transactions from your wallet. You approve each one.",
                     icon: "paperplane"),
        "wallet.ethereum.sign": .init(token: "wallet.ethereum.sign", tier: .perUse,
                     label: "Ethereum: Sign Messages",
                     reason: "Sign Ethereum messages and typed data. You approve each one.",
                     icon: "signature"),
        // Legacy flat token, superseded by wallet.ethereum.* (expanded at parse).
        "evm": .init(token: "evm", tier: .perUse,
                     label: "Ethereum wallet",
                     reason: "Connect and request signatures or transactions",
                     icon: "link"),
        "wallet": .init(token: "wallet", tier: .install,
                        label: "Wallets",
                        reason: "See your wallet labels, addresses, and assets across networks and chains.",
                        icon: "wallet.pass"),
        "scan": .init(token: "scan", tier: .perUse,
                      label: "Scan codes",
                      reason: "Open the camera to scan a QR or barcode",
                      icon: "qrcode.viewfinder"),
        "share": .init(token: "share", tier: .install,
                       label: "Share",
                       reason: "Share content using the system share sheet",
                       icon: "square.and.arrow.up"),
        "clipboard": .init(token: "clipboard", tier: .install,
                           label: "Clipboard",
                           reason: "Copy text to your clipboard",
                           icon: "doc.on.clipboard"),
    ]

    static func spec(_ token: String) -> MiniAppCapabilitySpec? { specs[token.lowercased()] }

    /// True when a token needs no declaration/consent.
    static func isAuto(_ token: String) -> Bool { specs[token.lowercased()] == nil }

    /// Specs for the given tokens that should be disclosed at install
    /// (.install / .perUse), sorted perUse-first then alphabetically. Auto and
    /// unknown tokens are dropped.
    static func disclosable(_ tokens: Set<String>) -> [MiniAppCapabilitySpec] {
        tokens.compactMap { specs[$0.lowercased()] }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier == .perUse }
                return a.label < b.label
            }
    }
}
