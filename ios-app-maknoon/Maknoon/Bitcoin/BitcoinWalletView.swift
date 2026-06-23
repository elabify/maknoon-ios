// Top-level screen for the active Bitcoin wallet. Wallet picker at the
// top, big balance, last-sync timestamp, manual refresh, recent
// transactions, and three action buttons (Send / Receive /
// Addresses).
//
// Pushed by WalletView's Bitcoin section.

import SwiftUI
import BitcoinDevKit

struct BitcoinWalletView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var balance: Balance?
    @State private var recentTxs: [CanonicalTx] = []
    /// Pre-computed signed net deltas keyed by full txid hex.
    /// Populated alongside `recentTxs` so each BitcoinTxRow can
    /// render the real signed amount instead of an em-dash.
    @State private var recentTxNetSats: [String: Int64] = [:]
    @State private var syncing: Bool = false
    @State private var lastError: String?
    @State private var rebuildNotice: String?
    @State private var bitcoin: BitcoinWallet?
    /// Next unrevealed receive address. Cached so the dashboard's
    /// "Next receive" row doesn't re-derive on every redraw. Filled
    /// from `bitcoin.nextReceiveAddress()` after the wallet handle
    /// is ready; nil while loading.
    @State private var nextReceiveAddress: String?
    @State private var copiedReceive: Bool = false
    @State private var showWallets = false
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showAddresses = false
    @State private var showAllTxs = false
    @State private var showSignMessage = false
    @State private var showVerifyMessage = false
    @State private var showAddWallet = false

    private var activeWallet: BitcoinWalletDescriptor? {
        store.bitcoinWalletStore.activeWallet
    }

    /// Show the locked banner when the sandwich is sealed AND the
    /// active wallet derives from the seed. Mirrors the same rule
    /// every other account-based chain uses; hardware wallets
    /// (BDK-backed via the cached xpub) keep working.
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
                if let rebuildNotice {
                    rebuildBanner(reason: rebuildNotice)
                }
                nextReceiveRow
                syncRow
                balanceCard
                actionButtons
                recentList
                if let lastError {
                    Text(lastError).font(.callout).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .padding(.vertical, 16)
        }
        // Pull-down to re-sync. Standard iOS gesture; the existing
        // refresh logic runs the Electrum sync and reloads BDK
        // state.
        .refreshable { await refresh() }
        // Horizontal swipe shortcuts inside the wallet:
        //   swipe LEFT  → Send
        //   swipe RIGHT → Receive
        .simultaneousGesture(walletSwipeGesture)
        // Hide the system back button + swipe-back so an accidental
        // horizontal swipe doesn't pop back to the wallet list.
        // Custom "Wallets" button on the leading edge keeps
        // explicit back-navigation available.
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Bitcoin")
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
                    Divider()
                    Button {
                        showSignMessage = true
                    } label: {
                        Label("Sign message", systemImage: "signature")
                    }
                    Button {
                        showVerifyMessage = true
                    } label: {
                        Label("Verify message", systemImage: "checkmark.seal")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Wallet actions")
            }
        }
        .task(id: activeWallet?.id) { await openAndSync() }
        // Deleting the last wallet (from Manage wallets) leaves this
        // screen with no active wallet and nothing to show. Close the
        // manage sheet and pop back to the Wallets home instead of
        // stranding the user on an empty, non-functional Bitcoin page.
        .onChange(of: store.bitcoinWalletStore.wallets.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            showWallets = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
        }
        .sheet(isPresented: $showWallets) {
            BitcoinWalletsView()
                .environment(store)
        }
        .sheet(isPresented: $showAddWallet) {
            AddBitcoinWalletSheet()
                .environment(store)
        }
        .sheet(isPresented: $showSend) {
            if let bitcoin {
                BitcoinSendView(wallet: bitcoin) { _ in
                    Task { await refresh() }
                }
                .environment(store)
            }
        }
        .sheet(isPresented: $showReceive) {
            if let bitcoin {
                BitcoinReceiveView(wallet: bitcoin)
                    .environment(store)
            }
        }
        .sheet(isPresented: $showAddresses) {
            if let bitcoin {
                BitcoinAddressesView(wallet: bitcoin)
                    .environment(store)
            }
        }
        .sheet(isPresented: $showSignMessage) {
            BitcoinSignMessageSheet(activeWallet: activeWallet)
                .environment(store)
        }
        .sheet(isPresented: $showVerifyMessage) {
            BitcoinVerifyMessageSheet()
                .environment(store)
        }
        .sheet(isPresented: $showAllTxs) {
            if let bitcoin {
                BitcoinTransactionListView(wallet: bitcoin)
                    .environment(store)
            }
        }
    }

    /// Horizontal swipe handler. 60-pt minimum distance so accidental
    /// taps + small finger jitters don't trigger; we require the
    /// horizontal translation to dominate the vertical so a
    /// diagonal pan doesn't conflict with the scroll view.
    private var walletSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 60, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5 else { return }
                if dx < -80 {
                    showSend = true
                } else if dx > 80 {
                    showReceive = true
                }
            }
    }

    // MARK: -- subviews

    private var walletPicker: some View {
        Menu {
            ForEach(store.bitcoinWalletStore.wallets) { w in
                Button {
                    store.bitcoinWalletStore.setActive(w.id)
                } label: {
                    Label("\(w.label) - \(w.network.displayName)", systemImage: w.id == activeWallet?.id ? "checkmark" : "")
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
                ChainLogo("ChainBitcoin", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeWallet?.label ?? "No wallet").font(.headline)
                        if let backing = backingDevice {
                            // Hardware-wallet badge so the user always
                            // knows which physical device backs this
                            // wallet before they hit Send.
                            Label(backing.label, systemImage: backing.kind.systemImage)
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
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

    /// If the active wallet is hardware-backed, surface the matching
    /// registered device so the picker can show a badge and the Send
    /// button can name the device.
    private var backingDevice: RegisteredDevice? {
        guard let w = activeWallet,
              case let .hardware(deviceId, _, _) = w.kind
        else { return nil }
        return store.devices.find(id: deviceId)
    }

    /// Stable per-wallet input for `WalletThumbprint`. We prefer the
    /// account-level xpub because it's unique per (seed, account,
    /// network) AND it's the same string Sparrow / Specter / etc.
    /// would use to label this wallet, which makes cross-tool
    /// identification trivial. Falls back to the wallet UUID if no
    /// xpub is yet cached (legacy software wallet pre-migration).
    private func thumbprintSeed(for descriptor: BitcoinWalletDescriptor?) -> String {
        guard let descriptor else { return "no-wallet" }
        if let xpub = descriptor.cachedAccountXpub, !xpub.isEmpty { return xpub }
        switch descriptor.kind {
        case .hardware(_, _, let xpub): return xpub
        case .software:                 return descriptor.id.uuidString
        }
    }

    private var walletSubtitle: String {
        guard let w = activeWallet else { return "-" }
        let accountSuffix: String
        switch w.kind {
        case .software(let acct):  accountSuffix = "Index \(acct)"
        case .hardware:
            // Hardware wallets don't carry their account index in
            // the kind today; we surface "Hardware wallet" as the
            // suffix. The wallet's name already includes the
            // `#<account>` so the account is still visible.
            accountSuffix = "Hardware wallet"
        }
        return "\(w.network.displayName) · \(accountSuffix)"
    }

    /// "Next receive: bc1q…xyz · copy" row. Sits immediately below
    /// the wallet picker. Bitcoin has no single "the" address (HD
    /// keychain), so the most-actionable surface is the next
    /// unrevealed receive address, what the user would share with
    /// a sender right now.
    @ViewBuilder
    private var nextReceiveRow: some View {
        if let addr = nextReceiveAddress {
            HStack(spacing: 10) {
                Image(systemName: "wallet.pass")
                    .font(.callout)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next receive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(addr)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = addr
                    withAnimation { copiedReceive = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { copiedReceive = false }
                    }
                } label: {
                    Image(systemName: copiedReceive ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy receive address")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    /// "Last sync … · refresh" row. Sits between the next-receive
    /// row and the balance card.
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
        VStack(spacing: 8) {
            Text(displayBalance)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(activeWallet?.network.ticker ?? "BTC")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let fiat = fiatBalance {
                Text(fiat).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 8)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton(sendButtonLabel, systemImage: "arrow.up.right.circle.fill") { showSend = true }
            actionButton("Receive", systemImage: "arrow.down.left.circle.fill") { showReceive = true }
            actionButton("Addresses", systemImage: "list.bullet.rectangle.fill") { showAddresses = true }
        }
        .padding(.horizontal, 16)
    }

    private var sendButtonLabel: String {
        return "Send"
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.medium))
                    // Keep all three buttons the same height even
                    // when one label wraps to two lines.
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
        .foregroundStyle(.orange)
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
            if recentTxs.isEmpty {
                emptyTxs
            } else {
                ForEach(Array(recentTxs.prefix(5).enumerated()), id: \.offset) { _, tx in
                    BitcoinTxRow(
                        tx: tx,
                        network: activeWallet?.network ?? .mainnet,
                        explorerBaseURL: store.bitcoinSettings.explorerURL(for: activeWallet?.network ?? .mainnet),
                        netSat: recentTxNetSats[String(describing: tx.transaction.computeTxid())],
                        wallet: bitcoin
                    )
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyTxs: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
            Text("No transactions yet").foregroundStyle(.secondary).font(.callout)
            Text("Fund this wallet to see it here. Use Receive to copy a deposit address.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: -- data

    private var displayBalance: String {
        guard let b = balance else { return "-" }
        let sats = b.total.toSat()
        let btc = Double(sats) / 100_000_000.0
        return String(format: "%.8f", btc)
    }

    private var fiatBalance: String? {
        guard let b = balance,
              activeWallet?.network == .mainnet
        else { return nil }
        let sats = b.total.toSat()
        guard sats > 0 else { return nil }
        let btc = Decimal(sats) / Decimal(100_000_000)
        // Returns nil when the user disabled fiat references; the
        // caller hides the caption entirely in that case.
        return store.assetPrices.fiatCaption(
            amount: btc,
            asset: "bitcoin",
            fiat: store.fiatPreferences.code
        )
    }

    private var lastSyncSummary: String {
        guard let last = activeWallet?.lastSyncAt else { return "Never synced" }
        let rel = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        return "Last sync \(rel)"
    }

    @MainActor
    private func openAndSync() async {
        // No auto-seed: the user creates wallets explicitly from the
        // Wallet tab's "+" via AddNetworkSheet > Bitcoin > Add
        // software wallet (or from Manage wallets > Discover for
        // recovery cases).
        guard let descriptor = activeWallet else { return }
        do {
            let result = try BitcoinWallet.openWithResult(
                descriptor: descriptor, sandwich: store.sandwich
            )
            bitcoin = result.wallet
            // If this open derived from the seed (legacy wallet
            // path), the result carries the cacheable public-key
            // material. Persist it so the next open is biometric-
            // free.
            if let updated = result.updatedDescriptor,
               let fp = updated.cachedAccountFingerprint,
               let xpub = updated.cachedAccountXpub
            {
                store.bitcoinWalletStore.setCachedAccountKey(
                    id: descriptor.id, fingerprint: fp, xpub: xpub
                )
            }
            if result.rebuilt {
                // Local cache was wiped because BDK couldn't load
                // the previous SQLite. Clear lastSyncAt so the next
                // refresh runs a full scan (incremental sync would
                // hit zero revealed addresses on a wiped db and
                // silently return empty). Banner stays visible until
                // dismissed.
                store.bitcoinWalletStore.clearLastSync(id: descriptor.id)
                rebuildNotice = result.rebuildReason ?? "Maknoon upgrade or schema mismatch"
            } else {
                rebuildNotice = nil
            }
            await refresh()
        } catch {
            lastError = "Open failed: \(error)"
        }
    }

    @MainActor
    private func refresh() async {
        guard let bitcoin else { return }
        guard let descriptor = activeWallet else { return }
        let url = store.bitcoinSettings.electrumURL(for: descriptor.network)
        // Show whatever BDK has persisted from the previous sync
        // BEFORE kicking off the slow Electrum round trip. On a
        // first-ever open both reads return empty, but on every
        // subsequent open the balance + tx list pop instantly with
        // the last-known state and the "Syncing…" indicator tells
        // the user the wire fetch is still in flight. That fixes
        // the "blank wallet for 10+ seconds on every open" UX.
        balance = await bitcoin.balance()
        recentTxs = await bitcoin.transactions()
        await refreshNetSats(bitcoin: bitcoin, txs: recentTxs)
        // Surface the next unrevealed receive address in the
        // top-of-page row. Cheap call (BDK reads from its persister
        // without a wire round-trip).
        if let info = try? await bitcoin.nextReceiveAddress() {
            self.nextReceiveAddress = info.address.description
        }
        // Republish the next-unused receive address into the
        // shared address book so "Your wallets" entries always
        // point at a fresh address. nextUnusedAddress (unlike
        // nextReceiveAddress above) does not advance the
        // keychain, so it's safe on every refresh.
        let unused = await bitcoin.nextUnusedReceiveAddress()
        store.bitcoinWalletStore.updateMirrorAddress(
            walletId: descriptor.id,
            address: unused.address.description
        )
        syncing = true
        lastError = nil
        do {
            let lastSync = descriptor.lastSyncAt
            if lastSync == nil {
                try await bitcoin.fullScan(electrumURL: url)
            } else {
                try await bitcoin.sync(electrumURL: url)
            }
            balance = await bitcoin.balance()
            recentTxs = await bitcoin.transactions()
            await refreshNetSats(bitcoin: bitcoin, txs: recentTxs)
            // Post-sync, the next-unused address may have rolled
            // forward (the previous one received a payment). Push
            // the fresh value so the address-book mirror tracks.
            let postSyncUnused = await bitcoin.nextUnusedReceiveAddress()
            store.bitcoinWalletStore.updateMirrorAddress(
                walletId: descriptor.id,
                address: postSyncUnused.address.description
            )
            store.bitcoinWalletStore.markSynced(id: descriptor.id)
        } catch {
            // A superseded sync (pull-to-refresh racing the .task / a
            // concurrent refresh) is cancellation, not a failure.
            if isSupersededFetch(error) { syncing = false; return }
            lastError = "Sync failed: \(error)"
        }
        syncing = false
    }

    /// For every tx in the list, ask the wallet actor for its signed
    /// net delta (received - sent) so the row can render +0.001 /
    /// -0.001 BTC instead of an em-dash. Cheap (BDK keeps tx
    /// metadata in memory after sync); we call sequentially because
    /// the actor serialises them anyway and the typical view shows
    /// at most a few hundred txs.
    private func refreshNetSats(bitcoin: BitcoinWallet, txs: [CanonicalTx]) async {
        var out: [String: Int64] = [:]
        for tx in txs {
            let txid = String(describing: tx.transaction.computeTxid())
            out[txid] = await bitcoin.netAmount(tx: tx.transaction)
        }
        recentTxNetSats = out
    }

    /// Banner shown after BDK's load() failed and we wiped the local
    /// SQLite. Explicitly reassures the user the funds are safe and
    /// that a re-scan is running. The user can dismiss; on dismissal
    /// the banner does not return until another rebuild happens.
    private func rebuildBanner(reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local cache rebuilt").font(.callout.weight(.semibold))
                Text("Your wallet's local index could not be read, so Maknoon wiped it and is doing a full re-scan now. Your on-chain funds are safe and untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Reason: \(reason)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                rebuildNotice = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: -- transaction row

struct BitcoinTxRow: View {
    let tx: CanonicalTx
    let network: BitcoinNetwork
    var explorerBaseURL: String? = nil
    /// Pre-computed signed net delta in satoshis (received - sent).
    /// `nil` means the parent didn't compute one (legacy fallback);
    /// the row then renders an em-dash.
    var netSat: Int64? = nil
    /// The wallet this tx belongs to. Required for the "Bump fee"
    /// context-menu action because that path builds a replacement
    /// PSBT via BDK's BumpFeeTxBuilder. Optional so the row stays
    /// usable in any preview / non-active context that doesn't have
    /// a wallet handle; bump menu item is hidden when nil.
    var wallet: BitcoinWallet? = nil

    /// When true, the timestamp slot displays the block height
    /// instead. Toggles on tap.
    @State private var showBlockHeight = false
    @State private var showingLabelSheet = false
    @State private var showingBumpFeeSheet = false

    @Environment(HolderStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showBlockHeight.toggle()
                } label: {
                    Text(showBlockHeight ? blockHeightString : dateString)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Text(shortTxid)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = fullTxid
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy transaction ID")
                }
                if let label = txLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if isUnconfirmed {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text(statusString)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    // TimelineView re-renders every minute so the
                    // "Xm pending" counter ticks without the user
                    // having to pull-to-refresh.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        if let pending = pendingForString {
                            Text(pending)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if canBumpFee {
                        Button {
                            showingBumpFeeSheet = true
                        } label: {
                            Label("Bump fee", systemImage: "arrow.up.forward.circle")
                                .font(.caption2.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.orange)
                    }
                } else {
                    Text(statusString)
                        .font(.caption2).foregroundStyle(.secondary)
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
        .contextMenu {
            Button {
                showingLabelSheet = true
            } label: {
                Label("Label transaction…", systemImage: "tag")
            }
            if canBumpFee {
                Button {
                    showingBumpFeeSheet = true
                } label: {
                    Label("Bump fee…", systemImage: "arrow.up.forward.circle")
                }
            }
        }
        .sheet(isPresented: $showingLabelSheet) {
            // Scope: per-output label keyed on (txid, vout=0). vout 0
            // is the convention for a tx's primary identity label; if
            // a user later wants per-vout labels they get those via
            // the UTXO picker.
            BitcoinLabelEditSheet(scope: .output(txid: fullTxid, vout: 0))
                .environment(store)
        }
        .sheet(isPresented: $showingBumpFeeSheet) {
            if let wallet {
                BumpFeeSheet(
                    wallet: wallet,
                    originalTxidHex: fullTxid,
                    originalFeeSat: netSat.map { -$0 }  // outgoing net = -(amount+fee); fee component is < |netSat|
                )
                .environment(store)
            }
        }
    }

    private var blockHeightString: String {
        switch tx.chainPosition {
        case .confirmed(let blockTime, _):
            return "Block \(blockTime.blockId.height)"
        case .unconfirmed:
            return "Mempool"
        }
    }

    private var fullTxid: String { String(describing: tx.transaction.computeTxid()) }

    private var shortTxid: String {
        let s = fullTxid
        if s.count <= 16 { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }

    private var explorerURL: URL? {
        guard let base = explorerBaseURL else { return nil }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/tx/\(fullTxid)")
    }

    private var iconName: String {
        switch tx.chainPosition {
        case .confirmed: return "checkmark.circle.fill"
        case .unconfirmed: return "clock.fill"
        }
    }

    private var iconColor: Color {
        switch tx.chainPosition {
        case .confirmed: return .green
        case .unconfirmed: return .orange
        }
    }

    private var statusString: String {
        switch tx.chainPosition {
        case .confirmed:    return "Confirmed"
        case .unconfirmed:  return "Unconfirmed"
        }
    }

    private var isUnconfirmed: Bool {
        if case .unconfirmed = tx.chainPosition { return true }
        return false
    }

    /// Human caption for how long this tx has been pending. Uses
    /// BDK's first-seen timestamp on the unconfirmed chainPosition
    /// (set when we apply the broadcast result via
    /// `applyUnconfirmedTxs(lastSeen: now)`). Format graduates from
    /// "Just now" to "Xm pending" to "Xh Xm pending" so the user
    /// can decide when to hit Bump fee.
    private var pendingForString: String? {
        guard case .unconfirmed(let firstSeen) = tx.chainPosition,
              let firstSeen
        else { return nil }
        let elapsed = Int(Date().timeIntervalSince1970) - Int(firstSeen)
        guard elapsed >= 0 else { return nil }
        if elapsed < 60 { return "Just now" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m pending" }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        return "\(hours)h \(restMinutes)m pending"
    }

    private var amountString: String {
        // Pre-computed by the parent via BitcoinWallet.netAmount(tx:).
        // Display as +/- BTC with 8 decimals trimmed where possible.
        guard let sats = netSat else { return "-" }
        let signedBTC = Double(sats) / 100_000_000
        // The leading sign is preserved by String(format:) for negatives;
        // we prepend an explicit "+" for positive deltas so the
        // direction is unambiguous at a glance.
        let body = String(format: "%.8f", signedBTC)
        return sats >= 0 ? "+\(body)" : body
    }

    private var amountColor: Color {
        guard let sats = netSat else { return .primary }
        if sats > 0 { return .green }
        if sats < 0 { return .primary }
        return .secondary
    }

    private var txLabel: String? {
        // First-class: output-keyed label set by the user from the
        // tx row itself or the UTXO picker.
        if let l = store.bitcoinLabels.label(forOutput: fullTxid, vout: 0),
           !l.isEmpty {
            return l
        }
        return nil
    }

    /// Bump-fee is offered when:
    ///   * we have a wallet handle to build the replacement PSBT,
    ///   * the tx is still in the mempool (unconfirmed), and
    ///   * the tx is outgoing (net delta < 0, money left the wallet).
    /// BDK will surface a clean error if the tx itself isn't
    /// actually RBF-replaceable for some reason (e.g. it didn't
    /// signal AND the user's local node is on a non-full-RBF
    /// policy); we don't pre-check signaling here because the
    /// modern default is full-RBF on mining pools.
    private var canBumpFee: Bool {
        guard wallet != nil else { return false }
        guard case .unconfirmed = tx.chainPosition else { return false }
        return (netSat ?? 0) < 0
    }

    private var dateString: String {
        let ts: UInt64
        switch tx.chainPosition {
        case .confirmed(let blockTime, _):
            ts = blockTime.confirmationTime
        case .unconfirmed(let unconfirmedTs):
            ts = unconfirmedTs ?? UInt64(Date().timeIntervalSince1970)
        }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
