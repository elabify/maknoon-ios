// Dashboard row for one installed TRC-20 token. Mirrors
// `SolanaSPLTokenRow`: monogram badge, symbol + name on the left,
// formatted balance on the right, "Custom" capsule when the entry
// came from the user rather than the catalog.

import SwiftUI

struct TronTRC20TokenRow: View {
    @Environment(HolderStore.self) private var store
    let token: TronTRC20Token
    /// On-chain raw amount as a base-10 string (TRC-20 amounts can
    /// exceed UInt64 so we store as String everywhere). nil = not
    /// yet fetched.
    let rawBalance: String?

    var body: some View {
        HStack(spacing: 12) {
            TokenLogoView(
                url: store.tronSettings.tokenLogoURL(contract: token.contract),
                symbol: token.symbol,
                tint: .red
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(token.symbol)
                        .font(.callout.weight(.semibold))
                    if token.source == .custom {
                        Text("Custom")
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
                    Text(token.format(rawAmountDecimal: raw))
                        .font(.callout.monospacedDigit())
                } else {
                    Text("—").font(.callout).foregroundStyle(.tertiary)
                }
                Text(token.symbol).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
