// Full Lightning payment history, opened from the dashboard's "See all"
// (Phase 2b workstream I). Brings Lightning to parity with the other chains'
// transaction-list sheet (BitcoinTransactionListView etc.). Newest first,
// reusing the dashboard's LightningTxRow. Loads a bounded batch from LNDHub
// (no incremental pagination, matching every other chain's list view).

import SwiftUI

struct LightningTransactionListView: View {
    let account: LightningAccount
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var txs: [LightningTx] = []
    @State private var loading = false
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            List(txs) { tx in
                LightningTxRow(tx: tx)
            }
            .listStyle(.plain)
            .overlay {
                if loading, txs.isEmpty {
                    ProgressView()
                } else if let lastError, txs.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load history",
                        systemImage: "exclamationmark.triangle",
                        description: Text(lastError)
                    )
                } else if txs.isEmpty {
                    ContentUnavailableView(
                        "No payments yet",
                        systemImage: "tray",
                        description: Text("Send or receive over Lightning to see history here.")
                    )
                }
            }
            .refreshable { await load() }
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
        guard let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
            lastError = "Password missing for this account. Re-import it."
            return
        }
        loading = true
        lastError = nil
        defer { loading = false }
        let client = LNDHubClient(account: account, password: pw)
        do {
            // A larger batch than the dashboard's 20-row preview; LNDHub has no
            // cursor, so we fetch a generous bounded window (parity with the
            // other chains' single-batch list views).
            txs = try await client.history(limit: 200)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
