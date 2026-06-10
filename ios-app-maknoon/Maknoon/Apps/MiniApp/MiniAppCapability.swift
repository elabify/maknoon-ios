// Single source of truth for mini-app capabilities: the things a dApp can
// ask the host to do. Each capability token (the same string a namespace
// handler declares as `requiredPermission`) has a consent tier, a
// human-facing label + reason, and an SF Symbol for the install/settings UI.
//
// Tiers:
//   .auto    — always available, low-risk; not declared, not shown, no consent
//              (storage, fiat, device, haptics, biometric gate).
//   .install — must be declared and SHOWN at install for the user to accept;
//              granted for the app's lifetime (addressBook, wallet read,
//              share, clipboard).
//   .perUse  — declared at install AND prompted natively every time it runs
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
                          label: "Verify identity",
                          reason: "Ask you to prove a verifiable credential",
                          icon: "person.text.rectangle"),
        "payment": .init(token: "payment", tier: .perUse,
                         label: "Payments & addresses",
                         reason: "Request payments and read your saved addresses",
                         icon: "creditcard"),
        "evm": .init(token: "evm", tier: .perUse,
                     label: "Ethereum wallet",
                     reason: "Connect and request signatures or transactions",
                     icon: "link"),
        "wallet": .init(token: "wallet", tier: .install,
                        label: "Wallet addresses",
                        reason: "See your wallet addresses",
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
