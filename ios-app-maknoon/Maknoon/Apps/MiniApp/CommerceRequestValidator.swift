// Holder-side authentication of a CommerceRequest (ADR-0031). Two checks:
//   1. The embedded VerifierRequest's signature (reusing VerifierRequestValidator)
//      — authenticates the merchant identity + the integrity of the ask, and
//      yields the trust tier (registered / self-signed / unknown).
//   2. `merchantSig` over `paymentTerms` against the same verifier pubkey — so a
//      relay/server cannot tamper with the payment terms or, crucially, swap the
//      `responseKey` the holder seals its response to. Without this, a malicious
//      relay could substitute its own key and read the response (defeating
//      server-blindness). With it, server-blindness holds against an active server.

import Foundation
import ElabifyCore

enum CommerceRequestValidator {
    /// Coarse trust tier for UI styling (color/icon), distinct from `ok` which
    /// is purely "did the signatures verify". A self-signed merchant can be
    /// `ok` yet must NOT render as the green "verified" tier.
    enum Tier { case registered, selfSigned, unknown }

    struct Result {
        let ok: Bool
        let tier: Tier
        let tierLabel: String
        let reason: String?
    }

    static func validate(_ request: CommerceRequest, registryHost: URL,
                         nowSec: Int64 = Int64(Date().timeIntervalSince1970)) async -> Result {
        // 1. Authenticate the verifier request (signature + expiry + trust tier).
        guard let vrData = try? JSONEncoder().encode(request.verifierRequest),
              let vrJSON = String(data: vrData, encoding: .utf8) else {
            return Result(ok: false, tier: .unknown, tierLabel: "Unverified", reason: "Malformed request.")
        }
        guard let decision = await VerifierRequestValidator.validate(
                scannedJsonString: vrJSON, registryHost: registryHost, nowSec: nowSec),
              decision.isValid else {
            return Result(ok: false, tier: .unknown, tierLabel: "Unverified",
                          reason: "The merchant request signature is invalid or expired.")
        }
        let tier: Tier
        let tierLabel: String
        switch decision.tier {
        case .registered(let name): tier = .registered; tierLabel = "Verified: \(name)"
        case .selfSigned:           tier = .selfSigned; tierLabel = "Self-signed merchant"
        case .unknown:              tier = .unknown;    tierLabel = "Unverified merchant"
        }

        // 2. Verify merchantSig over paymentTerms against the verifier pubkey.
        // Use the inline pubkey (self-signed) or, for a registered merchant that
        // omits it, resolve the pubkey from the registry — same source the
        // verifierRequest tier check above used.
        let resolvedPubHex: String?
        if let inline = request.verifierRequest.verifierPublicKey {
            resolvedPubHex = inline
        } else {
            resolvedPubHex = await VerifierRegistryClient.lookup(
                host: registryHost, did: request.verifierRequest.verifierDid)?.verifierPublicKey
        }
        guard let pubHex = resolvedPubHex, let pub = Self.hex(pubHex),
              let sigHex = request.merchantSig, let sig = Self.hex(sigHex) else {
            return Result(ok: false, tier: tier, tierLabel: tierLabel, reason: "Missing the merchant's payment signature.")
        }
        do {
            let raw = try JSONEncoder().encode(request.paymentTerms)
            guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                return Result(ok: false, tier: tier, tierLabel: tierLabel, reason: "Could not read the payment terms.")
            }
            obj.removeValue(forKey: "signature")
            let msg = try canonicalize(obj)
            let valid = MLDSAClient.verify(publicKey: pub, signature: sig, message: msg)
            return Result(ok: valid, tier: tier, tierLabel: tierLabel,
                          reason: valid ? nil : "The merchant's payment signature does not verify (possible tampering).")
        } catch {
            return Result(ok: false, tier: tier, tierLabel: tierLabel, reason: "Could not verify the payment terms.")
        }
    }

    private static func hex(_ s: String) -> Data? {
        let h = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard h.count % 2 == 0 else { return nil }
        var d = Data(); var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }
}
