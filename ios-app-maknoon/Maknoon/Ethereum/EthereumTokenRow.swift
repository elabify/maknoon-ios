// A single ERC-20 token row inside the EthereumWalletView. The balance
// is fetched once at the wallet-view level (which also filters out
// zero-balance tokens) and passed in; tapping opens a dedicated token
// Send / Receive sheet pre-bound to this token.

import SwiftUI

struct EthereumTokenRow: View {
    @Environment(HolderStore.self) private var store
    let token: EthereumToken
    let balance: EthereumWeiValue?
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 12) {
                TokenLogoView(
                    url: store.ethereumSettings.tokenLogoURL(
                        network: token.network,
                        contract: token.contractAddress
                    ),
                    symbol: token.symbol,
                    tint: .indigo
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.symbol).font(.callout.weight(.semibold))
                    Text(token.name).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(balance?.displayUnits(ticker: "", decimals: token.decimals, maxDecimals: 4)
                        .trimmingCharacters(in: .whitespaces) ?? "-")
                    .font(.callout.monospaced())
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
