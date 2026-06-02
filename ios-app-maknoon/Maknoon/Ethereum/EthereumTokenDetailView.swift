// Token detail: big balance, Send button (live), Receive button
// (same EOA address as the parent wallet), explorer link to the
// contract page. Same address always works for any ERC-20 on the
// same chain so "Receive" piggybacks on the wallet's existing
// receive sheet.

import SwiftUI

struct EthereumTokenDetailView: View {
    let wallet: EthereumWallet
    let token: EthereumToken
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var balance: EthereumWeiValue?
    @State private var loading: Bool = true
    @State private var showSend: Bool = false
    @State private var showReceive: Bool = false

    private var address: String? {
        store.ethereumWalletStore.activeWallet?.address
    }

    private var rpcURL: String {
        store.ethereumSettings.rpcURL(for: token.network)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    balanceCard
                    actionRow
                    metaSection
                }
                .padding(.vertical, 16)
            }
            .navigationTitle(token.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: token.id) { await refresh() }
            .sheet(isPresented: $showSend) {
                EthereumSendView(
                    wallet: wallet,
                    token: token,
                    onBroadcast: { _ in
                        Task { await refresh() }
                    }
                )
                .environment(store)
            }
            .sheet(isPresented: $showReceive) {
                if let addr = address {
                    EthereumReceiveView(
                        address: addr,
                        network: store.ethereumWalletStore.resolve(
                            .builtin(token.network),
                            customs: store.ethereumCustomNetworks,
                            settings: store.ethereumSettings
                        ),
                        walletLabel: token.symbol
                    )
                    .environment(store)
                }
            }
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            if loading {
                ProgressView().controlSize(.large)
            } else {
                Text(balance?.displayUnits(ticker: "", decimals: token.decimals, maxDecimals: 6)
                        .trimmingCharacters(in: .whitespaces) ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(token.symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(token.name).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionButton("Send", systemImage: "arrow.up.right.circle.fill") {
                showSend = true
            }
            actionButton("Receive", systemImage: "arrow.down.left.circle.fill") {
                showReceive = true
            }
            if let url = contractExplorerURL {
                Link(destination: url) {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass").font(.title2)
                        Text("Contract")
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .frame(height: 28)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.indigo)
            }
        }
        .padding(.horizontal, 16)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.indigo)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("Network", token.network.displayName)
            metaRow("Symbol", token.symbol)
            metaRow("Decimals", "\(token.decimals)")
            metaRow("Contract", token.contractAddress, monospaced: true)
        }
        .padding(.horizontal, 16)
    }

    private func metaRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    private var contractExplorerURL: URL? {
        let base = store.ethereumSettings.explorerURL(for: token.network)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/address/\(token.contractAddress)")
    }

    @MainActor
    private func refresh() async {
        loading = true
        do {
            balance = try await wallet.tokenBalance(token: token, rpcURL: rpcURL)
        } catch {
            balance = nil
        }
        loading = false
    }
}
