// Active Ethereum wallet view. Mirrors BitcoinWalletView's layout:
// wallet picker, big balance, action buttons (Send live in Phase 2
// for software wallets; Ledger SIGN_TRANSACTION lands in Phase 2.1),
// recent-tx list, manage-wallets entry under the + toolbar. Reads
// against the configured RPC + Etherscan-family API for this
// wallet's network.

import SwiftUI

struct EthereumWalletView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var balance: EthereumWeiValue?
    /// Token balances keyed by token.id, refreshed alongside the native
    /// balance. Drives the held-only token filter so curated defaults
    /// (USDC seeded on every chain) don't clutter the list at zero.
    @State private var tokenBalances: [String: EthereumWeiValue] = [:]
    @State private var recentTxs: [EthereumTx] = []
    @State private var recentTokenTxs: [EthereumTokenTransfer] = []
    @State private var syncing: Bool = false
    @State private var lastError: String?
    @State private var ethereum: EthereumWallet?
    @State private var showWallets = false
    @State private var showReceive = false
    @State private var showAllTxs = false
    @State private var showSend = false
    @State private var showAddToken = false
    @State private var showAddWallet = false
    @State private var showNetworkPicker = false
    @State private var detailToken: EthereumToken?

    private var activeWallet: EthereumWalletDescriptor? {
        store.ethereumWalletStore.activeWallet
    }

    /// Currently-selected EVM network for the active wallet. The
    /// same address signs on every EVM chain, so the user picks
    /// which chain to view (balance, history, tokens) via the
    /// network dropdown below the wallet picker. Resolves through
    /// the custom-network store + EthereumSettings overrides into
    /// a flat `ResolvedNetwork` value.
    private var activeNetwork: ResolvedNetwork {
        store.ethereumWalletStore.activeNetwork(
            customs: store.ethereumCustomNetworks,
            settings: store.ethereumSettings
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SandwichLockedBanner(visible: showsLockedBanner)
                    .environment(store)
                walletPicker
                accountRow
                networkPicker
                syncRow
                balanceCard
                actionButtons
                tokensSection
                recentList
                if let lastError {
                    Text(lastError).font(.callout).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .padding(.vertical, 16)
        }
        // Pull-down to re-sync. Standard iOS gesture; the
        // existing refresh logic mark-syncs the wallet and
        // updates balance, tx history, and token discovery.
        .refreshable { await refresh() }
        // Hide the system back button + swipe-back so an accidental
        // horizontal swipe inside the wallet view doesn't pop back
        // to the wallet list. The custom "Wallets" button on the
        // leading edge keeps explicit back-navigation available.
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Ethereum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                        Text("Wallets")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddWallet = true
                    } label: {
                        Label("Add wallet…", systemImage: "plus.circle")
                    }
                    Button {
                        showWallets = true
                    } label: {
                        Label("Manage wallets…", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Wallet actions")
            }
        }
        // Re-open + re-sync whenever the wallet OR the selected
        // network changes. The address is the same across networks
        // but balance/history/tokens are not.
        .task(id: refreshKey) { await openAndSync() }
        // Deleting the last wallet (from Manage wallets) leaves this
        // screen with no active wallet and nothing to show. Close the
        // manage sheet and pop back to the Wallets home instead of
        // stranding the user on an empty, non-functional Ethereum page.
        .onChange(of: store.ethereumWalletStore.wallets.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            showWallets = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
        }
        .sheet(isPresented: $showWallets) {
            EthereumWalletsView()
                .environment(store)
        }
        .sheet(isPresented: $showAddWallet) {
            AddEthereumWalletSheet()
                .environment(store)
        }
        .sheet(isPresented: $showReceive) {
            if let activeWallet, let addr = activeWallet.address {
                EthereumReceiveView(
                    address: addr,
                    network: activeNetwork,
                    walletLabel: activeWallet.label
                )
                .environment(store)
            }
        }
        .sheet(isPresented: $showAllTxs) {
            if let activeWallet, let _ = activeWallet.address, let ethereum {
                EthereumTransactionListView(wallet: ethereum)
                    .environment(store)
            }
        }
        .sheet(isPresented: $showSend) {
            if let ethereum {
                EthereumSendView(
                    wallet: ethereum,
                    onBroadcast: { _ in
                        Task { await refresh() }
                    }
                )
                .environment(store)
            }
        }
        .sheet(isPresented: $showAddToken) {
            if let ethereum, let builtin = activeBuiltinNetwork {
                EthereumAddTokenSheet(
                    wallet: ethereum,
                    network: builtin,
                    onAdded: {}
                )
                .environment(store)
            }
        }
        .sheet(item: $detailToken) { token in
            if let ethereum {
                EthereumTokenDetailView(wallet: ethereum, token: token)
                    .environment(store)
            }
        }
        .sheet(isPresented: $showNetworkPicker) {
            if let w = activeWallet {
                EthereumNetworkPickerSheet(walletId: w.id, selected: activeNetwork.networkID)
                    .environment(store)
            }
        }
    }

    /// Underlying built-in case for tokens / Add-token sheet,
    /// when the active network is a built-in catalog entry. nil
    /// for custom networks (tokens are gated to built-in chains).
    private var activeBuiltinNetwork: EthereumNetwork? {
        if case .builtin(let net) = activeNetwork.networkID { return net }
        return nil
    }

    /// Composite key so the `.task(id:)` modifier reruns when
    /// either the active wallet OR the selected network changes.
    private var refreshKey: String {
        let id = activeWallet?.id.uuidString ?? "no-wallet"
        return "\(id):\(activeNetwork.networkID.stableId)"
    }

    // MARK: -- tokens

    private var currentTokens: [EthereumToken] {
        // Only show tokens the wallet actually holds. Curated defaults
        // (USDC on every chain) otherwise sit in the list at zero balance.
        return store.ethereumTokenStore.tokens(on: activeNetwork)
            .filter { (tokenBalances[$0.id] ?? .zero) > .zero }
    }

    /// Native + ERC-20 transfers merged into one timestamp-sorted
    /// list. When the same tx hash appears in both feeds (an out-
    /// going ERC-20 transfer the user initiated produces a native
    /// row with value=0 and one or more token rows), we keep the
    /// token row because its amount is the useful one; the native
    /// row would just say "0 ETH" alongside.
    private var mergedTxItems: [EthereumTxItem] {
        let tokenHashes = Set(recentTokenTxs.map { $0.hash })
        var out: [EthereumTxItem] = []
        out.reserveCapacity(recentTxs.count + recentTokenTxs.count)
        for tx in recentTxs where !tokenHashes.contains(tx.hash) {
            out.append(.native(tx))
        }
        for transfer in recentTokenTxs {
            out.append(.token(transfer))
        }
        out.sort { $0.timestampSeconds > $1.timestampSeconds }
        return out
    }

    @ViewBuilder
    private var tokensSection: some View {
        if activeWallet != nil, activeNetwork.isBuiltin {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tokens").font(.headline)
                    Spacer()
                    Button {
                        showAddToken = true
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .accessibilityLabel("Add token")
                }
                if currentTokens.isEmpty {
                    emptyTokens
                } else {
                    ForEach(currentTokens) { token in
                        EthereumTokenRow(
                            token: token,
                            balance: tokenBalances[token.id],
                            onTap: { detailToken = token }
                        )
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = token.contractAddress
                            } label: {
                                Label("Copy contract address", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                store.ethereumTokenStore.remove(token)
                            } label: {
                                Label("Remove token", systemImage: "trash")
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyTokens: some View {
        VStack(spacing: 6) {
            Image(systemName: "diamond.tophalf.filled").font(.title2).foregroundStyle(.tertiary)
            Text("No tokens yet").foregroundStyle(.secondary).font(.callout)
            Text("Tap + to paste a contract address. The app reads the symbol and decimals from-chain.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: -- subviews

    private var walletPicker: some View {
        Menu {
            ForEach(store.ethereumWalletStore.wallets) { w in
                Button {
                    store.ethereumWalletStore.setActive(w.id)
                } label: {
                    Label(w.label, systemImage: w.id == activeWallet?.id ? "checkmark" : "")
                }
            }
            Divider()
            Button {
                showWallets = true
            } label: {
                Label("Manage wallets", systemImage: "list.bullet")
            }
        } label: {
            HStack {
                WalletThumbprint(
                    seed: activeWallet?.address ?? activeWallet?.id.uuidString ?? "no-wallet",
                    size: 36,
                    systemImage: "diamond.fill"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeWallet?.label ?? "No wallet").font(.headline)
                    Text(walletSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    /// Network selector below the wallet picker. The same address
    /// signs on every EVM chain, so this just swaps which RPC /
    /// explorer / token-catalog the wallet is talking to. Persists
    /// to `EthereumWalletStore.currentNetworkByWallet`.
    @ViewBuilder
    private var networkPicker: some View {
        if activeWallet != nil {
            Button {
                showNetworkPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(Color.indigo)
                    Text(activeNetwork.displayName)
                        .font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text("chain \(activeNetwork.chainId)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if activeNetwork.isTestnet {
                        Text("Testnet")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tertiary)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var walletSubtitle: String {
        guard let w = activeWallet else { return "—" }
        switch w.kind {
        case .software(let acct):  return "Software · Account \(acct)"
        case .hardware:            return "Hardware wallet"
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(displayBalance)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(activeNetwork.ticker)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let fiat = nativeFiatCaption {
                Text(fiat)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Account #N · short-address · copy" row immediately below
    /// the wallet picker. Was previously inside the balance card.
    @ViewBuilder
    private var accountRow: some View {
        if let addr = activeWallet?.address {
            AccountAddressBadge(
                accountIndex: activeAccountIndex,
                address: addr
            )
            .padding(.horizontal, 16)
        }
    }

    /// "Last sync … · refresh" row immediately below the network
    /// picker.
    private var syncRow: some View {
        HStack(spacing: 6) {
            if syncing {
                ProgressView().controlSize(.small)
                Text("Syncing…").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(lastSyncSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(syncing)
        }
        .padding(.horizontal, 16)
    }

    /// BIP44 account index for the active wallet, threaded into the
    /// shared `AccountAddressBadge`. Returns nil if no wallet is
    /// active.
    private var activeAccountIndex: UInt32? {
        guard let kind = activeWallet?.kind else { return nil }
        switch kind {
        case .software(let acct):       return acct
        case .hardware(_, let acct, _): return acct
        }
    }

    /// Show the locked banner when the sandwich is sealed AND the
    /// active wallet derives from the seed.
    private var showsLockedBanner: Bool {
        guard store.sandwich == nil, let kind = activeWallet?.kind else { return false }
        if case .software = kind { return true }
        return false
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton(
                "Send",
                systemImage: "arrow.up.right.circle.fill",
                enabled: canSend
            ) {
                showSend = true
            }
            actionButton("Receive", systemImage: "arrow.down.left.circle.fill", enabled: true) {
                showReceive = true
            }
            actionButton("Explorer", systemImage: "globe", enabled: activeWallet?.address != nil) {
                openExplorer()
            }
        }
        .padding(.horizontal, 16)
    }

    /// Software wallets can sign on device; hardware wallets show a
    /// disabled Send-on-Ledger state inside the sheet until Phase 2.1.
    private var canSend: Bool {
        guard let w = activeWallet, w.address != nil else { return false }
        return true
    }

    private func actionButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.indigo : Color.secondary)
        .disabled(!enabled)
    }

    private func openExplorer() {
        guard let w = activeWallet, let addr = w.address else { return }
        let base = activeNetwork.explorerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/address/\(addr)") else { return }
        UIApplication.shared.open(url)
    }

    private var pendingForActive: [PendingEthereumTx] {
        guard let id = activeWallet?.id else { return [] }
        return store.ethereumWalletStore.pendingTxsByWallet[id] ?? []
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transactions").font(.headline)
                Spacer()
                if !recentTxs.isEmpty {
                    Button("See all") { showAllTxs = true }.font(.callout)
                }
            }
            let pending = pendingForActive
            let items = mergedTxItems
            if pending.isEmpty && items.isEmpty {
                emptyTxs
            } else {
                ForEach(pending) { p in
                    PendingEthereumTxRow(
                        pending: p,
                        ticker: activeNetwork.ticker,
                        explorerBaseURL: activeNetwork.explorerURL
                    )
                    Divider()
                }
                ForEach(items.prefix(5)) { item in
                    switch item {
                    case .native(let tx):
                        EthereumTxRow(
                            tx: tx,
                            myAddress: activeWallet?.address ?? "",
                            ticker: activeNetwork.ticker,
                            explorerBaseURL: activeNetwork.explorerURL
                        )
                    case .token(let transfer):
                        EthereumTokenTxRow(
                            transfer: transfer,
                            myAddress: activeWallet?.address ?? "",
                            explorerBaseURL: activeNetwork.explorerURL
                        )
                    }
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyTxs: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
            Text("No transactions yet").foregroundStyle(.secondary).font(.callout)
            Text("Fund this wallet to see history here. \(emptyTxsExtraNote)")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyTxsExtraNote: String {
        return activeNetwork.explorerAPIURL == nil
            ? "This network does not expose an Etherscan-style API, so history is not fetched."
            : ""
    }

    // MARK: -- data flow

    private var displayBalance: String {
        guard let b = balance else { return "—" }
        return b.display(ticker: "", maxDecimals: 6).trimmingCharacters(in: .whitespaces)
    }

    /// Fiat caption shown under the balance — e.g. "≈ $1,234.56".
    /// nil when the user disabled fiat references, the network has
    /// no CoinGecko asset id (testnets), or no price is cached yet.
    private var nativeFiatCaption: String? {
        guard let b = balance,
              let asset = activeNetwork.coinGeckoAssetId
        else { return nil }
        let amount = b.ether  // 1 ETH = 1e18 wei; ether divides for us
        guard amount > 0 else { return nil }
        return store.assetPrices.fiatCaption(
            amount: amount,
            asset: asset,
            fiat: store.fiatPreferences.code
        )
    }

    private var lastSyncSummary: String {
        guard let last = activeWallet?.lastSyncAt else { return "Never synced" }
        return "Last sync \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))"
    }

    private func shorten(_ addr: String) -> String {
        if addr.count <= 12 { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    @MainActor
    private func openAndSync() async {
        guard let descriptor = activeWallet else { return }
        ethereum = EthereumWallet(descriptor: descriptor)
        // This runs only on a wallet/network switch (via .task(id: refreshKey)),
        // so clear the previous context's data before re-fetching. Otherwise a
        // failed/slow fetch on the new network leaves the old chain's balance and
        // transactions on screen (e.g. switching zkSync -> Ethereum still showing
        // zkSync txs). Manual refresh calls refresh() directly and won't clear.
        balance = nil
        recentTxs = []
        recentTokenTxs = []
        tokenBalances = [:]
        lastError = nil
        await refresh()
    }

    @MainActor
    /// Pull ERC-20 transfer events, cross-reference contracts
    /// against the reputable token list, auto-install any matches
    /// that the user does not already have. Silently best-effort
    /// (a failed Etherscan call doesn't surface to the user; the
    /// "+ Add custom token" path stays available).
    private func autoDiscoverTokens(
        from transfers: [EthereumTokenTransfer],
        network: ResolvedNetwork
    ) async {
        // Auto-discover only works against built-in catalog
        // entries because the reputable token list is keyed by
        // EthereumNetwork. Custom networks just skip silently.
        guard case .builtin(let builtin) = network.networkID else { return }
        let contracts = Set(transfers.map { $0.contractAddress.lowercased() })
        for contract in contracts {
            if store.ethereumTokenStore.find(network: builtin, contract: contract) != nil {
                continue
            }
            // Consult the remote registry first (fresh verified
            // tokens from Uniswap's list arrive here as soon as the
            // weekly refresh fires), then fall back to the curated
            // in-tree list so offline first launches still resolve
            // long-standing tokens like USDC + USDT.
            if let entry = store.ethereumTokenRegistry.find(network: builtin, contract: contract) {
                let token = EthereumToken(
                    network: builtin,
                    contractAddress: entry.contract,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: Int(entry.decimals),
                    curated: true
                )
                store.ethereumTokenStore.add(token)
            } else if let token = EthereumTokenCatalog.find(network: builtin, contract: contract) {
                store.ethereumTokenStore.add(token)
            }
        }
    }

    private func refresh() async {
        guard let ethereum, let descriptor = activeWallet else { return }
        let network = activeNetwork
        let rpcURL = network.rpcURL
        let explorerAPI = network.explorerAPIURL
        let apiKey = network.explorerAPIKey
        // Opportunistically refresh the verified-token catalog
        // alongside the dashboard sync. No-ops when the cache is
        // fresh (weekly TTL); explicit refresh-now lives in
        // Ethereum Settings.
        await store.ethereumTokenRegistry.refreshIfStale(
            catalogURL: store.ethereumSettings.tokenCatalogURL
        )
        syncing = true
        lastError = nil
        var partialErrors: [String] = []
        // Balance and tx-history are independent: a wallet with no
        // Etherscan API key still has a known balance from RPC, and
        // a wallet with a flaky RPC can still show prior history.
        // Mark synced when EITHER read returned data; keep stale
        // data on the other axis so the UI doesn't blank everything
        // because one of two endpoints hiccuped.
        do {
            balance = try await ethereum.balance(rpcURL: rpcURL)
            store.ethereumWalletStore.markSynced(id: descriptor.id)
        } catch {
            // A superseded fetch (switching wallet/network restarts the
            // .task and cancels this one) is not a failure: bail without
            // surfacing it, the new sync is already running.
            if isSupersededFetch(error) { syncing = false; return }
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            partialErrors.append("Balance: \(msg)")
        }
        do {
            recentTxs = try await ethereum.recentTransactions(
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                chainId: network.chainId,
                perPage: 25
            )
            store.ethereumWalletStore.markSynced(id: descriptor.id)
            // Evict any pending entries whose hash is now in the
            // confirmed feed (or older than 15 min — Eth can take
            // a while on busy chains).
            let confirmedHashes = Set(recentTxs.map { $0.hash })
            store.ethereumWalletStore.dropConfirmedPending(
                walletId: descriptor.id,
                confirmedTxHashes: confirmedHashes
            )
        } catch {
            if isSupersededFetch(error) { syncing = false; return }
            // History comes from free public block explorers that flake
            // often (HTML 404/502 pages, rate limits). It's supplementary:
            // keep whatever we already have and don't raise the balance
            // error banner over a transient explorer hiccup. Balance (the
            // load-bearing read, above) still surfaces real failures.
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            LogStore.shared.warn("eth.wallet", "history \(network.displayName): \(msg)")
        }
        // Fetch ERC-20 transfer events once and use them both to
        // populate the tx list (so incoming USDC etc. shows up) and
        // to drive token-catalog auto-discovery below.
        let tokenTransfers: [EthereumTokenTransfer]
        do {
            tokenTransfers = try await ethereum.recentTokenTransfers(
                explorerAPIURL: explorerAPI,
                apiKey: apiKey,
                chainId: network.chainId,
                perPage: 100
            )
            recentTokenTxs = tokenTransfers
        } catch {
            // Non-fatal: keep whatever we had on a transient
            // Etherscan blip.
            tokenTransfers = recentTokenTxs
        }
        await autoDiscoverTokens(from: tokenTransfers, network: network)
        // Refresh token balances last: auto-discover may have just added
        // tokens, and the list only shows entries with a positive balance.
        await refreshTokenBalances(network: network, rpcURL: rpcURL)
        if !partialErrors.isEmpty {
            lastError = partialErrors.joined(separator: "\n")
        }
        syncing = false
    }

    /// Fetch the balance of every token configured on `network` so the
    /// list can hide zero-balance entries. Best-effort: a token whose
    /// balance read fails is simply omitted (treated as zero) rather than
    /// surfacing an error, since balance/history above are the primary reads.
    @MainActor
    private func refreshTokenBalances(network: ResolvedNetwork, rpcURL: String) async {
        guard let ethereum else { return }
        var fresh: [String: EthereumWeiValue] = [:]
        for token in store.ethereumTokenStore.tokens(on: network) {
            if let bal = try? await ethereum.tokenBalance(token: token, rpcURL: rpcURL) {
                fresh[token.id] = bal
            }
        }
        tokenBalances = fresh
    }
}

// MARK: -- transaction row

struct EthereumTxRow: View {
    let tx: EthereumTx
    let myAddress: String
    let ticker: String
    let explorerBaseURL: String?

    /// When true, the timestamp slot displays the block number
    /// instead. Toggles on tap so the user can switch between
    /// "when did this happen" and "what block landed it" without
    /// leaving the wallet view.
    @State private var showBlockNumber = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showBlockNumber.toggle()
                } label: {
                    Text(showBlockNumber ? blockNumberString : dateString)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                Text(counterparty)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if tx.isError == "1" {
                    Text("Failed").font(.caption2).foregroundStyle(.red)
                } else {
                    Text("Confirmed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let url = explorerURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in block explorer")
            }
        }
        .padding(.vertical, 4)
    }

    private var blockNumberString: String {
        "Block \(tx.blockNumber)"
    }

    private var direction: TxDirection {
        let me = myAddress.lowercased()
        let from = tx.from.lowercased()
        let to = (tx.to ?? "").lowercased()
        if from == me && to == me { return .self }
        if from == me { return .out }
        if to == me { return .in }
        return .other
    }

    private enum TxDirection { case `in`, out, `self`, other }

    private var iconName: String {
        switch direction {
        case .in:     return "arrow.down.circle.fill"
        case .out:    return "arrow.up.circle.fill"
        case .self:   return "arrow.triangle.2.circlepath.circle.fill"
        case .other:  return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch direction {
        case .in:    return .green
        case .out:   return .orange
        case .self:  return .blue
        case .other: return .secondary
        }
    }

    private var amount: String {
        // value is wei as decimal string. Convert to ether for display.
        guard let wei = Decimal(string: tx.value), wei != 0 else { return "0 \(ticker)" }
        let divisor = pow(Decimal(10), 18)
        let ether = wei / divisor
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 6
        let sign = direction == .out ? "−" : (direction == .in ? "+" : "")
        return "\(sign)\(f.string(from: NSDecimalNumber(decimal: ether)) ?? "0") \(ticker)"
    }

    private var shortHash: String {
        let s = tx.hash
        if s.count <= 16 { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }

    private var counterparty: String {
        // A null `to` means contract creation (no recipient address).
        guard let to = tx.to, !to.isEmpty else { return "Contract creation" }
        switch direction {
        case .in:    return "From \(short(tx.from))"
        case .out:   return "To \(short(to))"
        case .self:  return "Self"
        case .other: return "\(short(tx.from)) → \(short(to))"
        }
    }

    private func short(_ addr: String) -> String {
        if addr.count <= 12 { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    private var dateString: String {
        guard let ts = TimeInterval(tx.timeStamp) else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private var explorerURL: URL? {
        guard let base = explorerBaseURL else { return nil }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/tx/\(tx.hash)")
    }
}

/// One ERC-20 transfer row. Same visual cadence as `EthereumTxRow`
/// but the amount is rendered with the token's own symbol and
/// decimals (so a USDC receive shows `+20 USDC`, not `+0 ETH`),
/// and the icon carries a small "token" badge so the user can tell
/// at a glance that this is a contract event, not a native transfer.
struct EthereumTokenTxRow: View {
    let transfer: EthereumTokenTransfer
    let myAddress: String
    let explorerBaseURL: String?

    @State private var showBlockNumber = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.title3)
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(.systemBackground)).frame(width: 12, height: 12))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showBlockNumber.toggle()
                } label: {
                    Text(showBlockNumber ? blockNumberString : dateString)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                Text(counterparty)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let url = explorerURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in block explorer")
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        transfer.tokenSymbol?.uppercased() ?? "TOKEN"
    }

    private var decimals: Int {
        Int(transfer.tokenDecimal ?? "") ?? 18
    }

    private enum TxDirection { case `in`, out, `self`, other }

    private var direction: TxDirection {
        let me = myAddress.lowercased()
        let from = transfer.from.lowercased()
        let to = transfer.to.lowercased()
        if from == me && to == me { return .self }
        if from == me { return .out }
        if to == me { return .in }
        return .other
    }

    private var iconName: String {
        switch direction {
        case .in:    return "arrow.down.circle.fill"
        case .out:   return "arrow.up.circle.fill"
        case .self:  return "arrow.triangle.2.circlepath.circle.fill"
        case .other: return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch direction {
        case .in:    return .green
        case .out:   return .orange
        case .self:  return .blue
        case .other: return .secondary
        }
    }

    private var amountString: String {
        guard let raw = Decimal(string: transfer.value), raw != 0 else { return "0" }
        let divisor = pow(Decimal(10), decimals)
        let scaled = raw / divisor
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 6
        let sign = direction == .out ? "−" : (direction == .in ? "+" : "")
        return "\(sign)\(f.string(from: NSDecimalNumber(decimal: scaled)) ?? "0")"
    }

    private var counterparty: String {
        switch direction {
        case .in:    return "From \(short(transfer.from))"
        case .out:   return "To \(short(transfer.to))"
        case .self:  return "Self"
        case .other: return "\(short(transfer.from)) → \(short(transfer.to))"
        }
    }

    private func short(_ addr: String) -> String {
        if addr.count <= 12 { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    private var blockNumberString: String {
        "Block \(transfer.blockNumber)"
    }

    private var dateString: String {
        guard let ts = TimeInterval(transfer.timeStamp) else { return "" }
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private var explorerURL: URL? {
        guard let base = explorerBaseURL else { return nil }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/tx/\(transfer.hash)")
    }
}

/// Optimistic-pending row for Ethereum. Mirrors `PendingTronTxRow`
/// and `PendingSolanaTxRow`: pulsing orange clock icon, relative
/// broadcast time, signed amount, "Pending" status, explorer link.
struct PendingEthereumTxRow: View {
    let pending: PendingEthereumTx
    let ticker: String
    let explorerBaseURL: String?
    @State private var pulse: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .opacity(pulse ? 0.55 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text("Broadcast \(pending.broadcastAt, style: .relative) ago")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text(shorten(pending.counterparty))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("Pending").font(.caption2).foregroundStyle(.orange)
            }
            if let url = explorerURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in block explorer")
            }
        }
        .padding(.vertical, 4)
        .onAppear { pulse = true }
    }

    private var amountString: String {
        if let symbol = pending.tokenSymbol, let decimals = pending.tokenDecimals {
            let raw = Decimal(string: pending.weiValue) ?? 0
            let factor = pow(Decimal(10), Int(decimals))
            let amt = raw / factor
            let sign = pending.direction == .out ? "−" : "+"
            return "\(sign)\(format(amt, maxFraction: Int(decimals))) \(symbol)"
        }
        guard let wei = Decimal(string: pending.weiValue), wei != 0 else { return "0 \(ticker)" }
        let divisor = pow(Decimal(10), 18)
        let ether = wei / divisor
        let sign = pending.direction == .out ? "−" : "+"
        return "\(sign)\(format(ether, maxFraction: 6)) \(ticker)"
    }

    private func format(_ d: Decimal, maxFraction: Int) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFraction
        return f.string(from: NSDecimalNumber(decimal: d)) ?? String(describing: d)
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    private var explorerURL: URL? {
        guard let base = explorerBaseURL else { return nil }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/tx/\(pending.txHash)")
    }
}
