// HTTP client for LNDHub-compatible Lightning custodial servers.
// Same API surface BlueWallet defined and Zeus speaks: POST /auth
// for tokens, GET /balance, POST /addinvoice, POST /payinvoice,
// GET /gettxs, GET /getuserinvoices.
//
// TLS: the configured account flag `allowInsecureTLS` flips the
// URLSessionDelegate to accept self-signed certificates. Off by
// default; users running their own hub with a private CA opt in
// from the Networks settings page.

import Foundation

struct LightningInvoice: Codable, Hashable, Sendable {
    /// BOLT11-encoded payment request string (`lnbc...`).
    let payment_request: String
    /// Amount in millisatoshi (LNDHub returns this as a string in
    /// some implementations, integer in others; we accept both).
    let amt: String?
    /// User-supplied memo / description.
    let memo: String?
}

/// One entry from LNDHub `/gettxs` (outgoing payments) OR from
/// `/getuserinvoices` (incoming). The shape varies wildly across
/// implementations: some serialise numeric fields as strings, some
/// use `amt` instead of `value`, some use `description` instead of
/// `memo`, some return a top-level `{txs: [...]}` envelope instead
/// of a bare array. This struct's `init(from:)` accepts all of
/// those.
struct LightningTx: Hashable, Identifiable, Sendable {
    let payment_hash: String?
    let payment_preimage: String?
    let value: Int64?
    let fee: Int64?
    let memo: String?
    let timestamp: Int64?
    let type: String?
    /// True if this is an incoming invoice that the payer
    /// settled. Only meaningful for `/getuserinvoices` rows;
    /// `/gettxs` payments don't carry this flag.
    let isPaid: Bool?

    var id: String { payment_hash ?? "\(timestamp ?? 0)|\(value ?? 0)" }
    var isOutgoing: Bool {
        let t = (type ?? "").lowercased()
        // user_invoice / user_invoice_settled = incoming; everything
        // else (paid_invoice, outgoing, user_outgoing) = outgoing.
        if t.contains("invoice") && !t.contains("paid") {
            return false
        }
        return t.contains("paid") || t == "outgoing" || t == "user_outgoing"
    }
}

extension LightningTx: Codable {
    enum CodingKeys: String, CodingKey {
        case payment_hash, payment_preimage, value, amount, amt, fee, fees
        case memo, description, timestamp, time, settled_at, type, ispaid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.payment_hash = try c.decodeStringFlex(forKey: .payment_hash)
        self.payment_preimage = try c.decodeStringFlex(forKey: .payment_preimage)
        self.value = try c.decodeInt64Flex(forKey: .value)
            ?? c.decodeInt64Flex(forKey: .amount)
            ?? c.decodeInt64Flex(forKey: .amt)
        self.fee = try c.decodeInt64Flex(forKey: .fee)
            ?? c.decodeInt64Flex(forKey: .fees)
        self.memo = try c.decodeStringFlex(forKey: .memo)
            ?? c.decodeStringFlex(forKey: .description)
        self.timestamp = try c.decodeInt64Flex(forKey: .timestamp)
            ?? c.decodeInt64Flex(forKey: .time)
            ?? c.decodeInt64Flex(forKey: .settled_at)
        self.type = try c.decodeStringFlex(forKey: .type)
        self.isPaid = try c.decodeIfPresent(Bool.self, forKey: .ispaid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(payment_hash, forKey: .payment_hash)
        try c.encodeIfPresent(payment_preimage, forKey: .payment_preimage)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(fee, forKey: .fee)
        try c.encodeIfPresent(memo, forKey: .memo)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(isPaid, forKey: .ispaid)
    }
}

private extension KeyedDecodingContainer {
    /// Decode an Int64 that may have been serialised as either a
    /// number or a numeric string (e.g. "1000"). Returns nil for
    /// missing, null, or unparseable values.
    func decodeInt64Flex(forKey key: Key) throws -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Decode a String that may be missing or null. Numbers also
    /// accepted (some LNDHubs ship payment_hash as bytes-rendered-
    /// to-int in edge cases).
    func decodeStringFlex(forKey key: Key) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return "\(i)" }
        return nil
    }
}

enum LNDHubError: LocalizedError {
    case badServerURL
    case http(Int, String)
    case server(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badServerURL:        return "Server URL is not a valid HTTPS URL."
        case .http(let s, let b):  return "HTTP \(s): \(b.prefix(200))"
        case .server(let m):       return "Hub error: \(m)"
        case .decode(let m):       return "Could not decode response: \(m)"
        }
    }
}

actor LNDHubClient {
    let account: LightningAccount
    let password: String

    private var accessToken: String?
    private var refreshToken: String?
    private let session: URLSession

    init(account: LightningAccount, password: String) {
        self.account = account
        self.password = password
        // Use the URLSessionDelegate-driven session if the account
        // is opted into self-signed-cert acceptance; otherwise use
        // the shared session with strict trust evaluation.
        if account.allowInsecureTLS {
            let cfg = URLSessionConfiguration.default
            self.session = URLSession(
                configuration: cfg,
                delegate: InsecureTLSDelegate(),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession.shared
        }
    }

    // MARK: -- auth

    private struct AuthResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let error: String?
        let message: String?
    }

    private func authenticate() async throws {
        let body: [String: Any] = [
            "login": account.username,
            "password": password,
        ]
        let resp: AuthResponse = try await postJSON(path: "/auth?type=auth", body: body, authenticated: false)
        guard let t = resp.access_token, let r = resp.refresh_token else {
            throw LNDHubError.server(resp.error ?? resp.message ?? "auth response missing tokens")
        }
        self.accessToken = t
        self.refreshToken = r
    }

    private func ensureAuth() async throws {
        if accessToken == nil { try await authenticate() }
    }

    // MARK: -- balance

    private struct BalanceResponse: Decodable {
        struct BTC: Decodable { let AvailableBalance: Int64 }
        let BTC: BTC?
        let error: String?
        let message: String?
    }

    /// Total available balance in satoshis.
    func balanceSat() async throws -> Int64 {
        try await ensureAuth()
        let resp: BalanceResponse = try await get(path: "/balance")
        if let err = resp.error ?? resp.message {
            throw LNDHubError.server(err)
        }
        return resp.BTC?.AvailableBalance ?? 0
    }

    // MARK: -- invoices

    private struct AddInvoiceResponse: Decodable {
        let payment_request: String?
        let error: String?
        let message: String?
    }

    /// Create a receive invoice. `amountSat = 0` makes an
    /// amountless invoice (the payer specifies the amount).
    func addInvoice(amountSat: Int64, memo: String) async throws -> String {
        try await ensureAuth()
        let body: [String: Any] = [
            "amt": "\(amountSat)",
            "memo": memo,
        ]
        let resp: AddInvoiceResponse = try await postJSON(path: "/addinvoice", body: body, authenticated: true)
        if let err = resp.error ?? resp.message, resp.payment_request == nil {
            throw LNDHubError.server(err)
        }
        guard let pr = resp.payment_request else {
            throw LNDHubError.decode("payment_request missing")
        }
        return pr
    }

    // MARK: -- pay

    private struct PayInvoiceResponse: Decodable {
        let payment_preimage: String?
        let payment_route: PaymentRoute?
        let error: String?
        let message: String?

        struct PaymentRoute: Decodable {
            let total_amt: Int64?
            let total_fees: Int64?
        }
    }

    struct PaymentResult: Sendable {
        let preimage: String
        let amountSat: Int64?
        let feeSat: Int64?
    }

    /// Pay a BOLT11 invoice. `amountSat` is required only when the
    /// invoice has no embedded amount; pass nil to use the
    /// invoice's amount.
    func payInvoice(_ bolt11: String, amountSat: Int64? = nil) async throws -> PaymentResult {
        try await ensureAuth()
        var body: [String: Any] = ["invoice": bolt11]
        if let amt = amountSat { body["amount"] = amt }
        // /payinvoice blocks until the payment ROUTES (or fails), which can
        // exceed URLSession's 60s default for a multi-hop route and surface as
        // a bogus "timeout" on a healthy hub. Give it a generous window
        // (parity with Android's 120s read timeout on the same call).
        let resp: PayInvoiceResponse = try await postJSON(
            path: "/payinvoice",
            body: body,
            authenticated: true,
            timeout: 120
        )
        if let err = resp.error ?? resp.message, resp.payment_preimage == nil {
            throw LNDHubError.server(err)
        }
        guard let preimage = resp.payment_preimage else {
            throw LNDHubError.decode("payment_preimage missing")
        }
        return PaymentResult(
            preimage: preimage,
            amountSat: resp.payment_route?.total_amt,
            feeSat: resp.payment_route?.total_fees
        )
    }

    // MARK: -- history

    /// Combined history: outgoing payments (`/gettxs`) + settled
    /// incoming invoices (`/getuserinvoices` filtered by ispaid).
    /// Sorted newest first; deduped by payment_hash.
    func history(limit: Int = 100) async throws -> [LightningTx] {
        async let outgoing: [LightningTx] = transactions(limit: limit)
        async let incoming: [LightningTx] = userInvoices(limit: limit)
        let out = (try? await outgoing) ?? []
        let inv = (try? await incoming) ?? []
        let merged = (out + inv.filter { $0.isPaid != false })
        var seen = Set<String>()
        var deduped: [LightningTx] = []
        for tx in merged {
            let key = tx.payment_hash ?? tx.id
            if seen.insert(key).inserted { deduped.append(tx) }
        }
        return deduped.sorted { ($0.timestamp ?? 0) > ($1.timestamp ?? 0) }
    }

    func transactions(limit: Int = 100) async throws -> [LightningTx] {
        try await ensureAuth()
        let data = try await getRaw(path: "/gettxs?limit=\(limit)")
        // Some LNDHubs return a bare array; some return
        // `{"txs": [...]}`; a few sprinkle invoices into a
        // separate `/getuserinvoices` endpoint instead. We try
        // both shapes here and fall back to an empty list rather
        // than throwing, so a malformed response doesn't blank
        // the wallet's other state.
        if let arr = try? JSONDecoder().decode([LightningTx].self, from: data) {
            return arr
        }
        struct Envelope: Decodable { let txs: [LightningTx]? }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let txs = env.txs {
            return txs
        }
        // Final attempt: snapshot the raw response into the
        // diagnostic log so we can see exactly what shape the
        // server returned. Surface a friendlier error than the
        // raw decoder message.
        let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
        LogStore.shared.warn("lightning.gettxs",
            "could not decode \(account.serverURL): \(preview)")
        throw LNDHubError.decode(
            "history payload didn't match any known LNDHub shape. Paste the diagnostic log entry under Settings → About → Share logs so we can extend the decoder."
        )
    }

    /// Incoming invoices. LNDHub splits these out from `/gettxs`,
    /// which only carries outgoing payments. Returns invoices in
    /// the same `LightningTx` shape; callers filter by `isPaid`.
    func userInvoices(limit: Int = 100) async throws -> [LightningTx] {
        try await ensureAuth()
        let data = try await getRaw(path: "/getuserinvoices?limit=\(limit)")
        if let arr = try? JSONDecoder().decode([LightningTx].self, from: data) {
            // user_invoice rows don't carry a `type` field in some
            // forks; tag them post-decode so isOutgoing returns false.
            return arr.map { tx in
                var copy = tx
                if (tx.type ?? "").isEmpty {
                    copy = LightningTx(
                        payment_hash: tx.payment_hash,
                        payment_preimage: tx.payment_preimage,
                        value: tx.value,
                        fee: tx.fee,
                        memo: tx.memo,
                        timestamp: tx.timestamp,
                        type: "user_invoice",
                        isPaid: tx.isPaid
                    )
                }
                return copy
            }
        }
        struct Envelope: Decodable { let invoices: [LightningTx]? }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let invs = env.invoices {
            return invs
        }
        let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>"
        LogStore.shared.warn("lightning.getuserinvoices",
            "could not decode \(account.serverURL): \(preview)")
        return []
    }

    // MARK: -- transport

    private func url(_ path: String) throws -> URL {
        let base = account.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: base + path) else { throw LNDHubError.badServerURL }
        return u
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "GET"
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    /// GET that returns the raw body. Used by endpoints whose
    /// shape we want to inspect/probe (e.g. /gettxs which varies
    /// per LNDHub implementation).
    private func getRaw(path: String) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "GET"
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LNDHubError.http(http.statusCode, body)
        }
        return data
    }

    private func postJSON<T: Decodable>(
        path: String,
        body: [String: Any],
        authenticated: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let timeout { req.timeoutInterval = timeout }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LNDHubError.http(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LNDHubError.decode("\(error.localizedDescription)")
        }
    }
}

/// URLSessionDelegate that accepts the server-presented certificate
/// without validation. Only used when the account is opted into
/// `allowInsecureTLS`. Otherwise the shared session does strict
/// trust evaluation.
final class InsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
