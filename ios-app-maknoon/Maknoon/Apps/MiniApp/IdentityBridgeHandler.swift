// "maknoon" namespace handler (window.maknoon.identity).
//
// identity.request({ schemas?, issuers?, requiredClaims, maxAgeSec?,
//   purpose? }) drives the full holder->verifier loop, on-device:
//   1. build a VerifierFilter and run MatchingEngine over the wallet;
//   2. if nothing matches, return DENY/no_matching_credential with no UI;
//   3. otherwise present the approval sheet (pick + Face ID consent);
//   4. fetch a server challenge (/v1/challenge), sign a Presentation via
//      the shared PresentationFactory, and submit it to /v1/verify;
//   5. return the server's authoritative verdict { decision, reason,
//      checks, disclosed } to JS, recording the disclosure in history.
//
// The verdict is computed by the verifier server, never asserted by the
// mini app: even though the POS demo collapses merchant and holder onto
// one device, the GRANT/DENY (including the sanctions-freshness gate) is
// the server's, not the page's. If the server is unreachable we fall back
// to a clearly-flagged offline local check.

import Foundation
import ElabifyCore

@MainActor
final class IdentityBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "maknoon"
    let requiredPermission: String? = "identity"

    private let store: HolderStore
    private let appTitle: String
    private let installedAppId: String
    private let coordinator: MiniAppIdentityCoordinator
    private let collectCoordinator: MiniAppCollectCoordinator

    /// Verifier server the bridge issues challenges to and verifies
    /// against. Reuses the host the rest of the app already trusts.
    private let verifierBase = HolderStore.elabifyDropHost

    init(store: HolderStore, appTitle: String, installedAppId: String,
         coordinator: MiniAppIdentityCoordinator,
         collectCoordinator: MiniAppCollectCoordinator) {
        self.store = store
        self.appTitle = appTitle
        self.installedAppId = installedAppId
        self.coordinator = coordinator
        self.collectCoordinator = collectCoordinator
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "identity.getDID":
            guard let did = store.sandwich?.holderDID else {
                throw MiniAppBridgeError.unauthorized("wallet is locked")
            }
            return ["did": did]
        case "identity.request":
            return try await requestPresentation(params: params)
        case "identity.collect":
            return try await collect(params: params)
        default:
            throw MiniAppBridgeError.unsupported("maknoon.\(method)")
        }
    }

    /// Cross-device: scan + verify a *separate* customer's presentation.
    private func collect(params: Any?) async throws -> [String: Any] {
        let opts = params as? [String: Any] ?? [:]
        let requiredClaims = (opts["requiredClaims"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !requiredClaims.isEmpty else {
            throw MiniAppBridgeError.invalidParams("identity.collect requires requiredClaims")
        }
        let schema = opts["schema"] as? String
        let maxAgeSec = (opts["maxAgeSec"] as? NSNumber)?.int64Value

        // Best-effort: host a signed VerifierRequest so the sheet can show a
        // QR the customer scans directly (vs only the merchant scanning them).
        // If anything fails (locked wallet, offline), the sheet still works as
        // a plain scanner.
        let requestURL = try? await hostVerifierRequest(
            schema: schema, requiredClaims: requiredClaims)
        // requestId is the last path component of /v1/verifier-request/<id>;
        // the sheet polls /v1/verify/result/<id> for the holder's verdict.
        let requestId = requestURL.flatMap { URL(string: $0)?.lastPathComponent }

        let req = MiniAppCollectCoordinator.Request(
            appTitle: appTitle,
            purpose: opts["purpose"] as? String,
            schema: schema,
            requiredClaims: requiredClaims,
            maxAgeSec: maxAgeSec,
            requestURL: requestURL,
            requestId: requestId
        )
        return try await collectCoordinator.present(req)
    }

    /// Build a self-signed VerifierRequest (signed with the holder's ephemeral
    /// identity key), POST it to /v1/verifier-request, and return the short
    /// GET URL to encode as a QR. The customer's wallet scans the URL,
    /// validates the self-signed request, and presents against it.
    private func hostVerifierRequest(schema: String?, requiredClaims: [String]) async throws -> String? {
        // Stable merchant identity (provisioned on first use), NOT the holder's
        // consumer identity, so the customer's wallet resolves a consistent
        // DID -> pubkey and can show "Verified: <Merchant>" once registered.
        let merchantDid = try store.merchantIdentity.ensureProvisioned(installedAppId)
        guard let merchantPkHex = store.merchantIdentity.publicKeyHex(installedAppId) else { return nil }

        let ch = try await VerifierClient.challenge(verifierBase: verifierBase, requestedClaims: requiredClaims)
        let filter = VerifierFilter(
            issuers: nil,
            schemas: schema.map { VerifierFilterClause(mode: "allow", list: [$0]) },
            requiredClaims: requiredClaims
        )
        // Server-mediated delivery: the holder POSTs its Presentation to the
        // verifier server, which verifies + stashes the verdict keyed by
        // requestId for the merchant to poll (GET /v1/verify/result/:requestId).
        let callbackUrl = verifierBase.appendingPathComponent("/v1/verify/callback").absoluteString
        let response = VerifierResponseDirective(mode: "callback", callbackUrl: callbackUrl)

        // Omit the inline pubkey ONLY when this merchant DID is registered, so
        // the holder resolves it from the registry (green "Verified" tier). If
        // unconfirmed/offline, inline it (orange self-signed) — never omit an
        // unregistered key, or the holder rejects the request as unknown.
        let registered = await VerifierRegistryClient.lookup(host: verifierBase, did: merchantDid) != nil
        let inlinePk: HexString? = registered ? nil : merchantPkHex

        func make(signature: HexString?) -> VerifierRequest {
            VerifierRequest(
                v: 1, verifierDid: merchantDid, verifierName: appTitle,
                verifierPublicKey: inlinePk, requestId: ch.requestId,
                issuedAt: ch.issuedAt, expiresAt: ch.expiresAt, challenge: ch.challenge,
                filter: filter, response: response, signature: signature)
        }

        // Canonicalize WITHOUT the signature, byte-identical to the validator.
        let unsigned = make(signature: nil)
        let raw = try JSONEncoder().encode(unsigned)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        obj.removeValue(forKey: "signature")
        let msg = try canonicalize(obj)
        let sig = try store.merchantIdentity.sign(installedAppId, msg)
        let sigHex = "0x" + sig.map { String(format: "%02x", $0) }.joined()

        // POST the signed request to the verifier-request store.
        let signed = make(signature: sigHex)
        var post = URLRequest(url: verifierBase.appendingPathComponent("/v1/verifier-request"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONEncoder().encode(["request": signed])
        let (_, resp) = try await URLSession.shared.data(for: post)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }

        return verifierBase.appendingPathComponent("/v1/verifier-request/\(ch.requestId)").absoluteString
    }

    // MARK: -- identity.request

    private func requestPresentation(params: Any?) async throws -> [String: Any] {
        guard let opts = params as? [String: Any] else {
            throw MiniAppBridgeError.invalidParams("expected an options object")
        }
        let requiredClaims = (opts["requiredClaims"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !requiredClaims.isEmpty else {
            throw MiniAppBridgeError.invalidParams("requiredClaims must be a non-empty array")
        }
        let schemas = (opts["schemas"] as? [Any])?.compactMap { $0 as? String }
        let issuers = (opts["issuers"] as? [Any])?.compactMap { $0 as? String }
        let purpose = opts["purpose"] as? String
        let maxAgeSec: Int64? = (opts["maxAgeSec"] as? NSNumber)?.int64Value

        guard store.sandwich != nil else {
            throw MiniAppBridgeError.unauthorized("wallet is locked")
        }

        let filter = VerifierFilter(
            issuers: issuers.map { VerifierFilterClause(mode: "allow", list: $0) },
            schemas: schemas.map { VerifierFilterClause(mode: "allow", list: $0) },
            requiredClaims: requiredClaims
        )
        let matches = MatchingEngine.match(credentials: store.credentials, filter: filter)
        guard !matches.isEmpty else {
            LogStore.shared.info("MiniApp", "identity.request: no matching credential for \(appTitle)")
            return [
                "decision": "DENY",
                "reason": "no_matching_credential",
                "checks": [String: Any](),
                "disclosed": [String: Any](),
            ]
        }

        // User consent: pick a credential + Face ID. Throws userRejected
        // if they decline (propagates to the JS promise as a 4001).
        let chosen = try await coordinator.present(
            appTitle: appTitle,
            purpose: purpose,
            requiredClaims: requiredClaims,
            maxAgeSec: maxAgeSec,
            matches: matches
        )

        // Server-issued challenge -> signed presentation -> server verify.
        let ch = try await VerifierClient.challenge(verifierBase: verifierBase, requestedClaims: requiredClaims)
        let presentation = try await PresentationFactory.build(
            credential: chosen,
            selectedClaims: Set(requiredClaims),
            challenge: ch.challenge,
            verifierDid: "did:elabify:open",
            pendingRequest: nil,
            store: store
        )
        let verifyReq = VerifyRequest(
            v: 1,
            challengeContext: ChallengeContext(requestId: ch.requestId, issuedAt: ch.issuedAt, expiresAt: ch.expiresAt),
            presentation: presentation
        )

        do {
            let resp = try await VerifierClient.verify(verifierBase: verifierBase, request: verifyReq)
            VerifierHistory.record(
                verifierDid: "did:elabify:open",
                verifierName: appTitle,
                label: appTitle,
                credentialId: chosen.header.cid,
                credentialSchema: chosen.header.schema,
                disclosedKeys: requiredClaims
            )
            LogStore.shared.info("MiniApp", "identity.request: server decision \(resp.decision) for \(appTitle)")
            return [
                "decision": resp.decision,
                "reason": resp.reason,
                "checks": mapChecks(resp.checks),
                "disclosed": mapDisclosed(resp.disclosed),
                "requestId": ch.requestId,
                "offline": false,
            ]
        } catch {
            // Server unreachable: fall back to an offline local check,
            // clearly flagged so the mini app can decide how much to trust.
            LogStore.shared.warn("MiniApp", "identity.request: verify failed, offline fallback: \(error.localizedDescription)")
            let local = PresentationVerifier.verifyOffline(presentation)
            return [
                "decision": local.decision,
                "reason": "offline_local_verify",
                "checks": ["overallPass": local.checks.overallPass],
                "disclosed": mapDisclosed(local.disclosed),
                "requestId": ch.requestId,
                "offline": true,
            ]
        }
    }

    // MARK: -- JSON shaping

    private func mapChecks(_ checks: [String: JSONValue?]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in checks { out[k] = v?.anyValue ?? NSNull() }
        return out
    }

    private func mapDisclosed(_ disclosed: [String: JSONValue]?) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in (disclosed ?? [:]) { out[k] = v.anyValue }
        return out
    }
}
