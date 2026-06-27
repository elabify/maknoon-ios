// "payment" namespace handler (window.maknoon.payment.receive).
//
// receive({ chain, network, address, amount, fiatText? }) opens a native
// sheet that shows a per-chain payment-request QR (PaymentURI) with the
// crypto + fiat totals, watches the receiving address on-chain, and
// resolves when the incoming transfer lands. The merchant receives funds
// directly to their own (address-book) address; nothing is signed here.
//
// Returns { txHash|null, chain, network, amount, confirmedAt } to the app.

import Foundation

@MainActor
final class PaymentBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "payment"
    let requiredPermission: String? = "wallet"

    private let store: HolderStore
    private let appTitle: String
    private let coordinator: MiniAppPaymentCoordinator

    init(store: HolderStore, appTitle: String, coordinator: MiniAppPaymentCoordinator) {
        self.store = store
        self.appTitle = appTitle
        self.coordinator = coordinator
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "payment.lightningAccounts":
            // List the user's Lightning accounts so the app can offer a picker.
            return store.lightningAccountStore.accounts.map {
                ["id": $0.id.uuidString, "label": $0.label]
            }
        case "payment.receive":
            break
        default:
            throw MiniAppBridgeError.unsupported("payment.\(method)")
        }
        guard let p = params as? [String: Any],
              let chain = (p["chain"] as? String)?.lowercased() else {
            throw MiniAppBridgeError.invalidParams("payment.receive requires { chain, amount }")
        }
        // Lightning receives into a chosen Lightning account (its UUID passed as
        // `account`; empty falls back to the active one) and needs no address;
        // every on-chain chain requires an address.
        let isLightning = (chain == "lightning" || chain == "ln")
        let address = isLightning ? (p["account"] as? String ?? "") : (p["address"] as? String ?? "")
        guard isLightning || !address.isEmpty else {
            throw MiniAppBridgeError.invalidParams("payment.receive requires `address`")
        }
        let networkRaw = p["network"] as? String
        let fiatText = p["fiatText"] as? String
        // amount in the chain's native unit (decimal string).
        let amountStr = (p["amount"] as? String) ?? (p["amount"] as? NSNumber)?.stringValue ?? "0"
        guard let amount = Decimal(string: amountStr), amount > 0 else {
            throw MiniAppBridgeError.invalidParams("payment.receive requires a positive `amount`")
        }

        let built = try Self.build(chain: chain, networkRaw: networkRaw, address: address,
                                   amount: amount, fiatText: fiatText, appTitle: appTitle)
        return try await coordinator.present(built)
    }

    /// Resolve chain + network into a ready-to-render payment request. Pure
    /// (no store access) so it's unit-testable.
    nonisolated static func build(
        chain: String, networkRaw: String?, address: String,
        amount: Decimal, fiatText: String?, appTitle: String
    ) throws -> MiniAppPaymentCoordinator.Request {
        // Lightning: no address/URI here, the sheet creates a BOLT11 invoice
        // on the active account. `amount` is in sats.
        if chain == "lightning" || chain == "ln" {
            // `address` carries the chosen Lightning account UUID (empty ⇒ active).
            return MiniAppPaymentCoordinator.Request(
                appTitle: appTitle, chain: "lightning", networkRaw: networkRaw,
                networkDisplay: "Bitcoin Lightning", address: address, amount: amount,
                ticker: "sats", uri: "", fiatText: fiatText, isLightning: true)
        }

        let uri: String
        let ticker: String
        let networkDisplay: String

        switch chain {
        case "ethereum", "evm", "eth":
            let net = networkRaw.flatMap { EthereumNetwork(rawValue: $0) } ?? .mainnet
            ticker = net.ticker
            networkDisplay = net.displayName
            uri = PaymentURI.ethereum(address: address, chainId: net.chainId, weiValue: weiString(amount)).string
        case "bitcoin", "btc":
            let net = networkRaw.flatMap { BitcoinNetwork(rawValue: $0) } ?? .mainnet
            ticker = net.ticker
            networkDisplay = net.displayName
            uri = PaymentURI.bitcoin(address: address, btc: amount).string
        case "solana", "sol":
            let net = networkRaw.flatMap { SolanaNetwork(rawValue: $0) } ?? .mainnet
            ticker = "SOL"
            networkDisplay = net.displayName
            uri = PaymentURI.solana(address: address, sol: amount).string
        case "tron", "trx":
            let net = networkRaw.flatMap { TronNetwork(rawValue: $0) } ?? .mainnet
            ticker = "TRX"
            networkDisplay = net.displayName
            uri = PaymentURI.tron(address: address, trx: amount).string
        default:
            throw MiniAppBridgeError.invalidParams("unknown chain '\(chain)'")
        }

        return MiniAppPaymentCoordinator.Request(
            appTitle: appTitle, chain: chain, networkRaw: networkRaw,
            networkDisplay: networkDisplay, address: address, amount: amount,
            ticker: ticker, uri: uri, fiatText: fiatText
        )
    }

    /// Decimal ETH → integer wei string for EIP-681.
    nonisolated private static func weiString(_ eth: Decimal) -> String {
        var v = eth * Decimal(sign: .plus, exponent: 18, significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 0, .down)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
