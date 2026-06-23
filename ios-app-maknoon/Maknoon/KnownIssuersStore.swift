// User's allow-list of credential issuers. Storing the *host* of
// each trusted issuer URL means a single entry trusts every
// endpoint that issuer exposes (pickup, status, revocation)
// without having to enumerate paths.
//
// Defaults are loaded from the bundled Issuers.json (deployment data,
// not hardcoded here) so the demo works out of the box. Users can add
// more (e.g. their employer, university, or a self-hosted issuer) from
// Settings → Identity → Known issuers, and remove any of the defaults
// if they don't trust them.
//
// The Receive credential flow consults this store at fetch time.
// Pickup URLs whose host is in the list proceed silently; URLs
// from an unknown host trigger an explicit one-time-trust prompt
// before any network call is made.

import Foundation
import Observation

@Observable
final class KnownIssuersStore {
    private(set) var hosts: [String] = []

    private static let storeKey = "identity.knownIssuers.v1"

    /// Default-trusted issuer hosts, loaded from the bundled Issuers.json
    /// (deployment data, not code) so the demo against the Sepolia deployment
    /// works on first run. Users can remove any from Identity settings. Missing
    /// or malformed resource -> empty defaults (every pickup then prompts for
    /// one-time trust), so a generic build with no list still works.
    static let defaults: [String] = loadBundledDefaults()

    private struct BundledIssuers: Decodable {
        let defaultTrustedHosts: [String]
    }

    private static func loadBundledDefaults() -> [String] {
        guard let url = Bundle.main.url(forResource: "Issuers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(BundledIssuers.self, from: data)
        else { return [] }
        return doc.defaultTrustedHosts
    }

    init() { load() }

    /// Case-insensitive trust check. Matches against an entry's host
    /// portion, ignoring port. (Entries may be stored as `host` or
    /// `host:port`; a pickup URL on a non-default port is still
    /// trusted as long as the host matches.) The port-preserving
    /// storage is for outbound URL construction; trust decisions stay
    /// host-scoped to match user expectations.
    func isTrusted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        for entry in hosts {
            let entryHost = entry.split(separator: ":").first.map(String.init) ?? entry
            if entryHost.lowercased() == host { return true }
        }
        return false
    }

    /// Build the outbound base URL for a stored issuer entry. The
    /// issuance flow uses this to POST to
    /// `{baseURL}/v1/passport-attestation/submit-packet`.
    ///
    /// Scheme heuristic: localhost / RFC 1918 / link-local addresses
    /// get `http://`; anything else gets `https://`. Local dev (an IP
    /// address with a port like `192.168.1.50:4000`) needs http; a
    /// production issuer hostname needs https. The user can always
    /// override by entering a full URL through the Custom… field at
    /// issuance time, that path doesn't go through this helper.
    func outboundBaseURL(forEntry entry: String) -> URL? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scheme = Self.looksLikeLocalAddress(trimmed) ? "http" : "https"
        return URL(string: "\(scheme)://\(trimmed)")
    }

    private static func looksLikeLocalAddress(_ hostOrHostPort: String) -> Bool {
        let host = hostOrHostPort.split(separator: ":").first.map(String.init) ?? hostOrHostPort
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        // RFC 1918 private ranges.
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        // 169.254/16 link-local.
        if host.hasPrefix("169.254.") { return true }
        return false
    }

    /// Add a new trusted issuer. Accepts either a bare host
    /// (`musnad.elabify.com`) or a full URL (`https://musnad.elabify.com/v1/...`)
    /// and stores the host portion only.
    func add(_ raw: String) {
        let host = Self.normalize(raw)
        guard !host.isEmpty else { return }
        if !hosts.contains(where: { $0.lowercased() == host }) {
            hosts.append(host)
            persist()
        }
    }

    func remove(_ host: String) {
        hosts.removeAll { $0.lowercased() == host.lowercased() }
        persist()
    }

    func resetToDefaults() {
        hosts = Self.defaults
        persist()
    }

    /// Bulk replace, used by settings-backup restore. Hosts in the
    /// new list are normalised (full URLs trimmed to host) and the
    /// existing list is dropped wholesale.
    func replaceAll(_ raw: [String]) {
        let normalised = raw.map { Self.normalize($0) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var out: [String] = []
        for h in normalised where !seen.contains(h) {
            seen.insert(h)
            out.append(h)
        }
        hosts = out
        persist()
    }

    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // Parse as URL when possible so we drop the scheme + path but
        // preserve the host + port together. `URL.host` strips ports,
        // so we reassemble them.
        if let url = URL(string: trimmed), let host = url.host {
            if let port = url.port {
                return "\(host.lowercased()):\(port)"
            }
            return host.lowercased()
        }
        return trimmed.lowercased()
    }

    /// Drop the in-memory cache and re-read from UserDefaults. Used by
    /// the wallet-wide reset path so the wipe surfaces immediately
    /// without waiting for a force-quit. If UserDefaults is empty
    /// `load()` reseeds with `defaults`, matching first-launch behaviour.
    func reload() {
        hosts = []
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            hosts = arr
        } else {
            hosts = Self.defaults
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
