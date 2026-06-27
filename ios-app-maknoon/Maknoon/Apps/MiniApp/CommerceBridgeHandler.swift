// window.maknoon.commerce.collectAndCharge: the unified verify-and-pay bridge
// (ADR-0031). One call replaces the POS's separate identity.collect +
// payment.receive: it builds + signs a CommerceRequest from the app's params,
// opens the native merchant sheet (engage holder, verify offline, broadcast), and
// returns a single verdict { decision, reason, missing, message, disclosed, txHash }.

import Foundation

@MainActor
final class CommerceBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "commerce"
    let requiredPermission: String? = "wallet"

    private let store: HolderStore
    private let appTitle: String
    private let installedAppId: String
    private let coordinator: MiniAppCommerceCoordinator

    init(store: HolderStore, appTitle: String, installedAppId: String, coordinator: MiniAppCommerceCoordinator) {
        self.store = store
        self.appTitle = appTitle
        self.installedAppId = installedAppId
        self.coordinator = coordinator
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "collectAndCharge":
            return try await collectAndCharge(params)
        default:
            throw MiniAppBridgeError.unsupported("commerce.\(method)")
        }
    }

    private func collectAndCharge(_ params: Any?) async throws -> [String: Any] {
        guard let p = params as? [String: Any] else {
            throw MiniAppBridgeError.invalidParams("commerce.collectAndCharge expects an object")
        }
        let identity = p["identity"] as? [String: Any] ?? [:]
        let payment = p["payment"] as? [String: Any] ?? [:]
        let rails = Self.parseRails(payment["acceptedRails"])
        guard !rails.isEmpty else {
            throw MiniAppBridgeError.invalidParams("payment.acceptedRails is required")
        }
        let lane = CommerceLane(rawValue: (p["lane"] as? String) ?? "full") ?? .full

        // Lightning is invoice-based: a "lightning" rail arrives carrying the
        // merchant's Lightning ACCOUNT id (not a payable destination). Mint a
        // fresh BOLT11 for the amount on that account here, on the merchant
        // device, so the holder pays a real invoice. Other chains pass through
        // untouched.
        let resolvedRails = try await Self.mintLightningInvoices(
            rails, store: store,
            memo: (p["merchantName"] as? String) ?? appTitle)

        let built = try await CommerceRequestFactory.build(
            store: store,
            installedAppId: installedAppId,
            merchantName: (p["merchantName"] as? String) ?? appTitle,
            schema: identity["schema"] as? String,
            requiredClaims: (identity["requiredClaims"] as? [String]) ?? [],
            issuers: identity["issuers"] as? [String],
            identityMaxAgeSec: (identity["maxAgeSec"] as? NSNumber)?.int64Value,
            fiatAmount: (payment["fiatAmount"] as? String) ?? "0",
            fiatCode: (payment["fiatCode"] as? String) ?? "USD",
            acceptedRails: resolvedRails,
            reference: payment["reference"] as? String,
            floorMinor: (payment["floorMinor"] as? NSNumber)?.int64Value,
            lane: lane)

        return try await coordinator.present(.init(
            appTitle: appTitle, installedAppId: installedAppId,
            commerce: built.request, responseKeypair: built.responseKeypair))
    }

    /// Replace each Lightning rail's account-id address with a freshly-minted
    /// BOLT11 invoice for the amount, generated on the merchant's own Lightning
    /// account (LNDHub addinvoice). Non-lightning rails pass through unchanged.
    private static func mintLightningInvoices(
        _ rails: [PaymentRail], store: HolderStore, memo: String
    ) async throws -> [PaymentRail] {
        var out: [PaymentRail] = []
        for rail in rails {
            guard rail.chain == "lightning" else { out.append(rail); continue }
            // Lightning rail amounts are in SATOSHIS (integer), not BTC, the PoS
            // sends sats for the Lightning leg. (Treating it as BTC here would
            // 100,000,000x the invoice and the provider rejects it.)
            guard let amount = rail.amount, let satsD = Double(amount), satsD > 0 else {
                throw MiniAppBridgeError.invalidParams("Lightning rail needs a positive satoshi amount.")
            }
            let sats = Int64(satsD.rounded())
            // rail.address carries the merchant's Lightning account id.
            guard let accountId = UUID(uuidString: rail.address),
                  let account = store.lightningAccountStore.accounts.first(where: { $0.id == accountId })
            else {
                throw MiniAppBridgeError.invalidParams("Select a Lightning account to receive into.")
            }
            guard let pw = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
                throw MiniAppBridgeError.invalidParams("Re-import the merchant Lightning account (no stored password).")
            }
            let client = LNDHubClient(account: account, password: pw)
            let bolt11 = try await client.addInvoice(amountSat: Int64(sats), memo: memo)
            out.append(PaymentRail(
                chain: rail.chain, network: rail.network, asset: rail.asset,
                address: bolt11, amount: rail.amount,
                assetContract: rail.assetContract, assetDecimals: rail.assetDecimals, rpcURL: rail.rpcURL))
        }
        return out
    }

    private static func parseRails(_ any: Any?) -> [PaymentRail] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.map { d in
            PaymentRail(
                chain: d["chain"] as? String ?? "",
                network: d["network"] as? String,
                asset: d["asset"] as? String ?? "",
                address: d["address"] as? String ?? "",
                amount: d["amount"] as? String,
                assetContract: d["assetContract"] as? String,
                assetDecimals: (d["assetDecimals"] as? NSNumber)?.intValue,
                rpcURL: d["rpcURL"] as? String)
        }
    }
}
