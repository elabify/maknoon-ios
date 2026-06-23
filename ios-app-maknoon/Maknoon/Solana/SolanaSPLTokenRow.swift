// Dashboard row for one SPL token. Renders the symbol + name + the
// wallet's current balance (formatted via the mint's decimals), with
// a "Custom" badge for non-Jupiter sources so the user can see which
// rows came from the curated catalog versus their own additions.

import SwiftUI

struct SolanaSPLTokenRow: View {
    @Environment(HolderStore.self) private var store
    let token: SolanaSPLToken
    /// On-chain integer balance for this mint, refreshed by the
    /// dashboard's token-account walk. nil = not yet loaded.
    let rawBalance: UInt64?

    var body: some View {
        HStack(spacing: 12) {
            TokenLogoView(
                url: store.solanaSettings.tokenLogoURL(mint: token.mint),
                symbol: token.symbol,
                tint: .purple
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(token.symbol)
                        .font(.callout.weight(.semibold))
                    if token.source != .jupiter {
                        Text(token.source == .custom ? "Custom" : "On-chain")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                Text(token.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let raw = rawBalance {
                    Text(token.format(rawAmount: raw))
                        .font(.callout.monospacedDigit())
                } else {
                    Text("-")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Text(token.symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
