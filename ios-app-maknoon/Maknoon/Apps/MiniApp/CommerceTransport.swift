// HTTP client for the server-mediated "verify and pay" flow (ADR-0031). The
// merchant hosts a signed CommerceRequest (small URL QR) and polls for the
// holder's response; the holder fetches the request and posts back its
// presentation + payment proof (txHash). The server is a relay — verification
// happens on the merchant device.

import Foundation

enum CommerceTransportError: LocalizedError {
    case http(Int)
    case decode(String)
    case badURL
    var errorDescription: String? {
        switch self {
        case .http(let s):     return "Server returned HTTP \(s)."
        case .decode(let m):   return "Could not read the server response: \(m)"
        case .badURL:          return "Invalid server URL."
        }
    }
}

/// The holder->merchant payload, stored+forwarded by the server and polled by
/// the merchant. Shared shape for POST (holder) and GET result (merchant).
struct CommerceServerResponse: Codable, Sendable {
    let requestId: String
    let presentation: Presentation
    let payment: Payment
    struct Payment: Codable, Sendable {
        let rail: PaymentRail
        let txHash: String
    }
}

enum CommerceTransport {
    // MARK: - Holder

    /// Fetch + decode a hosted CommerceRequest from a `request_uri`. Accepts the
    /// `{ v, request }` envelope or a bare CommerceRequest.
    static func fetchRequest(url: URL) async throws -> CommerceRequest {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CommerceTransportError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Envelope: Decodable { let request: CommerceRequest }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data) { return env.request }
        do { return try JSONDecoder().decode(CommerceRequest.self, from: data) }
        catch { throw CommerceTransportError.decode("\(error)") }
    }

    /// Post the holder's SEALED response for the merchant (server stays blind).
    static func postResponse(baseURL: URL, _ envelope: CommerceSealedEnvelope) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/commerce-response"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(envelope)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CommerceTransportError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Merchant

    /// Host a signed CommerceRequest; returns its requestId (for the QR URL + polling).
    static func hostRequest(baseURL: URL, _ request: CommerceRequest) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/commerce-request"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["request": request])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CommerceTransportError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Hosted: Decodable { let requestId: String }
        guard let h = try? JSONDecoder().decode(Hosted.self, from: data) else {
            throw CommerceTransportError.decode("missing requestId")
        }
        return h.requestId
    }

    /// Poll for the holder's SEALED response; nil until the holder has posted
    /// it. The merchant opens it locally with its ephemeral keypair.
    static func pollResult(baseURL: URL, requestId: String) async throws -> CommerceSealedEnvelope? {
        let (data, resp) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("/v1/commerce-result/\(requestId)"))
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CommerceTransportError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Poll: Decodable { let found: Bool; let response: CommerceSealedEnvelope? }
        guard let p = try? JSONDecoder().decode(Poll.self, from: data) else { return nil }
        return p.found ? p.response : nil
    }
}
