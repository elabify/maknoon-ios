// Brand marks for the chains a passport credential is pinned (anchored) on.
// Maps a CAIP-2 chain id to a brand logo (the same ChainXxx imageset the wallet
// dashboards use) + a testnet flag, plus a small chip used on the passport
// card's pinned-network strip. The holder-pinned primary chip gets a gold ring;
// testnets (today: Sepolia) carry a small, centered red "TEST" caption.

import SwiftUI

struct ChainMark {
    let name: String
    /// Asset-catalog imageset for the brand logo (e.g. "ChainEthereum"). nil
    /// falls back to the glyph + colour.
    let assetName: String?
    let glyph: String
    let color: Color
    let isTestnet: Bool
    /// Short red caption shown under a testnet chip (e.g. "Sepolia", "Devnet").
    var testnetLabel: String = "TEST"

    /// Chains shown to end users. Testnets (Sepolia eip155:11155111, Base Sepolia
    /// eip155:84532, anvil, devnets) are anchored for testing but never rendered
    /// in the clients — they are admin-only in the issuer console (ADR-0040).
    /// An explicit production allowlist, not a testnet heuristic (CAIP-2 84532
    /// has no "sepolia" substring to match on).
    static let productionChains: Set<String> = ["eip155:1", "eip155:8453"]

    /// True for chains the clients display by default. Drives the anchor filter
    /// so testnet pins are hidden unless the holder opts in (Settings, Identity,
    /// Advanced, "Show testnet anchors").
    static func isProduction(_ caip2: String) -> Bool {
        productionChains.contains(caip2.lowercased())
    }

    /// True for testnet / dev chains (Sepolia, Base Sepolia, Solana devnet, anvil).
    static func isTestnet(_ caip2: String) -> Bool {
        forCAIP2(caip2).isTestnet
    }

    static func forCAIP2(_ caip2: String) -> ChainMark {
        let id = caip2.lowercased()
        switch true {
        case id == "eip155:1":
            return ChainMark(name: "Ethereum", assetName: "ChainEthereum", glyph: "Ξ", color: Color(hex: 0x627eea), isTestnet: false)
        case id == "eip155:11155111":
            return ChainMark(name: "Ethereum Sepolia", assetName: "ChainEthereum", glyph: "Ξ", color: Color(hex: 0x627eea), isTestnet: true, testnetLabel: "Sepolia")
        case id == "eip155:8453":
            return ChainMark(name: "Base", assetName: "ChainBase", glyph: "B", color: Color(hex: 0x0052ff), isTestnet: false)
        case id == "eip155:84532":
            return ChainMark(name: "Base Sepolia", assetName: "ChainBase", glyph: "B", color: Color(hex: 0x0052ff), isTestnet: true, testnetLabel: "Sepolia")
        case id == "eip155:42161":
            return ChainMark(name: "Arbitrum", assetName: nil, glyph: "A", color: Color(hex: 0x28a0f0), isTestnet: false)
        case id == "eip155:137":
            return ChainMark(name: "Polygon", assetName: nil, glyph: "P", color: Color(hex: 0x8247e5), isTestnet: false)
        case id.hasPrefix("eip155:"):
            return ChainMark(name: "EVM", assetName: "ChainEthereum", glyph: "Ξ", color: Color(hex: 0x627eea), isTestnet: false)
        case id.hasPrefix("solana:"):
            let test = id.contains("devnet") || id.contains("testnet")
            return ChainMark(name: "Solana", assetName: "ChainSolana", glyph: "◎", color: Color(hex: 0x9945ff), isTestnet: test, testnetLabel: "Devnet")
        case id.hasPrefix("bip122:"), id.contains("bitcoin"):
            return ChainMark(name: "Bitcoin", assetName: "ChainBitcoin", glyph: "₿", color: Color(hex: 0xf7931a), isTestnet: false)
        case id.hasPrefix("tron:"), id.contains("tron"):
            return ChainMark(name: "Tron", assetName: "ChainTron", glyph: "T", color: Color(hex: 0xef0027), isTestnet: false)
        default:
            return ChainMark(name: caip2, assetName: nil, glyph: "⛓", color: Color(hex: 0x64748b), isTestnet: false)
        }
    }

    /// Block-explorer URL for a contract/registry ADDRESS on a given CAIP-2 chain.
    /// nil for chains without a contract-address explorer (e.g. bitcoin).
    static func explorerAddressURL(chain caip2: String, address: String) -> URL? {
        let id = caip2.lowercased()
        let base: String?
        switch true {
        case id == "eip155:1":         base = "https://etherscan.io/address/"
        case id == "eip155:11155111":  base = "https://sepolia.etherscan.io/address/"
        case id == "eip155:8453":      base = "https://basescan.org/address/"
        case id == "eip155:84532":     base = "https://sepolia.basescan.org/address/"
        case id == "eip155:42161":     base = "https://arbiscan.io/address/"
        case id == "eip155:137":       base = "https://polygonscan.com/address/"
        case id.hasPrefix("solana:"):  base = "https://explorer.solana.com/address/"
        case id.hasPrefix("tron:"), id.contains("tron"): base = "https://tronscan.org/#/contract/"
        default:                       base = nil
        }
        guard let base else { return nil }
        var s = base + address
        if id.hasPrefix("solana:") && (id.contains("devnet") || id.contains("testnet")) { s += "?cluster=devnet" }
        return URL(string: s)
    }
}

/// A round brand-logo chip. `pinned` adds a gold ring (the holder-pinned
/// primary). Testnets carry a small, centered red "TEST" caption below.
struct ChainMarkChip: View {
    let mark: ChainMark
    var pinned: Bool = false
    var size: CGFloat = 26

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let asset = mark.assetName {
                    // Brand logo (e.g. the diamond Ethereum mark) on a white
                    // disc so it stays legible on the navy card.
                    Circle().fill(Color.white)
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.16)
                } else {
                    Circle().fill(mark.color)
                    Text(mark.glyph)
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(
                    pinned ? Color(hex: 0xf5c542) : Color.white.opacity(0.25),
                    lineWidth: pinned ? 2 : 1
                )
            )
            if mark.isTestnet {
                // A clearly-visible red pill naming the testnet (e.g. "Sepolia"),
                // so a testnet anchor never reads as production trust.
                Text(mark.testnetLabel)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color(hex: 0xe5484d), in: Capsule())
                    .fixedSize()
            }
        }
        .frame(width: max(size + 8, mark.isTestnet ? 44 : size + 8))
        .accessibilityLabel(mark.isTestnet ? "\(mark.name) testnet" : mark.name)
    }
}
