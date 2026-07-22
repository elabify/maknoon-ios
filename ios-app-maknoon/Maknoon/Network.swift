// Phase C network layer: `URLSession`-based, no third-party HTTP code.
// M4b proper routes everything through MusnadSDK so the app never sees
// raw bytes. Here we read+parse directly.

import Foundation

enum NetworkError: LocalizedError {
    case badURL
    case http(Int, String)
    case decoding(Error)
    case relayDisabled

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decoding(let e): return "Decode failed: \(e)"
        case .relayDisabled:
            return "The presentation relay is turned off in Settings, Identity. Turn it on to share or fetch a presentation over the network, or use the privacy QR."
        }
    }
}

/// Outcome of a pickup attempt. `pending` is a normal state during the
/// batch-anchor window (ADR-0022) and is not an error; the UI polls
/// until the credential is ready.
enum PickupOutcome {
    case ready(Credential)
    case pending(estimatedAnchorAt: Int64?)
}

enum IssuerClient {
    /// GET /v1/issuance/pickup/{token}. Returns `.ready` once the issuer's
    /// batch has flushed, otherwise `.pending` with an optional ETA.
    static func pickup(url pickupURL: URL) async throws -> PickupOutcome {
        var req = URLRequest(url: pickupURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.http(0, "no response") }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.http(http.statusCode, body)
        }
        do {
            let envelope = try JSONDecoder().decode(PickupEnvelope.self, from: data)
            if envelope.state == "ready", let cred = envelope.credential {
                return .ready(cred)
            }
            return .pending(estimatedAnchorAt: envelope.estimatedAnchorAt)
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    /// GET /v1/credentials/{cid}/anchors (ADR-0030). Returns the CURRENT anchor
    /// block, which GROWS as each network's batch lands after the credential is
    /// first delivered (the issuer marks it ready on the first network). The
    /// holder re-polls this so the card lights up each network as it anchors.
    /// Public + cid-keyed (not the one-time pickup token). Best-effort: returns
    /// nil on any error (wrong host / not found / offline).
    static func fetchAnchors(cid: String, host: String) async -> AnchorDescriptor? {
        guard let url = URL(string: "https://\(host)/v1/credentials/\(cid)/anchors") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        struct AnchorsResponse: Decodable { let anchor: AnchorDescriptor? }
        return (try? JSONDecoder().decode(AnchorsResponse.self, from: data))?.anchor
    }

    // MARK: -- restore-time reissuance

    /// One reissued credential the issuer is re-minting; carries a fresh
    /// pickup URL the holder polls like any other.
    struct ReissuePickup: Decodable, Sendable {
        let schema: String
        let credentialId: String
        let pickupUrl: String
        let estimatedAnchorAt: Int64?
    }

    struct ReissueResult: Decodable, Sendable {
        struct Skip: Decodable, Sendable { let schema: String; let reason: String }
        let reissued: [ReissuePickup]
        let skipped: [Skip]?
    }

    private struct ChallengeResult: Decodable { let nonce: String; let expiresAt: Int64 }

    /// POST /v1/issuance/reissue/challenge: get a one-time nonce bound to
    /// our holder DID. We then sign it with the master key and POST it back.
    static func reissueChallenge(host issuerBase: URL, holderDID: String) async throws -> String {
        let result: ChallengeResult = try await post(
            url: issuerBase.appendingPathComponent("/v1/issuance/reissue/challenge"),
            body: ["holderDid": holderDID]
        )
        return result.nonce
    }

    /// POST /v1/issuance/reissue: prove control of the holder DID with the
    /// signed nonce; the issuer re-mints the latest credential per schema it
    /// holds for this DID and returns their pickup URLs.
    static func reissue(
        host issuerBase: URL,
        holderDID: String,
        masterPublicKeyHex: String,
        nonce: String,
        signatureHex: String
    ) async throws -> ReissueResult {
        struct Body: Encodable {
            let v = 1
            let holderDid: String
            let masterPublicKey: String
            let nonce: String
            let signature: String
        }
        return try await post(
            url: issuerBase.appendingPathComponent("/v1/issuance/reissue"),
            body: Body(
                holderDid: holderDID,
                masterPublicKey: masterPublicKeyHex,
                nonce: nonce,
                signature: signatureHex
            )
        )
    }

    private static func post<Req: Encodable, Resp: Decodable>(url: URL, body: Req) async throws -> Resp {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.http(0, "no response") }
        guard 200..<300 ~= http.statusCode else {
            let respBody = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.http(http.statusCode, respBody)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw NetworkError.decoding(error)
        }
    }
}

/// Combined decoder for both `state: "ready"` (credential set) and
/// `state: "pending_anchor"` (estimatedAnchorAt set, credential nil)
/// branches of the pickup endpoint. Codable ignores unknown fields.
private struct PickupEnvelope: Codable {
    let state: String
    let credential: Credential?
    let estimatedAnchorAt: Int64?
}

enum VerifierClient {
    /// POST /v1/challenge: returns a fresh challenge + requestId.
    static func challenge(verifierBase: URL, requestedClaims: [String]) async throws -> ChallengeResponse {
        let body = ChallengeRequest(v: 1, requestedClaims: requestedClaims)
        return try await post(url: verifierBase.appendingPathComponent("/v1/challenge"), body: body)
    }

    /// POST /v1/verify: runs the full check matrix; returns GRANT/DENY
    /// with per-check details.
    static func verify(verifierBase: URL, request: VerifyRequest) async throws -> VerifyResponse {
        return try await post(url: verifierBase.appendingPathComponent("/v1/verify"), body: request)
    }

    private static func post<Req: Encodable, Resp: Decodable>(url: URL, body: Req) async throws -> Resp {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.http(0, "no response") }
        guard 200..<300 ~= http.statusCode else {
            let respBody = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.http(http.statusCode, respBody)
        }
        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw NetworkError.decoding(error)
        }
    }
}

// MARK: -- Drop service

/// Client for the Elabify-hosted Presentation drop pastebin. Used by the
/// offline `qrBack` flow when the holder wants to render their
/// Presentation as a small QR for an in-person verifier to scan back.
enum PresentationDrop {
    /// POST /v1/drop with the presentation body. Returns the public
    /// envelope (small) suitable for QR encoding.
    static func upload(host: URL, presentation: Presentation) async throws -> DropEnvelope {
        guard RelaySettings.isEnabled else { throw NetworkError.relayDisabled }
        let url = host.appendingPathComponent("/v1/drop")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(["presentation": presentation])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.http(0, "no response") }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.http(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(DropEnvelope.self, from: data)
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    /// GET /v1/drop/{dropId}. One-shot: subsequent fetches 404.
    static func fetch(host: URL, dropId: String) async throws -> Presentation {
        guard RelaySettings.isEnabled else { throw NetworkError.relayDisabled }
        let url = host.appendingPathComponent("/v1/drop/\(dropId)")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.http(0, "no response") }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.http(http.statusCode, body)
        }
        do {
            struct Wrapped: Codable { let presentation: Presentation }
            return try JSONDecoder().decode(Wrapped.self, from: data).presentation
        } catch {
            throw NetworkError.decoding(error)
        }
    }
}

// MARK: -- Open verifier POST (callback-mode share)

/// POST a Presentation to an arbitrary URL, used for the "Share to a URL"
/// terminal action and for `qrBack`-mode auto-callback. The response body
/// is opaque (any verifier can shape it however they want); we return raw
/// bytes + status so the UI can show whatever feedback the verifier sent.
enum OpenVerifierPost {
    struct Outcome {
        let status: Int
        let bodyText: String
    }

    static func send(presentation: Presentation, to url: URL) async throws -> Outcome {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(presentation)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        return Outcome(status: status, bodyText: body)
    }
}
