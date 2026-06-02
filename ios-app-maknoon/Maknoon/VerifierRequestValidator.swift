// Authenticates a scanned `VerifierRequest`. Two trust tiers:
//
//   * Self-signed: `verifierPublicKey` + `signature` inline. Validates the
//     signature against the embedded pubkey. UI badge: yellow.
//   * Registered: `verifierPublicKey` omitted. Resolves the pubkey via
//     `/v1/verifier-registry/:did` and validates `signature` against the
//     server-vouched pubkey. UI badge: green.
//
// Cryptographic verification routes through `MLDSAClient.verify` (Apple
// CryptoKit native ML-DSA-65). Canonical bytes are produced by the same
// `@elabify/core` `canonicalize()` the server uses, so byte-equality
// across iOS / TS holds without a separate KAT.

import Foundation
import ElabifyCore

enum VerifierRequestValidator {

    enum TrustTier: Equatable {
        case selfSigned
        case registered(name: String)
        case unknown
    }

    struct Decision {
        let request: VerifierRequest
        let tier: TrustTier
        let isValid: Bool
        let reason: String?  // populated iff isValid == false
    }

    /// Parse + authenticate a scanned QR payload. Performs IO when the
    /// request omits its inline pubkey (registry lookup).
    static func validate(
        scannedJsonString: String,
        registryHost: URL,
        nowSec: Int64 = Int64(Date().timeIntervalSince1970)
    ) async -> Decision? {
        // request_uri indirection: a self-signed VerifierRequest (inline ML-DSA
        // pubkey + signature, ~10 KB) is far over a QR's ~3 KB ceiling, so the
        // QR may carry an https URL to fetch the full request from (mirrors
        // OpenID4VP request_uri). Raw JSON is still accepted for back-compat.
        let data: Data
        let trimmed = scannedJsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeFetchableURL(trimmed), let url = URL(string: trimmed) {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (fetched, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            data = fetched
        } else {
            guard let d = scannedJsonString.data(using: .utf8) else { return nil }
            data = d
        }

        // Decode either a raw VerifierRequest (QR-inline / back-compat) or the
        // { v, request } envelope returned by GET /v1/verifier-request/:id.
        let request: VerifierRequest
        if let direct = try? JSONDecoder().decode(VerifierRequest.self, from: data) {
            request = direct
        } else if let env = try? JSONDecoder().decode(RequestEnvelope.self, from: data) {
            request = env.request
        } else {
            return nil
        }

        // Cheap structural checks first.
        if request.v != 1 {
            return Decision(request: request, tier: .unknown, isValid: false, reason: "Unsupported request version")
        }
        if nowSec > request.expiresAt {
            return Decision(request: request, tier: .unknown, isValid: false, reason: "Request has expired")
        }
        guard let sigHex = request.signature else {
            return Decision(request: request, tier: .unknown, isValid: false, reason: "Request is missing a signature")
        }

        // Resolve the pubkey + tier.
        let pubkey: Data?
        let tier: TrustTier
        if let inlineHex = request.verifierPublicKey {
            pubkey = hexToData(inlineHex)
            tier = .selfSigned
        } else {
            let rec = await VerifierRegistryClient.lookup(host: registryHost, did: request.verifierDid)
            if let rec, let pk = hexToData(rec.verifierPublicKey) {
                pubkey = pk
                tier = .registered(name: rec.verifierName)
            } else {
                return Decision(
                    request: request,
                    tier: .unknown,
                    isValid: false,
                    reason: "Verifier DID not in registry"
                )
            }
        }
        guard let pubkey, let sig = hexToData(sigHex) else {
            return Decision(request: request, tier: tier, isValid: false, reason: "Malformed pubkey or signature hex")
        }

        // Canonicalize the request WITHOUT the signature field, byte-for-byte
        // identical to the server-side check (verifier-server checks.ts
        // `verifyVerifierRequest`). The simplest robust path: round-trip
        // through Dictionary<String, Any> and drop `signature`.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let raw = try encoder.encode(request)
            guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                return Decision(request: request, tier: tier, isValid: false, reason: "Could not re-canonicalize")
            }
            obj.removeValue(forKey: "signature")
            let msgBytes = try canonicalize(obj)
            let ok = MLDSAClient.verify(publicKey: pubkey, signature: sig, message: msgBytes)
            return Decision(
                request: request,
                tier: tier,
                isValid: ok,
                reason: ok ? nil : "Signature does not validate"
            )
        } catch {
            return Decision(request: request, tier: tier, isValid: false, reason: "\(error)")
        }
    }

    /// Envelope shape returned by GET /v1/verifier-request/:id.
    private struct RequestEnvelope: Decodable {
        let request: VerifierRequest
    }

    /// Only https (or http to localhost for dev) is fetchable, a light SSRF
    /// guard on an attacker-chosen QR URL.
    private static func looksLikeFetchableURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("https://") { return true }
        if lower.hasPrefix("http://localhost") || lower.hasPrefix("http://127.0.0.1") { return true }
        return false
    }

    private static func hexToData(_ s: String) -> Data? {
        let stripped = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard stripped.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(stripped.count / 2)
        var idx = stripped.startIndex
        while idx < stripped.endIndex {
            let next = stripped.index(idx, offsetBy: 2)
            guard let b = UInt8(stripped[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}

/// Thin client for `GET /v1/verifier-registry/:did`. Returns nil on 404
/// or any network error — the caller falls back to "Verifier DID not in
/// registry" semantics.
enum VerifierRegistryClient {
    static func lookup(host: URL, did: String) async -> VerifierRegistryRecord? {
        let encoded = did.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? did
        let url = host.appendingPathComponent("/v1/verifier-registry/\(encoded)")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            return try JSONDecoder().decode(VerifierRegistryRecord.self, from: data)
        } catch {
            return nil
        }
    }
}
