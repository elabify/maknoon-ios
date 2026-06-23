// Native "receive payment" sheet for window.maknoon.payment.receive.
//
// Shows a per-chain payment-request QR (with the coin ticker badged in the
// centre) plus the crypto + fiat totals, and watches the receiving address
// on-chain. When the balance rises by at least the requested amount the
// sale is auto-confirmed and the continuation resolves; the merchant can
// also confirm manually or cancel. The customer pays from their own wallet
// by scanning the QR, nothing is signed on this device.

import SwiftUI
import Observation
import UIKit

@MainActor
@Observable
final class MiniAppPaymentCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        let chain: String
        let networkRaw: String?
        let networkDisplay: String
        let address: String
        let amount: Decimal       // on-chain: native units; lightning: sats
        let ticker: String
        let uri: String           // on-chain payment URI; empty for lightning
        let fiatText: String?
        var isLightning: Bool = false
    }

    private(set) var active: Request?
    private var continuation: CheckedContinuation<[String: Any], Error>?

    func present(_ request: Request) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = request
        }
    }

    func resolve(txHash: String?, request: Request, confirmedAt: Int64, bolt11: String? = nil) {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(returning: [
            "txHash": txHash ?? NSNull(),
            "bolt11": bolt11 ?? NSNull(),
            "chain": request.chain,
            "network": request.networkRaw ?? NSNull(),
            "amount": NSDecimalNumber(decimal: request.amount).stringValue,
            "confirmedAt": confirmedAt,
        ])
    }

    func cancel() {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}

struct MiniAppPaymentSheet: View {
    let request: MiniAppPaymentCoordinator.Request
    let store: HolderStore
    let onResolve: (_ txHash: String?, _ bolt11: String?, _ confirmedAt: Int64) -> Void
    let onCancel: () -> Void

    @State private var baseline: Decimal?
    @State private var status: String = "Waiting for payment…"
    @State private var watching = true
    @State private var bolt11: String?          // lightning invoice once created
    @State private var lnError: String?         // lightning invoice-creation error
    @State private var copied = false
    @State private var showScanner = false      // lightning: scan a customer voucher

    private var amountText: String {
        "\(NSDecimalNumber(decimal: request.amount).stringValue) \(request.ticker)"
    }

    /// The Lightning account this receive targets: the one chosen by the app
    /// (its UUID passed through `request.address`), else the active account.
    private var lightningAccount: LightningAccount? {
        if let id = UUID(uuidString: request.address),
           let a = store.lightningAccountStore.accounts.first(where: { $0.id == id }) { return a }
        return store.lightningAccountStore.activeAccount
    }

    /// What the QR encodes: an on-chain payment URI, or the BOLT11 invoice.
    private var qrPayload: String? {
        request.isLightning ? bolt11.map { "lightning:\($0)" } : request.uri
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Scan to pay").font(.headline)
                    Text("\(request.networkDisplay) · \(amountText)")
                        .font(.callout).foregroundStyle(.secondary)
                    if let fiat = request.fiatText {
                        Text(fiat).font(.caption).foregroundStyle(.secondary)
                    }
                    qrView
                    HStack(spacing: 8) {
                        if watching { ProgressView() }
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if request.isLightning {
                        if let inv = bolt11 {
                            Text(inv)
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                .lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).padding(.horizontal, 8)
                            Button {
                                UIPasteboard.general.string = inv
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy invoice", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .font(.caption)
                        }
                        // Dual mode: instead of the customer scanning our
                        // invoice, scan a withdraw voucher they present and pull.
                        Button { showScanner = true } label: {
                            Label("Scan customer voucher", systemImage: "qrcode.viewfinder")
                        }
                        .font(.caption)
                    } else {
                        Text(request.address)
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Receive payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark received") { onResolve(nil, bolt11, nowSec()) }
                }
            }
            .task { await run() }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    VStack(spacing: 12) {
                        QRScannerView(onCode: { code in
                            showScanner = false
                            Task { await handleWithdraw(code) }
                        })
                        QRPhotoPickerButton(onCode: { code in
                            showScanner = false
                            Task { await handleWithdraw(code) }
                        }) {
                            Label("Choose photo", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 12)
                    }
                    .navigationTitle("Scan voucher")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
                }
            }
        }
    }

    @ViewBuilder
    private var qrView: some View {
        if let payload = qrPayload, let img = BadgeQR.render(Data(payload.utf8), scale: 8) {
            ZStack {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                // Coin ticker (or a Lightning bolt) badged in the centre; QR
                // error correction tolerates the small occlusion.
                Group {
                    if request.isLightning {
                        Image(systemName: "bolt.fill").font(.caption)
                    } else {
                        Text(request.ticker).font(.caption2.weight(.bold))
                    }
                }
                .padding(6)
                .background(.background, in: Circle())
                .overlay(Circle().stroke(.purple, lineWidth: 2))
            }
        } else if request.isLightning, let err = lnError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.red)
                Text(err).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, minHeight: 160)
        } else if request.isLightning {
            VStack(spacing: 8) { ProgressView(); Text("Creating invoice…").font(.caption2).foregroundStyle(.secondary) }
                .frame(maxWidth: 260, maxHeight: 260)
        } else {
            Text("Could not render QR").foregroundStyle(.red)
        }
    }

    // MARK: -- flow

    /// Lightning: create the invoice first, then watch for settlement.
    /// On-chain: just watch the receiving address.
    private func run() async {
        if request.isLightning {
            guard await createInvoice() else { return }
        }
        await watch()
    }

    /// Create a BOLT11 invoice on the chosen (or active) Lightning account.
    private func createInvoice() async -> Bool {
        guard let account = lightningAccount,
              let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
            watching = false
            lnError = "No Lightning account. Add one in Maknoon, then retry."
            status = lnError!
            return false
        }
        let sats = (request.amount as NSDecimalNumber).int64Value
        do {
            let pr = try await LNDHubClient(account: account, password: pw).addInvoice(amountSat: sats, memo: request.appTitle)
            bolt11 = pr
            status = "Waiting for payment to \(account.label)…"
            return true
        } catch {
            watching = false
            lnError = "Could not create invoice on \(account.label): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            status = lnError!
            return false
        }
    }

    /// Pull funds from a customer-presented LNURL-withdraw voucher: decode it,
    /// create an invoice for the sale amount on the chosen account, and submit
    /// it to the voucher callback. The running balance watcher confirms receipt.
    private func handleWithdraw(_ scanned: String) async {
        guard let account = lightningAccount,
              let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
            lnError = "No Lightning account to receive into."; status = lnError!; return
        }
        let sats = (request.amount as NSDecimalNumber).int64Value
        do {
            let url = try LNURL.decode(scanned)
            let w = try await LNURL.fetchWithdrawRequest(url)
            let msat = sats * 1000
            guard msat >= w.minWithdrawable && msat <= w.maxWithdrawable else {
                lnError = "Voucher allows \(w.minWithdrawable / 1000)-\(w.maxWithdrawable / 1000) sat, need \(sats)."
                status = lnError!; return
            }
            let client = LNDHubClient(account: account, password: pw)
            let invoice = try await client.addInvoice(amountSat: sats, memo: request.appTitle)
            try await LNURL.submitWithdraw(w, bolt11: invoice)
            status = "Voucher accepted, waiting for settlement to \(account.label)…"
            // The balance watcher (already running) resolves on receipt.
        } catch {
            lnError = "Could not pull from voucher: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            status = lnError!
        }
    }

    // MARK: -- balance-delta watch (on-chain + lightning)

    private func watch() async {
        // Snapshot the starting balance, then poll for an increase of >= amount.
        baseline = try? await PaymentWatcher.balance(
            chain: request.chain, networkRaw: request.networkRaw,
            address: request.address, store: store)
        var ticks = 0
        while watching && ticks < 240 {   // ~20 min at 5s
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            ticks += 1
            guard watching else { return }
            guard let now = try? await PaymentWatcher.balance(
                chain: request.chain, networkRaw: request.networkRaw,
                address: request.address, store: store) else { continue }
            let base = baseline ?? now
            if now - base >= request.amount {
                watching = false
                status = "Payment received"
                onResolve(nil, bolt11, nowSec())
                return
            }
        }
    }

    private func nowSec() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

/// Reads an address's native-coin balance (in whole units) per chain, for
/// balance-delta payment detection. Best-effort; returns nil on error.
enum PaymentWatcher {
    @MainActor
    static func balance(chain: String, networkRaw: String?, address: String, store: HolderStore) async throws -> Decimal? {
        switch chain.lowercased() {
        case "ethereum", "evm", "eth":
            let net = networkRaw.flatMap { EthereumNetwork(rawValue: $0) } ?? .mainnet
            guard let rpc = EthereumRPCClient(urlString: store.ethereumSettings.rpcURL(for: net)) else { return nil }
            let wei = try await rpc.getBalance(address)
            return scale(wei.decimal, by: -18)
        case "solana", "sol":
            let net = networkRaw.flatMap { SolanaNetwork(rawValue: $0) } ?? .mainnet
            guard let rpc = SolanaRPCClient(urlString: store.solanaSettings.rpcURL(for: net)) else { return nil }
            let lamports = try await rpc.getBalance(address: address)
            return scale(Decimal(lamports), by: -9)
        case "tron", "trx":
            let net = networkRaw.flatMap { TronNetwork(rawValue: $0) } ?? .mainnet
            guard let rpc = TronRPCClient(baseString: store.tronSettings.rpcURL(for: net)) else { return nil }
            let sun = try await rpc.getBalance(addressBase58: address)
            return scale(Decimal(sun), by: -6)
        case "bitcoin", "btc":
            let net = networkRaw.flatMap { BitcoinNetwork(rawValue: $0) } ?? .mainnet
            let sats = try await bitcoinSats(base: store.bitcoinSettings.mempoolURL(for: net), address: address)
            return scale(Decimal(sats), by: -8)
        case "lightning", "ln":
            // Settlement = the chosen Lightning account's balance rising (the
            // account UUID is passed via `address`; empty ⇒ active). The
            // lightning `amount` is already in sats, so return raw sats here.
            let chosen: LightningAccount?
            if let id = UUID(uuidString: address),
               let a = store.lightningAccountStore.accounts.first(where: { $0.id == id }) {
                chosen = a
            } else {
                chosen = store.lightningAccountStore.activeAccount
            }
            guard let account = chosen,
                  let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else { return nil }
            let sats = try await LNDHubClient(account: account, password: pw).balanceSat()
            return Decimal(sats)
        default:
            return nil
        }
    }

    private static func scale(_ d: Decimal, by exponent: Int) -> Decimal {
        d * Decimal(sign: .plus, exponent: exponent, significand: 1)
    }

    /// mempool.space / Esplora address balance (confirmed + mempool), sats.
    private static func bitcoinSats(base: String, address: String) async throws -> Int64 {
        guard let url = URL(string: "\(base)/api/address/\(address)") else { return 0 }
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Stats: Decodable { let funded_txo_sum: Int64; let spent_txo_sum: Int64 }
        struct Resp: Decodable { let chain_stats: Stats; let mempool_stats: Stats }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return (r.chain_stats.funded_txo_sum - r.chain_stats.spent_txo_sum)
            + (r.mempool_stats.funded_txo_sum - r.mempool_stats.spent_txo_sum)
    }
}
