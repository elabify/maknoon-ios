// Tron dashboard. Same shape as SolanaWalletView so the two chains
// feel identical to the user: ScrollView/VStack with card-style
// sections, wallet picker chip, network dropdown chip, balance card
// with fiat caption + last-sync row, Send / Receive / Explorer
// action row, tokens section, recent transactions list.

import SwiftUI
import UIKit

struct TronWalletView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sun: Int64?
    @State private var address: String?
    @State private var recent: [TronRPCClient.TxRecord] = []
    @State private var tokenBalances: [String: String] = [:]
    @State private var lastSyncAt: Date?
    @State private var syncing: Bool = false
    @State private var lastError: String?
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showWallets = false
    @State private var showAddWallet = false
    @State private var showAddToken = false
    @State private var unknownContractToAdd: String?
    @State private var showAllTxs: Bool = false
    @State private var detailToken: TronTRC20Token?

    private var activeWallet: TronWalletDescriptor? {
        store.tronWalletStore.activeWallet
    }

    private var activeNetwork: TronNetwork {
        guard let id = activeWallet?.id else { return .mainnet }
        return store.tronWalletStore.activeNetwork(for: id)
    }

    /// Show the locked banner when the sandwich is sealed AND the
    /// active wallet derives from the seed. Mirrors the same rule
    /// every other account-based chain uses.
    private var showsLockedBanner: Bool {
        guard store.sandwich == nil, let kind = activeWallet?.kind else { return false }
        if case .software = kind { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SandwichLockedBanner(visible: showsLockedBanner)
                    .environment(store)
                walletPicker
                if activeWallet != nil {
                    accountRow
                    networkPicker
                    syncRow
                    balanceCard
                    actionButtons
                    tokensSection
                    unknownTokensBanner
                    recentList
                }
                if let lastError {
                    Text(lastError).font(.callout).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .padding(.vertical, 16)
        }
        .sheet(isPresented: $showAllTxs) {
            if let activeWallet, let addr = address {
                let rpcURL = store.tronSettings.rpcURL(for: activeNetwork)
                let wallet = TronWallet(
                    descriptor: activeWallet,
                    network: activeNetwork,
                    rpcURL: rpcURL,
                    sandwich: store.sandwich
                )
                TronTransactionListView(
                    wallet: wallet,
                    ownerAddress: addr,
                    network: activeNetwork
                )
                .environment(store)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Tron")
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
        .refreshable { await refresh() }
        .task(id: activeWallet?.id) { await refresh() }
        // Deleting the last wallet (from Manage wallets) leaves this
        // screen with no active wallet and nothing to show. Close the
        // manage sheet and pop back to the Wallets home instead of
        // stranding the user on an empty, non-functional Tron page.
        .onChange(of: store.tronWalletStore.wallets.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            showWallets = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 60, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }
                    if dx < -80, address != nil { showSend = true }
                    else if dx > 80 { showReceive = true }
                }
        )
        .sheet(isPresented: $showSend) {
            if let id = activeWallet?.id {
                NavigationStack {
                    TronSendView(walletId: id).environment(store)
                }
            }
        }
        .sheet(isPresented: $showReceive) {
            if let id = activeWallet?.id {
                NavigationStack {
                    TronReceiveView(walletId: id).environment(store)
                }
            }
        }
        .sheet(isPresented: $showWallets) {
            NavigationStack {
                TronWalletsView().environment(store)
            }
        }
        .sheet(isPresented: $showAddWallet) {
            AddTronWalletSheet { _ in showAddWallet = false }
                .environment(store)
        }
        .sheet(isPresented: $showAddToken) {
            TronAddTokenSheet(
                network: activeNetwork,
                prefilledContract: unknownContractToAdd
            ) {
                unknownContractToAdd = nil
                Task { await refresh() }
            }
            .environment(store)
        }
        .sheet(item: $detailToken) { token in
            if let id = activeWallet?.id {
                TronTokenDetailView(walletId: id, token: token)
                    .environment(store)
            }
        }
    }

    // MARK: -- sections

    @ViewBuilder
    private var walletPicker: some View {
        if let w = activeWallet {
            Menu {
                ForEach(store.tronWalletStore.wallets) { row in
                    Button {
                        store.tronWalletStore.setActive(row.id)
                        Task { await refresh() }
                    } label: {
                        Label(row.label, systemImage: row.id == w.id ? "checkmark" : "")
                    }
                }
                Divider()
                Button { showWallets = true } label: {
                    Label("Manage wallets", systemImage: "list.bullet")
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.16))
                        Image(systemName: "diamond.fill")
                            .foregroundStyle(Color.red)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.label).font(.headline)
                        Text(walletSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
            .foregroundStyle(.primary)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "diamond")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Button {
                    showAddWallet = true
                } label: {
                    Label("Add a Tron wallet", systemImage: "plus.circle.fill")
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var walletSubtitle: String {
        guard let w = activeWallet else { return "—" }
        switch w.kind {
        case .software(let a):           return "Software · Account \(a)"
        case .hardware(_, let a, _):     return "Hardware · Account \(a)"
        }
    }

    @ViewBuilder
    private var networkPicker: some View {
        if let w = activeWallet {
            Menu {
                ForEach(TronNetwork.allCases, id: \.self) { n in
                    Button {
                        store.tronWalletStore.setActiveNetwork(walletId: w.id, network: n)
                        sun = nil
                        recent = []
                        tokenBalances = [:]
                        Task { await refresh() }
                    } label: {
                        Label(n.displayName, systemImage: activeNetwork == n ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(Color.red)
                    Text(activeNetwork.displayName).font(.callout.weight(.medium))
                    if activeNetwork != .mainnet {
                        Text("Testnet")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
            }
            .foregroundStyle(.primary)
        }
    }

    /// "Account #N · short-address · copy" row. Sits immediately
    /// below the wallet picker so the user sees what address they're
    /// about to act on before scrolling further. Was previously
    /// stuffed inside the balance card.
    @ViewBuilder
    private var accountRow: some View {
        if let addr = address {
            AccountAddressBadge(
                accountIndex: activeAccountIndex,
                address: addr
            )
            .padding(.horizontal, 16)
        }
    }

    /// "Last sync … · refresh" row. Sits directly below the network
    /// picker so the user can see freshness next to their network
    /// selection.
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

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(balanceDisplay)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("TRX")
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

    private var activeAccountIndex: UInt32? {
        guard let kind = activeWallet?.kind else { return nil }
        switch kind {
        case .software(let a):           return a
        case .hardware(_, let a, _):     return a
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton("Send", systemImage: "arrow.up.right.circle.fill", enabled: address != nil) {
                showSend = true
            }
            actionButton("Receive", systemImage: "arrow.down.left.circle.fill", enabled: true) {
                showReceive = true
            }
            actionButton("Explorer", systemImage: "globe", enabled: address != nil) {
                openExplorer()
            }
        }
        .padding(.horizontal, 16)
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
        .foregroundStyle(enabled ? Color.red : Color.secondary)
        .disabled(!enabled)
    }

    private func openExplorer() {
        guard let addr = address else { return }
        let base = store.tronSettings.explorerURL(for: activeNetwork)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/#/address/\(addr)") else { return }
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private var tokensSection: some View {
        let tokens = store.tronTRC20TokenStore.tokens(on: activeNetwork)
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
            if tokens.isEmpty {
                Text("No TRC-20 tokens yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ForEach(tokens) { token in
                    Button {
                        detailToken = token
                    } label: {
                        HStack {
                            TronTRC20TokenRow(
                                token: token,
                                rawBalance: tokenBalances[token.contract]
                            )
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = token.contract
                        } label: {
                            Label("Copy contract address", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            store.tronTRC20TokenStore.remove(token)
                        } label: {
                            Label("Remove token", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var unknownTokensBanner: some View {
        let unknown = store.tronTRC20TokenStore.unknownContracts(on: activeNetwork)
        if !unknown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Unknown tokens detected")
                        .font(.subheadline.weight(.semibold))
                }
                Text("These contracts aren't in the verified catalog. They could be legitimate tokens not yet listed, or airdrop spam. Add only after verifying the contract against a trusted source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(unknown, id: \.self) { contract in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contract)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button("Add as custom…") {
                                unknownContractToAdd = contract
                                showAddToken = true
                            }
                            .font(.caption)
                            Button("Ignore") {
                                store.tronTRC20TokenStore.dismissUnknown(contract, on: activeNetwork)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private var pendingForActive: [PendingTronTx] {
        guard let id = activeWallet?.id else { return [] }
        return store.tronWalletStore.pendingTxsByWallet[id] ?? []
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transactions").font(.headline)
                Spacer()
                if !recent.isEmpty {
                    Button("See all") { showAllTxs = true }.font(.callout)
                }
            }
            let pending = pendingForActive
            if pending.isEmpty && recent.isEmpty {
                emptyTxs
            } else {
                let explorerBase = store.tronSettings.explorerURL(for: activeNetwork)
                ForEach(pending) { p in
                    PendingTronTxRow(pending: p, explorerBaseURL: explorerBase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                let ownerAddr = address ?? ""
                ForEach(recent.prefix(5)) { rec in
                    TronTxRow(
                        tx: rec,
                        ownerAddress: ownerAddr,
                        explorerBaseURL: explorerBase,
                        network: activeNetwork
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyTxs: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
            Text(syncing ? "Loading…" : "No transactions yet")
                .foregroundStyle(.secondary).font(.callout)
            Text("Fund this wallet to see history here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // Row layout lives in TronTxRow inside TronTransactionListView.swift
    // for reuse across the dashboard preview and the full list page.

    // MARK: -- display helpers

    private var balanceDisplay: String {
        guard let s = sun else { return "—" }
        let trx = Double(s) / 1_000_000.0
        return String(format: "%.6f", trx)
    }

    private var nativeFiatCaption: String? {
        guard let s = sun,
              let asset = activeNetwork.coinGeckoAssetId,
              s > 0
        else { return nil }
        let trx = Decimal(s) / Decimal(1_000_000)
        return store.assetPrices.fiatCaption(
            amount: trx,
            asset: asset,
            fiat: store.fiatPreferences.code
        )
    }

    private var lastSyncSummary: String {
        if let last = lastSyncAt ?? activeWallet?.lastSyncAt {
            return "Last sync \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))"
        }
        return "Never synced"
    }

    // MARK: -- refresh

    @MainActor
    private func refresh() async {
        guard let descriptor = activeWallet, let sandwich = store.sandwich else { return }
        syncing = true
        defer { syncing = false }
        let net = activeNetwork
        let rpcURL = store.tronSettings.rpcURL(for: net)
        let wallet = TronWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: sandwich
        )
        // Opportunistically refresh the verified-token catalog; the
        // call no-ops if the cache is still fresh.
        await store.tronTokenCatalog.refreshIfStale(
            catalogURL: store.tronSettings.tokenCatalogURL
        )
        do {
            let a = try await wallet.resolvedAddress(biometricReason: "Sync \(descriptor.label)")
            self.address = a
            // Push the resolved address into the address-book mirror
            // for cross-wallet "send to my own" flows.
            store.tronWalletStore.updateMirrorAddress(walletId: descriptor.id, address: a)
            self.sun = try await wallet.refreshBalance(biometricReason: "Sync \(descriptor.label)")
            self.recent = (try? await wallet.recentTransactions(limit: 10, biometricReason: "Sync \(descriptor.label)")) ?? []
            self.lastSyncAt = Date()
            store.tronWalletStore.markSynced(id: descriptor.id, at: Date())
            // Drop any pending entries whose tx has now been observed
            // confirmed in the canonical feed; also evicts pendings
            // older than 3 minutes (presumed orphaned).
            let confirmedIds = Set(recent.map { $0.txID })
            store.tronWalletStore.dropConfirmedPending(
                walletId: descriptor.id,
                confirmedTxIDs: confirmedIds
            )

            // Auto-discover held TRC-20s via TronScan's account API
            // (mainnet only; testnet has no equivalent). The TronGrid
            // RPC doesn't expose a "list all TRC-20 holdings" call,
            // so we lean on the explorer's index for discovery and
            // then probe per-contract balanceOf to keep the on-chain
            // truth as the displayed balance.
            if net == .mainnet {
                let held = (try? await TronScanAPI.discoverHeldTRC20(addressBase58: a)) ?? []
                store.tronTRC20TokenStore.reconcile(
                    heldContracts: held.map { $0.contract },
                    on: net,
                    catalog: store.tronTokenCatalog
                )
            }
            let installed = store.tronTRC20TokenStore.tokens(on: net)
            var balances: [String: String] = [:]
            for token in installed {
                if let raw = try? await probeTRC20Balance(
                    holder: a,
                    contract: token.contract,
                    rpcURL: rpcURL
                ) {
                    balances[token.contract] = raw
                }
            }
            self.tokenBalances = balances
        } catch is CancellationError {
            // Pull-to-refresh fired before a previous sync finished,
            // or the user chip-flipped mid-flight, or the view
            // dismissed. None of these are errors the user needs to
            // see; just exit and let the next refresh land.
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Read a TRC-20 balance via `triggerConstantContract`. Caller
    /// gets the raw 256-bit on-chain amount as a base-10 string so
    /// the decimals-aware formatter on `TronTRC20Token` can render
    /// it without truncation.
    private func probeTRC20Balance(holder: String, contract: String, rpcURL: String) async throws -> String {
        try await TronTRC20TransferBuilder.balance(
            holderBase58: holder,
            contractBase58: contract,
            rpcURL: rpcURL
        )
    }
}
