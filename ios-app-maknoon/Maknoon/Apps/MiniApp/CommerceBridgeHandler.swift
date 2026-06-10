// window.maknoon.commerce.collectAndCharge — the unified verify-and-pay bridge
// (ADR-0031). One call replaces the POS's separate identity.collect +
// payment.receive: it builds + signs a CommerceRequest from the dApp's params,
// opens the native merchant sheet (engage holder, verify offline, broadcast), and
// returns a single verdict { decision, reason, missing, message, disclosed, txHash }.

import Foundation

@MainActor
final class CommerceBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "commerce"
    let requiredPermission: String? = "payment"

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
            acceptedRails: rails,
            reference: payment["reference"] as? String,
            floorMinor: (payment["floorMinor"] as? NSNumber)?.int64Value,
            lane: lane)

        return try await coordinator.present(.init(
            appTitle: appTitle, commerce: built.request, responseKeypair: built.responseKeypair))
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
