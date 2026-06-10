// Merchant-side accept decision for a holder's CommerceResponse (ADR-0031).
// Cryptography is delegated to the shared PresentationVerifier; this layer adds
// the commerce policy: the response is bound to the request (nonce), the
// presented credential satisfies the identity ask (schema / required claims /
// freshness), and the chosen payment rail is one the merchant published.

import Foundation

struct CommerceAcceptResult {
    let granted: Bool
    /// First failing reason, or "ok". One of: nonce_mismatch, wrong_schema,
    /// missing_claims, stale_screening, rail_not_accepted, verification_failed.
    let reason: String
    let missing: [String]
    let message: String?
}

enum CommerceMerchantPolicy {

    /// The non-cryptographic checks, as pure inputs so they are unit-testable
    /// without fabricating a full Presentation. Returns the failing reasons (in
    /// priority order) plus the missing required-claim keys.
    static func policyReasons(
        schema: String,
        disclosedKeys: Set<String>,
        rail: PaymentRail,
        responseNonce: String,
        sanctions: SanctionsDisclosure?,
        request: CommerceRequest,
        nowSec: Int64
    ) -> (reasons: [String], missing: [String]) {
        var reasons: [String] = []

        if responseNonce != request.paymentTerms.nonce {
            reasons.append("nonce_mismatch")
        }

        let schemas = request.verifierRequest.filter.schemas
        if let schemas, schemas.mode == "allow",
           !(schemas.list ?? []).contains(schema) {
            reasons.append("wrong_schema")
        }

        let missing = request.verifierRequest.filter.requiredClaims
            .filter { !disclosedKeys.contains($0) }
        if !missing.isEmpty { reasons.append("missing_claims") }

        if let r = sanctionsReason(sanctions, maxAgeSec: request.identityMaxAgeSec, nowSec: nowSec) {
            reasons.append(r)
        }

        if !railAccepted(rail, in: request.paymentTerms.acceptedRails) {
            reasons.append("rail_not_accepted")
        }

        return (reasons, missing)
    }

    /// Full evaluation: the policy checks above plus the offline cryptographic
    /// verdict (signatures, Merkle proofs, expiry) from PresentationVerifier.
    static func evaluate(
        response: CommerceResponse,
        request: CommerceRequest,
        nowSec: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> CommerceAcceptResult {
        let p = response.presentation
        let disclosedMap: [String: Any] = Dictionary(uniqueKeysWithValues: p.disclosed.map { ($0.key, $0.value.anyValue) })
        var (reasons, missing) = policyReasons(
            schema: p.header.schema,
            disclosedKeys: Set(p.disclosed.map { $0.key }),
            rail: response.payment.rail,
            responseNonce: response.nonce,
            sanctions: extractSanctions(fromDisclosed: disclosedMap),
            request: request,
            nowSec: nowSec)

        if !PresentationVerifier.verifyOffline(p, nowSec: nowSec).checks.overallPass {
            reasons.append("verification_failed")
        }

        let granted = reasons.isEmpty
        return CommerceAcceptResult(
            granted: granted,
            reason: reasons.first ?? "ok",
            missing: missing,
            message: granted ? nil : message(for: reasons.first ?? "", missing: missing,
                                             disclosedKeys: p.disclosed.map { $0.key }))
    }

    // MARK: -- helpers

    /// A rail matches when the merchant published the same chain/network/asset
    /// and receiving address (address compared case-insensitively for EVM).
    static func railAccepted(_ rail: PaymentRail, in accepted: [PaymentRail]) -> Bool {
        accepted.contains { a in
            a.chain == rail.chain
                && (a.network ?? "") == (rail.network ?? "")
                && a.asset == rail.asset
                && a.address.caseInsensitiveCompare(rail.address) == .orderedSame
        }
    }

    /// Sanctions screening as disclosed. Either the passport `sdnScreen` object
    /// or the legacy flat `sanctionsScreenedAt` (musnadMaknoon), normalized.
    struct SanctionsDisclosure: Equatable {
        let result: String?      // "clean"/"sanctioned"/"pep"/… ; nil => legacy flat (presence implies clean)
        let screenedAt: String?  // ISO-8601
    }

    /// Pull sanctions info from a disclosed-claims map (claim key -> anyValue).
    /// Prefers the passport `sdnScreen` object; falls back to the flat key.
    static func extractSanctions(fromDisclosed disclosed: [String: Any]) -> SanctionsDisclosure? {
        if let sdn = disclosed["sdnScreen"] as? [String: Any] {
            return SanctionsDisclosure(result: sdn["result"] as? String,
                                       screenedAt: sdn["screenedAt"] as? String)
        }
        if let flat = disclosed["sanctionsScreenedAt"] as? String {
            return SanctionsDisclosure(result: "clean", screenedAt: flat)
        }
        return nil
    }

    /// Fail-closed sanctions gate. nil `maxAgeSec` => not requested (pass).
    /// Requires a "clean" result screened within `maxAgeSec`; anything else
    /// (sanctioned/pep/inconclusive/error, missing, or stale) fails.
    static func sanctionsReason(_ s: SanctionsDisclosure?, maxAgeSec: Int64?, nowSec: Int64) -> String? {
        guard let maxAge = maxAgeSec else { return nil }
        guard let s else { return "stale_screening" }
        if let result = s.result, result.lowercased() != "clean" { return "sanctioned" }
        guard let iso = s.screenedAt, let age = ageSeconds(iso: iso, nowSec: nowSec), age <= maxAge else {
            return "stale_screening"
        }
        return nil
    }

    private static func ageSeconds(iso: String, nowSec: Int64) -> Int64? {
        let f = ISO8601DateFormatter()
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? withFrac.date(from: iso) else { return nil }
        return nowSec - Int64(d.timeIntervalSince1970)
    }

    static func message(for reason: String, missing: [String], disclosedKeys: [String]) -> String {
        switch reason {
        case "missing_claims":
            let shared = disclosedKeys.isEmpty ? "nothing" : disclosedKeys.sorted().joined(separator: ", ")
            return "Missing: \(missing.joined(separator: ", ")). The customer shared: \(shared)."
        case "wrong_schema":      return "The customer presented the wrong credential type."
        case "stale_screening":   return "The customer's sanctions screening is missing or too old."
        case "sanctioned":        return "The customer's sanctions screening is not clean (flagged)."
        case "rail_not_accepted": return "The customer chose a payment rail this merchant does not accept."
        case "nonce_mismatch":    return "The response did not match this request (replay or stale QR)."
        case "verification_failed": return "The credential failed cryptographic verification."
        default:                  return "Declined: \(reason)"
        }
    }
}
