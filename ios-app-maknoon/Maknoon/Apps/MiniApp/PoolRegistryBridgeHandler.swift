// "pools" namespace handler (window.maknoon.pools.list).
//
// pools.list({ issuerUrl, caip2? }) does the one thing the mini-app sandbox
// cannot do itself: a network read. The WebView CSP is `connect-src 'none'`, so
// the page has no fetch/XHR; every network hop goes through this bridge. Here we
// GET the Access Issuer's public GET /v1/pools (the operator-maintained
// credential-gated pool registry, ADR-0058 / issuer pool-registry) and hand the
// parsed JSON straight back to the page, which uses it to populate its pool picker
// instead of hardcoding one pool.
//
// This is a read of a PUBLIC endpoint and carries no user data, no key material,
// and no consent step. To keep the sandbox's egress tied to a capability the app
// already holds, the handler is only registered for apps with EVM access (see
// MiniAppHostView), so it needs no permission token of its own.

import Foundation

@MainActor
final class PoolRegistryBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "pools"
    // Registered only for EVM-capable apps (MiniAppHostView); the endpoint is
    // public, so no per-method permission is required.
    let requiredPermission: String? = nil

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "pools.list":
            return try await list(params: params)
        default:
            throw MiniAppBridgeError.unsupported("pools.\(method)")
        }
    }

    private func list(params: Any?) async throws -> Any {
        guard let opts = params as? [String: Any],
              let issuerURLString = opts["issuerUrl"] as? String,
              let issuerURL = URL(string: issuerURLString) else {
            throw MiniAppBridgeError.invalidParams("pools.list requires { issuerUrl }")
        }
        let base = issuerURL.absoluteString.hasSuffix("/")
            ? String(issuerURL.absoluteString.dropLast()) : issuerURL.absoluteString
        var urlString = "\(base)/v1/pools"
        // Optional CAIP-2 filter. Encode the colon so it stays one query value
        // (matches the server's ?caip2=eip155:NNN handling).
        if let caip2 = opts["caip2"] as? String, !caip2.isEmpty {
            urlString += "?caip2=\(caip2.replacingOccurrences(of: ":", with: "%3A"))"
        }
        guard let url = URL(string: urlString) else {
            throw MiniAppBridgeError.invalidParams("pools.list: bad issuerUrl")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MiniAppBridgeError.internalError("no response from the issuer")
        }
        guard 200..<300 ~= http.statusCode else {
            throw MiniAppBridgeError.internalError("pools.list failed (\(http.statusCode))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniAppBridgeError.internalError("pools.list: malformed registry response")
        }
        LogStore.shared.info("MiniApp", "pools.list: \((obj["pools"] as? [Any])?.count ?? 0) pool(s) from \(base)")
        return obj
    }
}
