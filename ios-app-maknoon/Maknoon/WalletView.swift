// Wallet: digital assets, organised per network. Empty by default;
// the user taps the + toolbar button to pick a network (currently
// only Bitcoin is live) and add their first wallet on it.

import SwiftUI
import BitcoinDevKit

struct WalletView: View {
    @Environment(HolderStore.self) private var store
    @State private var showSettings = false
    @State private var showAddNetwork = false

    /// Networks that have at least one wallet. Each becomes a row in
    /// the Wallet tab. As Lightning / Tron ship they add their own
    /// counts the same way.
    private var hasBitcoinWallets: Bool {
        !store.bitcoinWalletStore.wallets.isEmpty
    }
    private var hasEthereumWallets: Bool {
        !store.ethereumWalletStore.wallets.isEmpty
    }
    private var hasLightningAccounts: Bool {
        !store.lightningAccountStore.accounts.isEmpty
    }
    private var hasSolanaWallets: Bool {
        !store.solanaWalletStore.wallets.isEmpty
    }
    private var hasTronWallets: Bool {
        !store.tronWalletStore.wallets.isEmpty
    }
    private var hasAnyWallets: Bool {
        hasBitcoinWallets || hasEthereumWallets || hasLightningAccounts
            || hasSolanaWallets || hasTronWallets
    }

    var body: some View {
        Form {
            if hasAnyWallets {
                if hasBitcoinWallets { bitcoinSection }
                if hasLightningAccounts { lightningSection }
                if hasEthereumWallets { ethereumSection }
                if hasSolanaWallets { solanaSection }
                if hasTronWallets { tronSection }
            } else {
                emptyStateSection
            }
        }
        .navigationTitle("Wallet")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddNetwork = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add network")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(store)
        }
        .sheet(isPresented: $showAddNetwork) {
            AddNetworkSheet().environment(store)
        }
    }

    // MARK: -- empty state

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "wallet.pass")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                Button {
                    showAddNetwork = true
                } label: {
                    // Spacer-padded HStack forces the icon + text to
                    // the horizontal center of the borderedProminent
                    // button. The naive `Label(...).frame(maxWidth:
                    // .infinity)` form leaves the content leading-
                    // aligned because Label's default content
                    // arrangement is leading-anchored within whatever
                    // size the frame expands it to.
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                        Text("Add Wallet")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: -- bitcoin

    private var bitcoinSection: some View {
        Section {
            NavigationLink {
                BitcoinWalletView()
                    .environment(store)
            } label: {
                bitcoinRow
            }
        } header: {
            Text("Bitcoin")
        }
    }

    private var bitcoinRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bitcoinsign.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeLabel).font(.callout.weight(.semibold))
                Text(activeSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: -- lightning

    private var lightningSection: some View {
        Section {
            NavigationLink {
                LightningWalletView()
                    .environment(store)
            } label: {
                lightningRow
            }
        } header: {
            Text("Bitcoin Lightning")
        }
    }

    private var lightningRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeLightningLabel).font(.callout.weight(.semibold))
                Text(activeLightningSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var activeLightningLabel: String {
        store.lightningAccountStore.activeAccount?.label ?? "Bitcoin Lightning"
    }

    private var activeLightningSubtitle: String {
        let n = store.lightningAccountStore.accounts.count
        return n == 1 ? "1 account" : "\(n) accounts"
    }

    // MARK: -- ethereum

    private var ethereumSection: some View {
        Section {
            NavigationLink {
                EthereumWalletView()
                    .environment(store)
            } label: {
                ethereumRow
            }
        } header: {
            Text("Ethereum")
        }
    }

    private var ethereumRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "diamond.fill")
                .font(.title2)
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeEthereumLabel).font(.callout.weight(.semibold))
                Text(activeEthereumSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var activeEthereumLabel: String {
        store.ethereumWalletStore.activeWallet?.label ?? "Ethereum"
    }

    private var activeEthereumSubtitle: String {
        guard store.ethereumWalletStore.activeWallet != nil else { return "—" }
        let net = store.ethereumWalletStore.activeNetwork(
            customs: store.ethereumCustomNetworks,
            settings: store.ethereumSettings
        )
        let n = store.ethereumWalletStore.wallets.count
        return "\(net.displayName) · \(n == 1 ? "1 wallet" : "\(n) wallets")"
    }

    // MARK: -- solana

    private var solanaSection: some View {
        Section {
            NavigationLink {
                SolanaWalletView()
                    .environment(store)
            } label: {
                solanaRow
            }
        } header: {
            Text("Solana")
        }
    }

    private var solanaRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeSolanaLabel).font(.callout.weight(.semibold))
                Text(activeSolanaSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: -- tron

    private var tronSection: some View {
        Section {
            NavigationLink {
                TronWalletView().environment(store)
            } label: {
                tronRow
            }
        } header: {
            Text("Tron")
        }
    }

    private var tronRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "diamond.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeTronLabel).font(.callout.weight(.semibold))
                Text(activeTronSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var activeTronLabel: String {
        store.tronWalletStore.activeWallet?.label ?? "Tron"
    }

    private var activeTronSubtitle: String {
        guard let w = store.tronWalletStore.activeWallet else { return "—" }
        let n = store.tronWalletStore.wallets.count
        let net = store.tronWalletStore.activeNetwork(for: w.id)
        return "\(net.displayName) - \(n == 1 ? "1 wallet" : "\(n) wallets")"
    }

    private var activeSolanaLabel: String {
        store.solanaWalletStore.activeWallet?.label ?? "Solana"
    }

    private var activeSolanaSubtitle: String {
        guard let w = store.solanaWalletStore.activeWallet else { return "—" }
        let n = store.solanaWalletStore.wallets.count
        let net = store.solanaWalletStore.activeNetwork(for: w.id)
        return "\(net.displayName) - \(n == 1 ? "1 wallet" : "\(n) wallets")"
    }

    private var activeLabel: String {
        store.bitcoinWalletStore.activeWallet?.label ?? "Bitcoin"
    }

    private var activeSubtitle: String {
        guard let w = store.bitcoinWalletStore.activeWallet else { return "—" }
        return "\(w.network.displayName) - \(walletCountLabel)"
    }

    private var walletCountLabel: String {
        let n = store.bitcoinWalletStore.wallets.count
        return n == 1 ? "1 wallet" : "\(n) wallets"
    }
}
