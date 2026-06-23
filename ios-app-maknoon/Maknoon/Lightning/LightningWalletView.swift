// Lightning wallet: account picker, balance, recent payments,
// Send / Receive entry points. Active account is sourced from the
// store; switching accounts re-pulls everything.
//
// Pull-to-refresh re-syncs balance + history. Same swipe-shortcut
// pattern as Bitcoin and Ethereum views: swipe left → Send, swipe
// right → Receive. Back button is the navigation "Wallets" leading
// item; system swipe-back is disabled.

import SwiftUI

struct LightningWalletView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var balanceSat: Int64?
    @State private var txs: [LightningTx] = []
    @State private var syncing = false
    @State private var lastError: String?
    @State private var showAccounts = false
    @State private var showSend = false
    @State private var showReceive = false
    @State private var showWithdraw = false
    @State private var showAllTxs = false

    private var activeAccount: LightningAccount? {
        store.lightningAccountStore.activeAccount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                accountPicker
                balanceCard
                actionButtons
                recentList
                if let lastError {
                    Text(lastError).font(.callout).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable { await refresh() }
        .simultaneousGesture(walletSwipeGesture)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Lightning")
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
                        showAccounts = true
                    } label: {
                        Label("Manage accounts", systemImage: "list.bullet.rectangle")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Account actions")
            }
        }
        .task(id: activeAccount?.id) { await refresh() }
        // Deleting the last account (from Manage accounts) leaves this
        // screen with no active account and nothing to show. Close the
        // manage sheet and pop back to the Wallets home instead of
        // stranding the user on an empty, non-functional Lightning page.
        .onChange(of: store.lightningAccountStore.accounts.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            showAccounts = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
        }
        .sheet(isPresented: $showAccounts) {
            LightningAccountsView()
                .environment(store)
        }
        .sheet(isPresented: $showSend) {
            if activeAccount != nil {
                LightningSendView(onPaid: { Task { await refresh() } })
                    .environment(store)
            }
        }
        .sheet(isPresented: $showReceive) {
            if activeAccount != nil {
                LightningReceiveView(onCreated: { Task { await refresh() } })
                    .environment(store)
            }
        }
        .sheet(isPresented: $showWithdraw) {
            if activeAccount != nil {
                LightningWithdrawView(onWithdrawn: { Task { await refresh() } })
                    .environment(store)
            }
        }
        .sheet(isPresented: $showAllTxs) {
            if let account = activeAccount {
                LightningTransactionListView(account: account)
                    .environment(store)
            }
        }
    }

    private var walletSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 60, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5 else { return }
                if dx < -80 { showSend = true }
                else if dx > 80 { showReceive = true }
            }
    }

    // MARK: -- subviews

    private var accountPicker: some View {
        Menu {
            ForEach(store.lightningAccountStore.accounts) { a in
                Button {
                    store.lightningAccountStore.setActive(a.id)
                } label: {
                    Label(a.label, systemImage: a.id == activeAccount?.id ? "checkmark" : "")
                }
            }
            Divider()
            Button {
                showAccounts = true
            } label: {
                Label("Manage accounts", systemImage: "list.bullet")
            }
        } label: {
            HStack {
                ChainLogo("ChainLightning", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeAccount?.label ?? "No account").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
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

    private var subtitle: String {
        guard let a = activeAccount else { return "-" }
        let host = URL(string: a.serverURL)?.host ?? a.serverURL
        return "\(a.username) · \(host)"
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(displayBalance)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("sats")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let fiat = fiatBalanceCaption {
                Text(fiat)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if syncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Last sync just now").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(syncing)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayBalance: String {
        guard let bal = balanceSat else { return "-" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: bal)) ?? "\(bal)"
    }

    /// Fiat caption under the sat-denominated balance, same path
    /// as the Bitcoin wallet view since 1 sat is 1e-8 BTC.
    private var fiatBalanceCaption: String? {
        guard let bal = balanceSat, bal > 0 else { return nil }
        let btc = Decimal(bal) / Decimal(100_000_000)
        return store.assetPrices.fiatCaption(
            amount: btc,
            asset: "bitcoin",
            fiat: store.fiatPreferences.code
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton("Send", systemImage: "arrow.up.right.circle.fill") { showSend = true }
            actionButton("Receive", systemImage: "arrow.down.left.circle.fill") { showReceive = true }
            actionButton("Withdraw", systemImage: "tray.and.arrow.down.fill") { showWithdraw = true }
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
        .foregroundStyle(activeAccount != nil ? Color.yellow : Color.secondary)
        .disabled(activeAccount == nil)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent payments").font(.headline)
                Spacer()
                // Always shown (matches Android Lightning); the full-history
                // sheet handles the empty case with its own placeholder.
                Button("See all") { showAllTxs = true }.font(.callout)
            }
            if txs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text("No payments yet").foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ForEach(txs.prefix(20)) { tx in
                    LightningTxRow(tx: tx)
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: -- data flow

    @MainActor
    private func refresh() async {
        guard let account = activeAccount else { return }
        guard let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
            lastError = "Password missing for this account. Re-import it."
            return
        }
        let client = LNDHubClient(account: account, password: pw)
        syncing = true
        lastError = nil
        do {
            balanceSat = try await client.balanceSat()
        } catch {
            // A superseded fetch (pull-to-refresh racing the .task / a
            // concurrent refresh) cancels the in-flight request; that's
            // not a failure, so bail quietly and let the newer one run.
            if isSupersededFetch(error) { syncing = false; return }
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        do {
            txs = try await client.history(limit: 50)
        } catch {
            if isSupersededFetch(error) { syncing = false; return }
            // Don't clear the previous history on transient failure.
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = (lastError.map { "\($0)\n" } ?? "") + "History: \(msg)"
        }
        syncing = false
    }
}

struct LightningTxRow: View {
    let tx: LightningTx

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: tx.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(tx.isOutgoing ? Color.orange : Color.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(dateString)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Text(tx.memo ?? (tx.isOutgoing ? "Outgoing payment" : "Incoming payment"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let fee = tx.fee, fee > 0 {
                    Text("fee \(fee) sat").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var amountString: String {
        let v = tx.value ?? 0
        let sign = tx.isOutgoing ? "−" : "+"
        return "\(sign)\(abs(v)) sat"
    }

    private var dateString: String {
        let ts = TimeInterval(tx.timestamp ?? 0)
        if ts <= 0 { return "-" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: Date(timeIntervalSince1970: ts))
    }
}
