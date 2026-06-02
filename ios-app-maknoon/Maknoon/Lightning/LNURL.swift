// LNURL-pay handler (LUD-06). Two phases:
//
//   1. Decode a bech32 LNURL or a lightning: prefix URL → URL.
//   2. GET the URL; server returns `tag=payRequest` with min/max
//      amount and a callback. Caller picks an amount, GETs the
//      callback with the chosen amount, gets back a BOLT11
//      invoice that the LNDHub client then pays.
//
// LNURL-withdraw and LNURL-auth are out of scope for this cut —
// only LNURL-pay is wired.

import Foundation

enum LNURL {
    enum Error: LocalizedError {
        case invalidEncoding(String)
        case http(Int, String)
        case wrongTag(String)
        case decode(String)
        case amountOutOfRange(min: Int64, max: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidEncoding(let m): return "Invalid LNURL: \(m)"
            case .http(let s, let b):     return "LNURL HTTP \(s): \(b.prefix(200))"
            case .wrongTag(let t):        return "LNURL tag was \(t), expected payRequest."
            case .decode(let m):          return "LNURL decode failed: \(m)"
            case .amountOutOfRange(let lo, let hi):
                return "Amount is outside the issuer's allowed range (\(lo / 1000) - \(hi / 1000) sat)."
            }
        }
    }

    struct PayRequest: Decodable, Sendable {
        let tag: String
        let callback: String
        let minSendable: Int64        // millisatoshi
        let maxSendable: Int64        // millisatoshi
        let metadata: String          // raw JSON string of metadata tuples
        let commentAllowed: Int?      // optional, LUD-12
    }

    struct PayResponse: Decodable, Sendable {
        let pr: String?               // BOLT11 invoice
        let status: String?
        let reason: String?
    }

    /// Pull out the underlying URL from any of:
    ///   • bech32-encoded `lnurl1...` string
    ///   • `lightning:LNURL1...` prefix
    ///   • bare https URL (some endpoints distribute raw URLs)
    ///   • Lightning Address per LUD-16 (`user@domain.tld`)
    /// Trims any `lightning:` scheme prefix.
    static func decode(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("lightning:") {
            s = String(s.dropFirst("lightning:".count))
        }
        // Bare URL passthrough, some QRs encode the resolved URL
        // directly instead of bech32.
        if s.lowercased().hasPrefix("https://") || s.lowercased().hasPrefix("http://") {
            guard let u = URL(string: s) else {
                throw Error.invalidEncoding("not a parseable URL")
            }
            return u
        }
        // LUD-16 Lightning Address: `user@domain.tld` resolves to
        // `https://domain.tld/.well-known/lnurlp/user`. The response
        // shape is the same payRequest JSON the bech32 path returns,
        // so once we rewrite the URL the rest of the LNURL pipeline
        // works unchanged.
        if s.contains("@"), !s.contains(" ") {
            let parts = s.split(separator: "@", maxSplits: 1).map(String.init)
            if parts.count == 2,
               !parts[0].isEmpty,
               parts[1].contains("."),
               !parts[1].hasPrefix(".") {
                let user = parts[0]
                let domain = parts[1].lowercased()
                let urlString = "https://\(domain)/.well-known/lnurlp/\(user)"
                guard let u = URL(string: urlString) else {
                    throw Error.invalidEncoding("Lightning Address could not be turned into a URL")
                }
                return u
            }
        }
        // bech32 path.
        guard let (hrp, data) = Bech32.decode(s) else {
            throw Error.invalidEncoding("bech32 checksum or alphabet failed")
        }
        guard hrp == "lnurl" else {
            throw Error.invalidEncoding("expected hrp 'lnurl', got '\(hrp)'")
        }
        guard let bytes = Bech32.convertBits(data, from: 5, to: 8, pad: false) else {
            throw Error.invalidEncoding("could not regroup bech32 bits")
        }
        guard let urlString = String(bytes: bytes, encoding: .utf8),
              let url = URL(string: urlString) else {
            throw Error.invalidEncoding("decoded bytes are not a valid URL")
        }
        return url
    }

    /// Fetch the payRequest JSON from a decoded LNURL.
    static func fetchPayRequest(_ url: URL) async throws -> PayRequest {
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let req: PayRequest
        do {
            req = try JSONDecoder().decode(PayRequest.self, from: data)
        } catch {
            throw Error.decode("\(error)")
        }
        guard req.tag == "payRequest" else {
            throw Error.wrongTag(req.tag)
        }
        return req
    }

    /// Hit the callback URL with the chosen amount (sat → msat
    /// conversion happens here) and get back a BOLT11 invoice.
    static func fetchInvoice(payRequest: PayRequest, amountSat: Int64, comment: String? = nil) async throws -> String {
        let amountMsat = amountSat * 1_000
        guard amountMsat >= payRequest.minSendable && amountMsat <= payRequest.maxSendable else {
            throw Error.amountOutOfRange(min: payRequest.minSendable, max: payRequest.maxSendable)
        }
        guard var comps = URLComponents(string: payRequest.callback) else {
            throw Error.decode("callback URL is unparseable")
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "amount", value: "\(amountMsat)"))
        if let comment, !comment.isEmpty,
           let max = payRequest.commentAllowed, max > 0 {
            items.append(URLQueryItem(name: "comment", value: String(comment.prefix(max))))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            throw Error.decode("callback URL with amount param is invalid")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let pay: PayResponse
        do {
            pay = try JSONDecoder().decode(PayResponse.self, from: data)
        } catch {
            throw Error.decode("\(error)")
        }
        if (pay.status?.uppercased() == "ERROR") {
            throw Error.http(0, pay.reason ?? "callback returned ERROR status")
        }
        guard let pr = pay.pr else {
            throw Error.decode("payResponse missing `pr` field")
        }
        return pr
    }

    /// Read out the issuer-supplied display name from the
    /// metadata blob. The blob is a JSON array of pairs:
    /// `[["text/plain", "Coffee shop"], ...]`. We surface the
    /// first `text/plain` entry; LUD-06 says it's the human-
    /// readable description.
    static func extractDescription(metadataJSON: String) -> String? {
        guard let data = metadataJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { return nil }
        for entry in arr where entry.count == 2 {
            if let kind = entry[0] as? String, kind == "text/plain",
               let text = entry[1] as? String {
                return text
            }
        }
        return nil
    }
}
