// Serves a verified mini-app bundle to WKWebView over a custom scheme.
//
// Each mini app loads from `maknoon-app://<appId>/<path>`. A custom
// scheme (rather than a loopback HTTP server) means:
//   * no open port, no ATS interaction, no network at all at serve time;
//   * a stable, app-unique web origin so localStorage / cookies are
//     isolated per app and never collide with a real https origin;
//   * the WebView can only reach files we have already integrity-checked.
//
// The handler maps the URL path to a file inside the bundle's rootDir,
// rejecting traversal, and attaches a strict Content-Security-Policy that
// forbids loading any off-origin resource. The mini app talks to native
// only through the injected bridge, never by fetching across the network
// directly (the POS demo reaches chain/verifier endpoints via the bridge,
// not via DOM fetch), so a tight CSP is safe.

import Foundation
import WebKit
import UniformTypeIdentifiers

final class MiniAppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "maknoon-app"

    private let bundle: MiniAppBundle

    init(bundle: MiniAppBundle) {
        self.bundle = bundle
    }

    /// Origin the bundle's entry page lives at.
    static func entryURL(appId: String, entryPath: String) -> URL {
        URL(string: "\(scheme)://\(host(for: appId))/\(entryPath)")!
    }

    /// Lowercased, scheme-safe host derived from the app id.
    static func host(for appId: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let lowered = appId.lowercased()
        let cleaned = String(lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "app" : cleaned
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.err("no url"))
            return
        }

        // Path inside the bundle. "/" -> entry page.
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = bundle.entryPath }

        guard let fileURL = resolve(path: path) else {
            respondNotFound(urlSchemeTask, url: url)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            respondNotFound(urlSchemeTask, url: url)
            return
        }

        let mime = Self.mimeType(for: fileURL)
        var headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
        ]
        // Lock the page down: only same-origin (the bundle) plus inline
        // styles/scripts the app ships. No remote origins. connect-src
        // 'none' because all native I/O goes through the message bridge,
        // not fetch/XHR.
        headers["Content-Security-Policy"] = [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "font-src 'self' data:",
            "connect-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler; nothing to cancel.
    }

    // MARK: -- helpers

    /// Map a request path to a file inside rootDir, rejecting traversal.
    private func resolve(path: String) -> URL? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.contains(".."), !comps.contains(".") else { return nil }
        var dest = bundle.rootDir
        for c in comps { dest = dest.appendingPathComponent(c) }
        let rootStd = bundle.rootDir.standardizedFileURL.path
        let destStd = dest.standardizedFileURL.path
        guard destStd == rootStd || destStd.hasPrefix(rootStd + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: destStd) else { return nil }
        return dest
    }

    private func respondNotFound(_ task: WKURLSchemeTask, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        task.didReceive(response)
        task.didReceive(Data("Not found".utf8))
        task.didFinish()
    }

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "txt":         return "text/plain; charset=utf-8"
        default:
            if let t = UTType(filenameExtension: ext)?.preferredMIMEType { return t }
            return "application/octet-stream"
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "MiniAppSchemeHandler", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
