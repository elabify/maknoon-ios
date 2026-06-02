// Full transaction history for a Bitcoin wallet, modeled on Sparrow's
// Transactions tab. Newest first. Tap a row for tx details. Outgoing
// unconfirmed rows get a "Bump fee" trailing swipe action wired to
// the M2 RBF flow.

import SwiftUI
import BitcoinDevKit

struct BitcoinTransactionListView: View {
    let wallet: BitcoinWallet
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var txs: [CanonicalTx] = []
    @State private var netSats: [String: Int64] = [:]
    @State private var loading: Bool = false

    var body: some View {
        NavigationStack {
            List(Array(txs.enumerated()), id: \.offset) { _, tx in
                BitcoinTxRow(
                    tx: tx,
                    network: store.bitcoinWalletStore.activeWallet?.network ?? .mainnet,
                    explorerBaseURL: store.bitcoinSettings.explorerURL(
                        for: store.bitcoinWalletStore.activeWallet?.network ?? .mainnet
                    ),
                    netSat: netSats[String(describing: tx.transaction.computeTxid())],
                    wallet: wallet
                )
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if txs.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "tray",
                        description: Text("Fund this wallet to see history here.")
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
        txs = await wallet.transactions()
        var sats: [String: Int64] = [:]
        for tx in txs {
            let txid = String(describing: tx.transaction.computeTxid())
            sats[txid] = await wallet.netAmount(tx: tx.transaction)
        }
        netSats = sats
        loading = false
    }
}
