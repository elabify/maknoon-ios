// window.maknoon.merchant: lets a merchant app (the POS) render its OWN
// self-contained settings: its verifier identity + verification status + its
// receipts. Everything is scoped to this installation (installedAppId), so one
// app can never read another's merchant data.
//
//   merchant.getIdentity() -> { did, publicKey, verified }
//       Provisions the per-install verifier key on first call. `verified` is a
//       live lookup against the curated verifier registry (true once Elabify
//       has registered this DID). The app shows the DID + key for the merchant
//       to send to sales@elabify.com.
//
// (Receipts + the rest of the merchant's settings are the app's own, kept via
// window.maknoon.storage; only the verifier key is native.)

import Foundation

@MainActor
final class MerchantBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "merchant"
    let requiredPermission: String? = nil   // scoped per-install; no extra grant

    private let store: HolderStore
    private let installedAppId: String
    private let verifierBase = HolderStore.elabifyDropHost

    init(store: HolderStore, installedAppId: String) {
        self.store = store
        self.installedAppId = installedAppId
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "merchant.getIdentity":
            let did = try store.merchantIdentity.ensureProvisioned(installedAppId)
            let pub = store.merchantIdentity.publicKeyHex(installedAppId) ?? ""
            let verified = await VerifierRegistryClient.lookup(host: verifierBase, did: did) != nil
            return ["did": did, "publicKey": pub, "verified": verified]
        default:
            throw MiniAppBridgeError.unsupported("merchant.\(method)")
        }
    }
}
