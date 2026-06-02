// Full transaction history. Reused row layout from
// `EthereumWalletView` so look matches the overview list.

import SwiftUI

struct EthereumTransactionListView: View {
    let wallet: EthereumWallet
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var txs: [EthereumTx] = []
    @State private var tokenTxs: [EthereumTokenTransfer] = []
    @State private var loading: Bool = false
    @State private var lastError: String?

    private var activeNetwork: ResolvedNetwork {
        store.ethereumWalletStore.activeNetwork(
            customs: store.ethereumCustomNetworks,
            settings: store.ethereumSettings
        )
    }

    private var displayItems: [EthereumTxItem] {
        let tokenHashes = Set(tokenTxs.map { $0.hash })
        var out: [EthereumTxItem] = []
        for tx in txs where !tokenHashes.contains(tx.hash) {
            out.append(.native(tx))
        }
        for t in tokenTxs { out.append(.token(t)) }
        out.sort { $0.timestampSeconds > $1.timestampSeconds }
        return out
    }

    var body: some View {
        NavigationStack {
            List(displayItems) { item in
                switch item {
                case .native(let tx):
                    EthereumTxRow(
                        tx: tx,
                        myAddress: store.ethereumWalletStore.activeWallet?.address ?? "",
                        ticker: activeNetwork.ticker,
                        explorerBaseURL: activeNetwork.explorerURL
                    )
                case .token(let transfer):
                    EthereumTokenTxRow(
                        transfer: transfer,
                        myAddress: store.ethereumWalletStore.activeWallet?.address ?? "",
                        explorerBaseURL: activeNetwork.explorerURL
                    )
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if displayItems.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "tray",
                        description: Text(lastError ?? "Fund this wallet to see history here.")
                    )
                }
            }
            .task { await load() }
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        lastError = nil
        defer { loading = false }
        guard store.ethereumWalletStore.activeWallet != nil else { return }
        let explorerAPI = activeNetwork.explorerAPIURL
        let apiKey = activeNetwork.explorerAPIKey
        do {
            async let native = wallet.recentTransactions(
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                chainId: activeNetwork.chainId,
                perPage: 100
            )
            async let tokens = wallet.recentTokenTransfers(
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                chainId: activeNetwork.chainId,
                perPage: 100
            )
            // Tolerate either feed failing on its own; keep the
            // other if one breaks.
            do { txs = try await native } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            do { tokenTxs = try await tokens } catch {
                if lastError == nil {
                    lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }
}
