// Solana dashboard. Mirrors EthereumWalletView's structure so the
// visual + behaviour parity across the two chains stays tight:
// ScrollView/VStack with card-style sections, wallet picker chip,
// network dropdown chip, balance card with fiat caption + last-sync
// row, Send / Receive / Explorer action row, tokens section, recent
// transactions list with a "See all" link.

import SwiftUI
import UIKit

struct SolanaWalletView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var balance: UInt64?
    @State private var address: String?
    @State private var lastSyncAt: Date?
    @State private var recent: [SolanaRPCClient.SignatureRecord] = []
    /// Per-signature SOL delta cache. Lazily filled by each row's
    /// `.task(id:)` as it scrolls into view; cleared on wallet switch.
    @State private var deltaBySignature: [String: SolanaRPCClient.TransactionDelta] = [:]
    /// Token-account balances keyed by mint. Refreshed on every
    /// dashboard sync along with the SOL balance.
    @State private var tokenBalances: [String: UInt64] = [:]
    @State private var syncing: Bool = false
    @State private var lastError: String?
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showWallets = false
    @State private var showAllTxs = false
    @State private var showAddWallet = false
    @State private var showAddToken = false
    @State private var detailToken: SolanaSPLToken?
    /// Mint that the dashboard is about to surface as "Unknown
    /// token, add as custom?" via the AddTokenSheet pre-populated
    /// with that mint.
    @State private var unknownMintToAdd: String?

    private var activeWallet: SolanaWalletDescriptor? {
        store.solanaWalletStore.activeWallet
    }

    /// Cluster the active wallet is currently viewed on. Drives the
    /// chip row, the RPC client, and the explorer link. Mirrors the
    /// `activeNetwork` accessor on EthereumWalletView.
    private var activeNetwork: SolanaNetwork {
        guard let id = activeWallet?.id else { return .mainnet }
        return store.solanaWalletStore.activeNetwork(for: id)
    }

    /// Show the locked banner when the sandwich is sealed AND the
    /// active wallet derives from the seed (hardware wallets cache
    /// the address + sign on-device, so they don't need the
    /// sandwich to operate).
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
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Solana")
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
        // stranding the user on an empty, non-functional Solana page.
        .onChange(of: store.solanaWalletStore.wallets.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            showWallets = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
        }
        // Horizontal swipe shortcuts inside the wallet: left → Send,
        // right → Receive. 60pt minimum distance with horizontal-
        // dominance check so the vertical scroll wins on diagonals.
        .simultaneousGesture(
            DragGesture(minimumDistance: 60, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }
                    if dx < -80, address != nil {
                        showSend = true
                    } else if dx > 80 {
                        showReceive = true
                    }
                }
        )
        .sheet(isPresented: $showSend) {
            if let id = activeWallet?.id {
                NavigationStack {
                    SolanaSendView(walletId: id)
                        .environment(store)
                }
            }
        }
        .sheet(isPresented: $showReceive) {
            if let id = activeWallet?.id {
                NavigationStack {
                    SolanaReceiveView(walletId: id)
                        .environment(store)
                }
            }
        }
        .sheet(isPresented: $showWallets) {
            NavigationStack {
                SolanaWalletsView()
                    .environment(store)
            }
        }
        .sheet(isPresented: $showAddWallet) {
            AddSolanaWalletSheet { _ in
                showAddWallet = false
            }
            .environment(store)
        }
        .sheet(isPresented: $showAddToken) {
            SolanaAddTokenSheet(
                network: activeNetwork,
                prefilledMint: unknownMintToAdd
            ) {
                // Clear the pending unknown after the sheet closes so
                // the dashboard banner stops re-suggesting the same
                // mint until the next refresh discovers it again.
                unknownMintToAdd = nil
                Task { await refresh() }
            }
            .environment(store)
        }
        .sheet(item: $detailToken) { token in
            if let id = activeWallet?.id {
                SolanaTokenDetailView(walletId: id, token: token)
                    .environment(store)
            }
        }
    }

    // MARK: -- sections

    @ViewBuilder
    private var walletPicker: some View {
        if let w = activeWallet {
            Menu {
                ForEach(store.solanaWalletStore.wallets) { row in
                    Button {
                        store.solanaWalletStore.setActive(row.id)
                        Task { await refresh() }
                    } label: {
                        Label(row.label, systemImage: row.id == w.id ? "checkmark" : "")
                    }
                }
                Divider()
                Button {
                    showWallets = true
                } label: {
                    Label("Manage wallets", systemImage: "list.bullet")
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.purple.opacity(0.18))
                        Image(systemName: "circle.hexagongrid")
                            .foregroundStyle(Color.purple)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.label).font(.headline)
                        Text(walletSubtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }
            .foregroundStyle(.primary)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tertiary)
                Button {
                    showAddWallet = true
                } label: {
                    Label("Add a Solana wallet", systemImage: "plus.circle.fill")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var walletSubtitle: String {
        guard let w = activeWallet else { return "—" }
        switch w.kind {
        case .software(let a):           return "Software · Account \(a)"
        case .hardware(_, let a, _):     return "Hardware · Account \(a)"
        }
    }

    /// Cluster picker. Mirrors EthereumWalletView's network chip.
    /// Switching clusters re-fetches balance + recent tx against the
    /// new RPC; the address is the same on every cluster.
    @ViewBuilder
    private var networkPicker: some View {
        if let w = activeWallet {
            Menu {
                ForEach(SolanaNetwork.allCases, id: \.self) { n in
                    Button {
                        store.solanaWalletStore.setActiveNetwork(walletId: w.id, network: n)
                        balance = nil
                        recent = []
                        tokenBalances = [:]
                        Task { await refresh() }
                    } label: {
                        Label(n.displayName, systemImage: activeNetwork == n ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(Color.purple)
                    Text(activeNetwork.displayName)
                        .font(.callout.weight(.medium))
                    if activeNetwork != .mainnet {
                        Text("Testnet")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
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
            .foregroundStyle(.primary)
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(balanceDisplay)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("SOL")
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

    /// "Account #N · short-address · copy" row, immediately below
    /// the wallet picker so the user sees the active address before
    /// scrolling. Was previously inside the balance card.
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

    /// "Last sync … · refresh" row, immediately below the network
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

    /// BIP44 account index for the active wallet. Threaded into the
    /// shared `AccountAddressBadge` so the dashboard renders the
    /// same "Account #N · 7XmK…3Y4f [copy]" identity row every
    /// account-based chain uses.
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
        .foregroundStyle(enabled ? Color.purple : Color.secondary)
        .disabled(!enabled)
    }

    /// Open the active cluster's block explorer pointed at the
    /// wallet's address. Solana's default explorer encodes the
    /// cluster as a query param on non-mainnet URLs; route the path
    /// around the query string so the link doesn't end up malformed.
    private func openExplorer() {
        guard let addr = address else { return }
        guard let url = explorerURL(forAddress: addr) else { return }
        UIApplication.shared.open(url)
    }

    /// Explorer URL for an arbitrary Solana address. Handles
    /// Solana Explorer's `?cluster=devnet` query convention.
    private func explorerURL(forAddress addr: String) -> URL? {
        let base = store.solanaSettings.explorerURL(for: activeNetwork)
        let final: String
        if base.contains("?") {
            final = base.replacingOccurrences(of: "?", with: "/address/\(addr)?")
        } else {
            final = "\(base)/address/\(addr)"
        }
        return URL(string: final)
    }

    /// Explorer URL for a transaction signature on the active cluster.
    fileprivate func explorerURL(forSignature sig: String) -> URL? {
        let base = store.solanaSettings.explorerURL(for: activeNetwork)
        let final: String
        if base.contains("?") {
            final = base.replacingOccurrences(of: "?", with: "/tx/\(sig)?")
        } else {
            final = "\(base)/tx/\(sig)"
        }
        return URL(string: final)
    }

    /// Lazy lookup of the SOL delta for a signature. The row calls
    /// this once on appear; subsequent renders read from the
    /// `deltaBySignature` cache. Returns nil on failure so the row
    /// falls back to "—".
    @MainActor
    fileprivate func fetchDeltaIfNeeded(for sig: String) async {
        if deltaBySignature[sig] != nil { return }
        guard let addr = address else { return }
        let rpcURL = store.solanaSettings.rpcURL(for: activeNetwork)
        guard let url = URL(string: rpcURL) else { return }
        let rpc = SolanaRPCClient(endpoint: url)
        if let delta = try? await rpc.getTransactionDelta(signature: sig, ownerAddress: addr) {
            deltaBySignature[sig] = delta
        }
    }

    private var balanceDisplay: String {
        guard let b = balance else { return "—" }
        let sol = Double(b) / 1_000_000_000.0
        return String(format: "%.6f", sol)
    }

    /// Fiat caption shown under the balance, e.g. "≈ $42.10". nil
    /// when fiat references are off, the cluster has no CoinGecko
    /// id (testnets), or no price is cached yet.
    private var nativeFiatCaption: String? {
        guard let b = balance,
              let asset = activeNetwork.coinGeckoAssetId,
              b > 0
        else { return nil }
        let sol = Decimal(b) / Decimal(1_000_000_000)
        return store.assetPrices.fiatCaption(
            amount: sol,
            asset: asset,
            fiat: store.fiatPreferences.code
        )
    }

    private var lastSyncSummary: String {
        // Prefer the in-session sync timestamp (covers cluster-flip
        // refreshes that don't touch the descriptor); fall back to
        // the persisted descriptor timestamp on cold launch.
        if let last = lastSyncAt ?? activeWallet?.lastSyncAt {
            return "Last sync \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))"
        }
        return "Never synced"
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    @ViewBuilder
    private var tokensSection: some View {
        let tokens = store.solanaSPLTokenStore.tokens(on: activeNetwork)
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
                Text("No SPL tokens yet.")
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
                            SolanaSPLTokenRow(
                                token: token,
                                rawBalance: tokenBalances[token.mint]
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
                            UIPasteboard.general.string = token.mint
                        } label: {
                            Label("Copy mint address", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            store.solanaSPLTokenStore.remove(token)
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
        let unknown = store.solanaSPLTokenStore.unknownMints(on: activeNetwork)
        if !unknown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Unknown tokens detected")
                        .font(.subheadline.weight(.semibold))
                }
                Text("These mints aren't in the verified catalog. They could be legitimate tokens not yet listed, or airdrop spam. Add only after verifying the mint against a trusted source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(unknown, id: \.self) { mint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button("Add as custom…") {
                                unknownMintToAdd = mint
                                showAddToken = true
                            }
                            .font(.caption)
                            Button("Ignore") {
                                store.solanaSPLTokenStore.dismissUnknown(mint, on: activeNetwork)
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

    private var pendingForActive: [PendingSolanaTx] {
        guard let id = activeWallet?.id else { return [] }
        return store.solanaWalletStore.pendingTxsByWallet[id] ?? []
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
                ForEach(pending) { p in
                    PendingSolanaTxRow(
                        pending: p,
                        explorerURL: explorerURL(forSignature: p.signature)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                ForEach(recent.prefix(5), id: \.signature) { sig in
                    txRow(sig)
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

    private func txRow(_ rec: SolanaRPCClient.SignatureRecord) -> some View {
        let delta = deltaBySignature[rec.signature]
        let direction: SolanaTxDirection = {
            guard let d = delta else { return .pending }
            if d.lamports > 0 { return .receive }
            if d.lamports < 0 { return .send }
            return .other
        }()
        let amountString: String = {
            guard let d = delta else { return "—" }
            let abs = Double(d.lamports.magnitude) / 1_000_000_000.0
            let sign = d.lamports > 0 ? "+" : (d.lamports < 0 ? "−" : "")
            return String(format: "%@%.6f SOL", sign, abs)
        }()
        let failed = rec.err != nil && rec.err?.isNull == false
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: direction.icon)
                .foregroundStyle(direction.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if let t = rec.blockTime {
                    Text(Date(timeIntervalSince1970: TimeInterval(t)), style: .relative)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                } else {
                    Text("Pending")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(rec.signature.prefix(8) + "…" + rec.signature.suffix(4))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if failed {
                    Text("Failed").font(.caption2).foregroundStyle(.red)
                } else if let conf = rec.confirmationStatus {
                    Text(conf.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let url = explorerURL(forSignature: rec.signature) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Solana Explorer")
            }
        }
        .padding(.vertical, 4)
        .task(id: rec.signature) {
            await fetchDeltaIfNeeded(for: rec.signature)
        }
    }

    // MARK: -- refresh

    @MainActor
    private func refresh() async {
        guard let descriptor = activeWallet, let sandwich = store.sandwich else { return }
        syncing = true
        defer { syncing = false }
        let net = activeNetwork
        let rpcURL = store.solanaSettings.rpcURL(for: net)
        let wallet = SolanaWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: sandwich
        )
        // Refresh the verified-token catalog opportunistically. The
        // call no-ops if the cache is still fresh; the user can also
        // force-refresh from Solana Settings.
        await store.solanaTokenCatalog.refreshIfStale(
            catalogURL: store.solanaSettings.tokenCatalogURL
        )
        do {
            let a = try await wallet.resolvedAddress(
                biometricReason: "Sync \(descriptor.label)"
            )
            self.address = a
            // Now that the software wallet's address is known, push
            // it into the address-book mirror so internal sends can
            // pick it from the contacts picker. Hardware wallets
            // already have their mirror seeded at descriptor creation.
            store.solanaWalletStore.updateMirrorAddress(walletId: descriptor.id, address: a)
            self.balance = try await wallet.refreshBalance(
                biometricReason: "Sync \(descriptor.label)"
            )
            self.recent = (try? await wallet.recentSignatures(limit: 10, biometricReason: "Sync \(descriptor.label)")) ?? []
            self.lastSyncAt = Date()
            store.solanaWalletStore.markSynced(id: descriptor.id, at: Date())
            // Evict any pending entries whose signature is now in
            // the confirmed feed (or older than 3 minutes).
            let confirmedSigs = Set(recent.map { $0.signature })
            store.solanaWalletStore.dropConfirmedPending(
                walletId: descriptor.id,
                confirmedSignatures: confirmedSigs
            )
            // Token-account scan: walk every SPL holding the wallet
            // has, match each mint against the catalog, auto-install
            // verified ones, and surface unverified mints in the
            // dashboard banner.
            let holdings = (try? await wallet.tokenAccounts(biometricReason: "Sync \(descriptor.label)")) ?? []
            // Drop zero-balance accounts: SPL Token Accounts can
            // persist after a transfer-out and we don't want to
            // re-surface a stale unverified-token banner the user
            // already dismissed.
            let nonZero = holdings.filter { $0.amount > 0 }
            store.solanaSPLTokenStore.reconcile(
                heldMints: nonZero.map { $0.mint },
                on: net,
                catalog: store.solanaTokenCatalog
            )
            // Cache the per-mint balances so the dashboard row can
            // render the user's holdings without re-querying.
            var balances: [String: UInt64] = [:]
            for h in nonZero { balances[h.mint] = h.amount }
            self.tokenBalances = balances
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// Optimistic-pending row used by `SolanaWalletView` to surface a
/// freshly-broadcast tx before RPC returns it as confirmed. Same
/// visual cadence as the confirmed `txRow` (pulsing clock icon +
/// "Pending" status text).
struct PendingSolanaTxRow: View {
    let pending: PendingSolanaTx
    let explorerURL: URL?
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
                .accessibilityLabel("Open in Solana Explorer")
            }
        }
        .padding(.vertical, 4)
        .onAppear { pulse = true }
    }

    private var amountString: String {
        if let symbol = pending.tokenSymbol, let decimals = pending.tokenDecimals {
            let factor = pow(10.0, Double(decimals))
            let v = Double(pending.lamports) / factor
            let sign = pending.direction == .out ? "−" : "+"
            return "\(sign)\(formatted(v, maxFraction: Int(decimals))) \(symbol)"
        }
        let sol = Double(pending.lamports) / 1_000_000_000.0
        let sign = pending.direction == .out ? "−" : "+"
        return "\(sign)\(formatted(sol, maxFraction: 6)) SOL"
    }

    private func formatted(_ v: Double, maxFraction: Int) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxFraction
        return f.string(from: NSDecimalNumber(decimal: Decimal(v))) ?? String(v)
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }
}

/// Tx-row direction tag mirroring `EthereumTxRow.TxDirection`. Decides
/// the row's leading icon + tint.
fileprivate enum SolanaTxDirection {
    case send, receive, pending, other

    var icon: String {
        switch self {
        case .send:    return "arrow.up.circle.fill"
        case .receive: return "arrow.down.circle.fill"
        case .pending: return "circle.dotted"
        case .other:   return "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .send:    return .orange
        case .receive: return .green
        case .pending: return .secondary
        case .other:   return .secondary
        }
    }
}
