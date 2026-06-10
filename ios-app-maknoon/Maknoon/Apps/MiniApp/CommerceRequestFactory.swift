// Builds + signs a CommerceRequest entirely on-device, no server (ADR-0031).
// Mirrors IdentityBridgeHandler.hostVerifierRequest's self-signed request signing
// but generates the challenge + requestId locally (serverless), and adds a
// merchantSig over the payment terms. The holder validates the verifierRequest via
// VerifierRequestValidator's self-signed tier (inline pubkey + signature).

import Foundation
import ElabifyCore

enum CommerceRequestFactory {
    enum Failure: LocalizedError {
        case identityUnavailable
        var errorDescription: String? { "Unlock your identity to issue a charge." }
    }

    @MainActor
    static func build(
        store: HolderStore,
        installedAppId: String,
        merchantName: String,
        schema: String?,
        requiredClaims: [String],
        issuers: [String]?,
        identityMaxAgeSec: Int64?,
        fiatAmount: String,
        fiatCode: String,
        acceptedRails: [PaymentRail],
        reference: String?,
        floorMinor: Int64?,
        lane: CommerceLane,
        ttlSec: Int64 = 300
    ) async throws -> (request: CommerceRequest, responseKeypair: TransportHolder) {
        // Stable merchant identity (provisioned on first use), NOT the holder's
        // consumer identity, so the customer's wallet shows a consistent merchant.
        let merchantDid = try store.merchantIdentity.ensureProvisioned(installedAppId)
        guard let merchantPkHex = store.merchantIdentity.publicKeyHex(installedAppId) else {
            throw Failure.identityUnavailable
        }
        let now = Int64(Date().timeIntervalSince1970)
        let filter = VerifierFilter(
            issuers: issuers.map { VerifierFilterClause(mode: "allow", list: $0) },
            schemas: schema.map { VerifierFilterClause(mode: "allow", list: [$0]) },
            requiredClaims: requiredClaims)
        let response = VerifierResponseDirective(mode: "qrBack", callbackUrl: nil)

        // Omit the inline pubkey only when this merchant DID is registered (→
        // green "Verified" tier); else inline it (self-signed). Never omit an
        // unregistered key, or the holder rejects the request as unknown.
        let registered = await VerifierRegistryClient.lookup(host: HolderStore.elabifyDropHost, did: merchantDid) != nil
        let inlinePk: HexString? = registered ? nil : merchantPkHex

        func make(_ sig: String?) -> VerifierRequest {
            VerifierRequest(
                v: 1, verifierDid: merchantDid, verifierName: merchantName,
                verifierPublicKey: inlinePk, requestId: UUID().uuidString,
                issuedAt: now, expiresAt: now + ttlSec, challenge: "0x" + randomHex(32),
                filter: filter, response: response, signature: sig)
        }
        // Build the unsigned request ONCE, then sign that exact value (a fresh
        // make() would re-randomize challenge/requestId).
        let unsigned = make(nil)
        let vrSig = try sign(unsigned, store: store, installedAppId: installedAppId)
        let verifierRequest = VerifierRequest(
            v: unsigned.v, verifierDid: unsigned.verifierDid, verifierName: unsigned.verifierName,
            verifierPublicKey: unsigned.verifierPublicKey, requestId: unsigned.requestId,
            issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt, challenge: unsigned.challenge,
            filter: unsigned.filter, response: unsigned.response, signature: vrSig)

        // Ephemeral keypair the holder seals its response to (server stays
        // blind). The public key rides in the signed paymentTerms; the private
        // key stays on the merchant device to decrypt the polled response.
        let responseKeypair = try TransportHolder()
        let terms = PaymentTerms(
            fiatAmount: fiatAmount, fiatCode: fiatCode, acceptedRails: acceptedRails,
            reference: reference, nonce: "0x" + randomHex(16),
            floorMinor: floorMinor, expiresAt: now + ttlSec,
            responseKey: responseKeypair.publicKeyBase64)
        let termsSig = try sign(terms, store: store, installedAppId: installedAppId)

        let request = CommerceRequest(
            v: 1, verifierRequest: verifierRequest, paymentTerms: terms, lane: lane,
            merchantName: merchantName, identityMaxAgeSec: identityMaxAgeSec, merchantSig: termsSig)
        return (request, responseKeypair)
    }

    /// Canonicalize an Encodable (signature field dropped) and ML-DSA-sign it
    /// with the device identity key, returning 0x-hex. Byte-identical to the
    /// holder-side validator's canonicalization.
    private static func sign<T: Encodable>(_ value: T, store: HolderStore, installedAppId: String) throws -> String {
        let raw = try JSONEncoder().encode(value)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw Failure.identityUnavailable
        }
        obj.removeValue(forKey: "signature")
        let sig = try store.merchantIdentity.sign(installedAppId, try canonicalize(obj))
        return "0x" + sig.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(_ count: Int) -> String {
        var b = Data(count: count)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
