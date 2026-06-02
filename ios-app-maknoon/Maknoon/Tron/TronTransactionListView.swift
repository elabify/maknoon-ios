// Full transaction history for a Tron wallet. Mirrors
// `EthereumTransactionListView`: reused row layout, lazy-fetched
// list of 100 most-recent transactions on the current network.

import SwiftUI

struct TronTransactionListView: View {
    let wallet: TronWallet
    let ownerAddress: String
    let network: TronNetwork
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var txs: [TronRPCClient.TxRecord] = []
    @State private var loading: Bool = false
    @State private var lastError: String?

    private var explorerBaseURL: String {
        store.tronSettings.explorerURL(for: network)
    }

    var body: some View {
        NavigationStack {
            List(txs) { tx in
                TronTxRow(
                    tx: tx,
                    ownerAddress: ownerAddress,
                    explorerBaseURL: explorerBaseURL,
                    network: network
                )
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if txs.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "tray",
                        description: Text(lastError ?? "Fund this wallet to see history here.")
                    )
                }
            }
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
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            txs = try await wallet.recentTransactions(
                limit: 100,
                biometricReason: "Refresh Tron transactions"
            )
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// One transaction row used by both `TronWalletView`'s preview list
/// and the full `TronTransactionListView`. Mirrors `EthereumTxRow`:
/// direction icon, relative date, counterparty, signed amount,
/// confirmation status, explorer link.
struct TronTxRow: View {
    let tx: TronRPCClient.TxRecord
    /// Wallet's own T-prefixed address. Used to compute send vs
    /// receive direction and to short-display the counterparty.
    let ownerAddress: String
    /// Base URL of the active network's TronScan instance.
    let explorerBaseURL: String
    let network: TronNetwork

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: direction.icon)
                .foregroundStyle(direction.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if let t = tx.blockTimestamp {
                    Text(Date(timeIntervalSince1970: TimeInterval(t) / 1000), style: .relative)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                } else {
                    Text("Pending")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(counterpartyShort)
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
                } else if let s = tx.contractStatus {
                    Text(s.capitalized).font(.caption2).foregroundStyle(.secondary)
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
                .accessibilityLabel("Open in TronScan")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: -- derived

    enum Direction { case `in`, out, contract, other }
    private var direction: Direction {
        let me = ownerAddress
        if tx.contractType == "TransferContract",
           let v = tx.contractValue {
            if v.toAddress == me { return .in }
            if v.ownerAddress == me { return .out }
            return .other
        }
        // TriggerSmartContract → TRC-20 etc. Treat as contract-call
        // unless we can determine direction.
        return .contract
    }

    private var failed: Bool {
        guard let s = tx.contractStatus else { return false }
        return s != "SUCCESS"
    }

    private var counterpartyShort: String {
        if let v = tx.contractValue {
            let other: String?
            switch direction {
            case .in:  other = v.ownerAddress
            case .out: other = v.toAddress
            case .contract: other = v.contractAddress
            case .other: other = v.toAddress ?? v.ownerAddress
            }
            if let a = other, !a.isEmpty {
                if a.count > 12 {
                    return "\(a.prefix(6))…\(a.suffix(4))"
                }
                return a
            }
        }
        let id = tx.txID
        if id.count > 12 {
            return "\(id.prefix(6))…\(id.suffix(4))"
        }
        return id
    }

    private var amountString: String {
        guard let sun = tx.nativeSunAmount, sun > 0 else {
            // TRC-20 or non-transfer: no native amount we can decode
            // cheaply. Display the contract type for context.
            return tx.contractType == "TriggerSmartContract" ? "TRC-20" : "—"
        }
        let trx = Double(sun) / 1_000_000.0
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 6
        let amt = f.string(from: NSDecimalNumber(decimal: Decimal(trx))) ?? String(trx)
        let sign: String
        switch direction {
        case .in:  sign = "+"
        case .out: sign = "−"
        case .contract, .other: sign = ""
        }
        return "\(sign)\(amt) TRX"
    }

    private var explorerURL: URL? {
        let base = explorerBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/#/transaction/\(tx.txID)")
    }
}

/// Optimistic-pending row used by `TronWalletView` to surface a
/// freshly-broadcast tx before TronGrid returns it as confirmed.
/// Same visual cadence as `TronTxRow`, with a pulsing clock icon
/// + "Pending" status text so it's clearly distinct.
struct PendingTronTxRow: View {
    let pending: PendingTronTx
    let explorerBaseURL: String
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
                .accessibilityLabel("Open in TronScan")
            }
        }
        .padding(.vertical, 4)
        .onAppear { pulse = true }
    }

    private var amountString: String {
        // TRC-20 path: amount carried separately. The native sun
        // value isn't meaningful for token transfers.
        if let symbol = pending.tokenSymbol, let decimals = pending.tokenDecimals {
            // We don't carry the raw token amount on PendingTronTx
            // today (caller passes the sun for native only); for
            // TRC-20 the sun field is reused as the raw-units value.
            let factor = pow(10.0, Double(decimals))
            let v = Double(pending.sunAmount) / factor
            let sign = pending.direction == .out ? "−" : "+"
            return "\(sign)\(formatted(v, maxFraction: Int(decimals))) \(symbol)"
        }
        let trx = Double(pending.sunAmount) / 1_000_000.0
        let sign = pending.direction == .out ? "−" : "+"
        return "\(sign)\(formatted(trx, maxFraction: 6)) TRX"
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

    private var explorerURL: URL? {
        let base = explorerBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/#/transaction/\(pending.txID)")
    }
}

fileprivate extension TronTxRow.Direction {
    var icon: String {
        switch self {
        case .in:       return "arrow.down.circle.fill"
        case .out:      return "arrow.up.circle.fill"
        case .contract: return "doc.text.fill"
        case .other:    return "circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .in:       return .green
        case .out:      return .orange
        case .contract: return .blue
        case .other:    return .secondary
        }
    }
}
