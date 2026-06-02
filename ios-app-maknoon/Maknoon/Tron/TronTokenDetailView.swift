// TRC-20 token detail: big balance, Send button (pre-selects this
// token), Receive button (same T-address as the parent wallet),
// explorer link to the contract page, meta section. Mirrors
// EthereumTokenDetailView so the tap → details → send flow is the
// same across chains.

import SwiftUI

struct TronTokenDetailView: View {
    let walletId: UUID
    let token: TronTRC20Token
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var rawBalance: String?
    @State private var loading: Bool = true
    @State private var showSend: Bool = false
    @State private var showReceive: Bool = false

    private var descriptor: TronWalletDescriptor? {
        store.tronWalletStore.wallets.first(where: { $0.id == walletId })
    }

    private var activeNetwork: TronNetwork {
        store.tronWalletStore.activeNetwork(for: walletId)
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
                NavigationStack {
                    TronSendView(walletId: walletId, preselectTokenId: token.id)
                        .environment(store)
                }
            }
            .sheet(isPresented: $showReceive) {
                TronReceiveView(walletId: walletId)
                    .environment(store)
            }
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            if loading {
                ProgressView().controlSize(.large)
            } else {
                Text(rawBalance.map { token.format(rawAmountDecimal: $0) } ?? "—")
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
                .foregroundStyle(Color.red)
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
        .foregroundStyle(Color.red)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaRow("Network", activeNetwork.displayName)
            metaRow("Symbol", token.symbol)
            metaRow("Decimals", "\(token.decimals)")
            metaRow("Contract", token.contract, monospaced: true)
        }
        .padding(.horizontal, 16)
    }

    private func metaRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var contractExplorerURL: URL? {
        let base = store.tronSettings.explorerURL(for: activeNetwork)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // TronScan routes contracts under /#/contract/<address>.
        return URL(string: "\(base)/#/contract/\(token.contract)")
    }

    @MainActor
    private func refresh() async {
        loading = true
        defer { loading = false }
        guard let descriptor else { return }
        let rpcURL = store.tronSettings.rpcURL(for: activeNetwork)
        let wallet = TronWallet(
            descriptor: descriptor,
            network: activeNetwork,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        do {
            let holder = try await wallet.resolvedAddress(
                biometricReason: "Read \(token.symbol) balance"
            )
            rawBalance = try await TronTRC20TransferBuilder.balance(
                holderBase58: holder,
                contractBase58: token.contract,
                rpcURL: rpcURL
            )
        } catch {
            rawBalance = nil
        }
    }
}
