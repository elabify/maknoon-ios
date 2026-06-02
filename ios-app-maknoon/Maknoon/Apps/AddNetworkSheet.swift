// Tap the "+" on the Wallet tab and you get this sheet, which is the
// "Add Network" affordance. Each row is a live network the user can
// add a wallet on. Bitcoin is special: it leads the list and gets a
// subtle visual emphasis. The rest are alphabetical. Networks that
// aren't shipped yet aren't shown at all (no roadmap teasing); they
// appear here the day their wire is live.

import SwiftUI

struct AddNetworkSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pendingAction: PendingAction?

    enum PendingAction: Identifiable {
        case addBitcoinWallet
        case addEthereumWallet
        case addLightningAccount
        case addSolanaWallet
        case addTronWallet
        var id: String {
            switch self {
            case .addBitcoinWallet:    return "add-bitcoin-wallet"
            case .addEthereumWallet:   return "add-ethereum-wallet"
            case .addLightningAccount: return "add-lightning-account"
            case .addSolanaWallet:     return "add-solana-wallet"
            case .addTronWallet:       return "add-tron-wallet"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Bitcoin leads the list and is highlighted.
                    networkRow(
                        title: "Bitcoin",
                        subtitle: "Native SegWit (BIP84).",
                        systemImage: "bitcoinsign.circle.fill",
                        tint: .orange,
                        highlighted: true,
                        action: { pendingAction = .addBitcoinWallet }
                    )
                    // Then alphabetical: Bitcoin Lightning, Ethereum,
                    // Solana. Future networks slot into alphabetical
                    // order at the moment their wire ships.
                    networkRow(
                        title: "Bitcoin Lightning",
                        subtitle: "Custodial LNDHub-compatible accounts (manual configuration).",
                        systemImage: "bolt.fill",
                        tint: .yellow,
                        highlighted: false,
                        action: { pendingAction = .addLightningAccount }
                    )
                    networkRow(
                        title: "Ethereum",
                        subtitle: "Mainnet plus EVM-compatible layers.",
                        systemImage: "diamond.fill",
                        tint: .indigo,
                        highlighted: false,
                        action: { pendingAction = .addEthereumWallet }
                    )
                    networkRow(
                        title: "Solana",
                        subtitle: "Mainnet.",
                        systemImage: "circle.hexagongrid.fill",
                        tint: .purple,
                        highlighted: false,
                        action: { pendingAction = .addSolanaWallet }
                    )
                    networkRow(
                        title: "Tron",
                        subtitle: "Mainnet plus Shasta and Nile testnets. TRX and TRC-20 tokens.",
                        systemImage: "diamond.fill",
                        tint: .red,
                        highlighted: false,
                        action: { pendingAction = .addTronWallet }
                    )
                } header: {
                    Text("Networks")
                }
            }
            .navigationTitle("Add network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $pendingAction) { action in
                switch action {
                case .addBitcoinWallet:
                    AddBitcoinWalletSheet(onCreated: {
                        pendingAction = nil
                        dismiss()
                    })
                    .environment(store)
                case .addEthereumWallet:
                    AddEthereumWalletSheet(onCreated: {
                        pendingAction = nil
                        dismiss()
                    })
                    .environment(store)
                case .addLightningAccount:
                    AddLightningAccountSheet(onAdded: { _ in
                        pendingAction = nil
                        dismiss()
                    })
                    .environment(store)
                case .addSolanaWallet:
                    AddSolanaWalletSheet { _ in
                        pendingAction = nil
                        dismiss()
                    }
                    .environment(store)
                case .addTronWallet:
                    AddTronWalletSheet { _ in
                        pendingAction = nil
                        dismiss()
                    }
                    .environment(store)
                }
            }
        }
    }

    private func networkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(highlighted ? .title2 : .title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(highlighted
                              ? .callout.weight(.bold)
                              : .callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(highlighted ? tint.opacity(0.08) : nil)
    }
}
