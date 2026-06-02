// Deterministic per-wallet "thumbprint" icon. Hashes the wallet's
// stable identifier (xpub for Bitcoin, account-derived address for
// Ethereum/Tron later) and renders a small rounded badge with a
// two-tone gradient + a 3x3 dot pattern derived from the hash. The
// result is visually distinct per wallet without leaking the xpub
// itself.

import SwiftUI
import CommonCrypto

struct WalletThumbprint: View {
    /// The deterministic seed used to colour the badge. For Bitcoin
    /// this is the xpub; for Ethereum / Tron later this will be the
    /// account public key or address. Anything stable per wallet
    /// works as long as we don't change it on the user.
    let seed: String

    /// Size in points of the rendered badge (default ~32 to match
    /// the existing wallet-row glyph slot).
    var size: CGFloat = 32

    /// SF Symbol drawn on top of the gradient so the user still has
    /// a chain hint at a glance (bitcoinsign.circle.fill,
    /// diamond.fill for Ethereum, …).
    var systemImage: String? = nil

    var body: some View {
        let hash = WalletThumbprint.sha256(of: seed)
        let g = WalletThumbprint.gradient(from: hash)
        let pattern = WalletThumbprint.pattern(from: hash)

        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(g)
            // 3x3 dot pattern overlay; cells lit per bit-pattern
            // are translucent white so the gradient still shows.
            GeometryReader { geo in
                let cell = geo.size.width / 4
                ForEach(0..<9, id: \.self) { idx in
                    let row = idx / 3
                    let col = idx % 3
                    if pattern[idx] {
                        Circle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: cell * 0.55, height: cell * 0.55)
                            .position(
                                x: cell * (CGFloat(col) + 1) + cell * 0.5,
                                y: cell * (CGFloat(row) + 1) + cell * 0.5
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))

            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: -- helpers

    private static func sha256(of s: String) -> [UInt8] {
        let data = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }

    private static func gradient(from hash: [UInt8]) -> LinearGradient {
        // Hue 1 from first byte, hue 2 from second byte. Force
        // saturation + brightness high so the badge reads clearly
        // against the dark app background.
        let h1 = Double(hash[0]) / 255.0
        let h2 = Double(hash[1]) / 255.0
        let c1 = Color(hue: h1, saturation: 0.7, brightness: 0.65)
        let c2 = Color(hue: h2, saturation: 0.8, brightness: 0.85)
        // Diagonal direction also varies by hash so two wallets
        // with similar hues don't look identical.
        let angleFromHash = Double(hash[2]) / 255.0  // 0..1
        let radians = angleFromHash * 2 * .pi
        let dx = CGFloat(cos(radians))
        let dy = CGFloat(sin(radians))
        return LinearGradient(
            colors: [c1, c2],
            startPoint: UnitPoint(x: 0.5 - dx * 0.5, y: 0.5 - dy * 0.5),
            endPoint:   UnitPoint(x: 0.5 + dx * 0.5, y: 0.5 + dy * 0.5)
        )
    }

    /// 9-bit pattern (3x3 grid of "lit" / "unlit" dots) from bytes
    /// 3-4 of the hash.
    private static func pattern(from hash: [UInt8]) -> [Bool] {
        let bits = (UInt16(hash[3]) << 8) | UInt16(hash[4])
        var out: [Bool] = []
        out.reserveCapacity(9)
        for i in 0..<9 {
            out.append((bits >> i) & 1 == 1)
        }
        return out
    }
}

#Preview {
    HStack(spacing: 12) {
        WalletThumbprint(seed: "xpub-sample-1", size: 40, systemImage: "bitcoinsign.circle.fill")
        WalletThumbprint(seed: "xpub-sample-2", size: 40, systemImage: "bitcoinsign.circle.fill")
        WalletThumbprint(seed: "xpub-sample-3", size: 40, systemImage: "diamond.fill")
        WalletThumbprint(seed: "0xa1b2c3", size: 40, systemImage: "hexagon.fill")
    }
    .padding()
    .background(Color.black)
}
