// Shared token-logo badge for every account-based wallet (Ethereum,
// Solana, Tron, future chains). Asynchronously loads a PNG from the
// configured logo registry (Trust Wallet by default), and falls back
// to a colour-tinted circle showing the first four characters of
// the token's symbol when the image isn't available.
//
// The caller passes the resolved URL (chain-specific helpers build
// it from the network's slug + the token's contract / mint). When
// `url == nil` we render the fallback immediately without firing a
// request, so chains that don't have a Trust Wallet folder (testnets,
// custom networks) stay quiet.

import SwiftUI

struct TokenLogoView: View {
    /// Fully-formed URL for the token's logo, or nil to skip the
    /// fetch entirely and render the monogram fallback.
    let url: URL?
    /// Token symbol used for the monogram fallback. First four
    /// characters render inside the colour circle.
    let symbol: String
    /// Chain-specific tint (Ethereum indigo, Solana purple, Tron
    /// red). Drives both the fallback circle fill and the text
    /// colour.
    let tint: Color
    /// Outer dimensions. Default matches existing token rows.
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    case .empty:
                        // While loading, show the fallback so the
                        // row is never blank even on slow networks.
                        // GitHub raw is usually ~50ms; this prevents
                        // a layout shift afterwards because the
                        // outer frame stays fixed.
                        fallback
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(tint.opacity(0.18))
            Text(monogram)
                .font(.system(size: size * 0.33, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(2)
        }
    }

    /// First four printable characters of the symbol, uppercased,
    /// stripped of whitespace. Empty symbols fall back to "TKN" so
    /// the circle is never blank.
    private var monogram: String {
        let cleaned = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if cleaned.isEmpty { return "TKN" }
        return String(cleaned.prefix(4))
    }
}
