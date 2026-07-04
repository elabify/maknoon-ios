// Wire format for a apps catalog: a curated list of integrations
// that Maknoon can install into the Apps tab. By default Maknoon
// fetches the Maknoon apps catalog published from the public
// elabify/maknoon-dapps repo via GitHub Pages; users can add additional
// catalog URLs in Settings > Apps so other institutions (issuers,
// verifier consortia, app aggregators) can publish their own lists.
//
// `AppStoreRegistry.refresh()` fetches each catalog URL and decodes
// the JSON into this shape. A catalog that returns no entries simply
// renders an empty list.

import Foundation
import SwiftUI

struct AppStoreCatalog: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let curator: String
    let summary: String
    let url: URL?
    /// Always flat in memory: a v2 (`catalogFormat: 2`) catalog is expanded at
    /// decode time into one entry per channel, all sharing the app `id`, so the
    /// browse view groups them into a single tile (ADR-0052).
    let apps: [AppStoreEntry]

    init(id: String, name: String, curator: String, summary: String, url: URL?, apps: [AppStoreEntry]) {
        self.id = id
        self.name = name
        self.curator = curator
        self.summary = summary
        self.url = url
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, curator, summary, url, apps, catalogFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "catalog"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Apps"
        curator = try c.decodeIfPresent(String.self, forKey: .curator) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        let format = try c.decodeIfPresent(Int.self, forKey: .catalogFormat) ?? 1
        if format >= 2 {
            let v2 = try c.decodeIfPresent([AppStoreCatalogV2App].self, forKey: .apps) ?? []
            apps = v2.flatMap { $0.expanded() }
        } else {
            apps = try c.decodeIfPresent([AppStoreEntry].self, forKey: .apps) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        // Persist the flat (v1) form; v2 is a wire-only input shape.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(curator, forKey: .curator)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(apps, forKey: .apps)
    }
}

/// ADR-0052 `catalogFormat: 2` app: one id with optional per-channel releases.
/// Decode-only; expanded into flat `AppStoreEntry` values sharing the app id.
private struct AppStoreCatalogV2App: Decodable {
    let id: String
    let title: String
    let summary: String?
    let details: String?
    let iconName: String?
    let curatedBy: String?
    let stable: Channel?
    let beta: Channel?

    struct Channel: Decodable {
        let version: String?
        let manifestURL: URL?
        let manifestSha256: String?
        let requiresMaknoonVersion: String?
        let supersededAtMaknoonVersion: String?
        let permissions: [String]?
        let capabilities: [AppStoreEntry.DeclaredCapability]?
    }

    func expanded() -> [AppStoreEntry] {
        var out: [AppStoreEntry] = []
        func make(_ ch: Channel, channel: String) -> AppStoreEntry {
            AppStoreEntry(
                id: id,
                title: title,
                summary: summary ?? "",
                details: details ?? "",
                iconName: iconName ?? "app.badge",
                statusLabel: channel.prefix(1).uppercased() + channel.dropFirst(),
                curatedBy: curatedBy ?? "",
                version: ch.version,
                channel: channel,
                requiresMaknoonVersion: ch.requiresMaknoonVersion,
                supersededAtMaknoonVersion: ch.supersededAtMaknoonVersion,
                manifestURL: ch.manifestURL,
                manifestSha256: ch.manifestSha256,
                permissions: ch.permissions,
                capabilities: ch.capabilities
            )
        }
        if let s = stable { out.append(make(s, channel: "stable")) }
        if let b = beta { out.append(make(b, channel: "beta")) }
        return out
    }
}

struct AppStoreEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let details: String
    /// SF Symbol name. Apps published by third-party stores can
    /// override with a "url" prefix later; for now SF Symbols only.
    let iconName: String
    let statusLabel: String   // legacy "Live"/"Demo"/"Soon"; superseded by `channel`
    let curatedBy: String     // human-readable curator label

    // --- Versioning / release channel (all optional) ------------------
    /// Semantic version of the app being offered, e.g. "0.1.0". Shown at
    /// install time. Distinct from `MiniAppManifest.version` (the bundle
    /// cache key); for a single-version entry they should match.
    let version: String?
    /// Release channel. "beta" or "stable" (default stable when omitted).
    /// Drives the badge chip in place of the legacy `statusLabel`.
    let channel: String?
    /// Minimum Maknoon (app) version this app targets, e.g. "0.4.1".
    /// Used to render a compatibility badge. Omitted ⇒ "unknown support".
    let requiresMaknoonVersion: String?
    /// Upper bound: the Maknoon (app) version at/above which this app version
    /// is superseded (no longer supported). Omitted ⇒ no upper bound. Compatible
    /// iff `requiresMaknoonVersion` ≤ host < `supersededAtMaknoonVersion`.
    let supersededAtMaknoonVersion: String?

    // --- Mini-app fields (all optional) -------------------------------
    // An entry that carries a `manifestURL` is a runnable mini app: an
    // HTML/CSS/JS bundle Maknoon downloads, integrity-checks, caches, and
    // serves into a sandboxed WKWebView. Entries without these fields are
    // metadata-only catalog rows (the original behavior) and decode
    // unchanged, so old catalogs keep working.

    /// URL of the app's `manifest.json` (see `MiniAppManifest`). The
    /// manifest lists every file in the bundle with its SHA-256. Files
    /// are fetched relative to the manifest's directory.
    let manifestURL: URL?
    /// SHA-256 (lowercase hex) of the raw manifest.json bytes, pinned by
    /// the catalog curator. A mismatch refuses to load the app. This is
    /// the single root-of-trust hash; per-file hashes chain off it.
    let manifestSha256: String?
    /// Legacy capability tokens (back-compat). Superseded by `capabilities`
    /// when that's present. Known values: "identity", "payment", "evm", …
    let permissions: [String]?
    /// Declared capabilities with a per-app reason string shown at install.
    /// When present this supersedes `permissions`. Tokens match the registry
    /// in `MiniAppCapability.swift`.
    let capabilities: [DeclaredCapability]?

    struct DeclaredCapability: Codable, Hashable, Sendable {
        let name: String
        let reason: String?
    }

    init(
        id: String,
        title: String,
        summary: String,
        details: String,
        iconName: String,
        statusLabel: String,
        curatedBy: String,
        version: String? = nil,
        channel: String? = nil,
        requiresMaknoonVersion: String? = nil,
        supersededAtMaknoonVersion: String? = nil,
        manifestURL: URL? = nil,
        manifestSha256: String? = nil,
        permissions: [String]? = nil,
        capabilities: [DeclaredCapability]? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.details = details
        self.iconName = iconName
        self.statusLabel = statusLabel
        self.curatedBy = curatedBy
        self.version = version
        self.channel = channel
        self.requiresMaknoonVersion = requiresMaknoonVersion
        self.supersededAtMaknoonVersion = supersededAtMaknoonVersion
        self.manifestURL = manifestURL
        self.manifestSha256 = manifestSha256
        self.permissions = permissions
        self.capabilities = capabilities
    }

    /// True when this entry is a runnable mini app (vs a metadata-only row).
    var isMiniApp: Bool { manifestURL != nil && manifestSha256 != nil }

    /// Granted capability set, lowercased. Empty when none declared.
    var grantedPermissions: Set<String> {
        declaredCapabilityTokens
    }

    /// All capability tokens this entry declares (from `capabilities` if
    /// present, else the legacy `permissions`), lowercased.
    var declaredCapabilityTokens: Set<String> {
        if let caps = capabilities, !caps.isEmpty {
            return Set(caps.map { $0.name.lowercased() })
        }
        return Set((permissions ?? []).map { $0.lowercased() })
    }

    /// The per-capability reason to show at install: the catalog-provided
    /// reason, falling back to the registry default. Keyed by token.
    func reason(for token: String) -> String {
        if let caps = capabilities,
           let match = caps.first(where: { $0.name.lowercased() == token.lowercased() }),
           let r = match.reason, !r.isEmpty {
            return r
        }
        return MiniAppCapabilityRegistry.spec(token)?.reason ?? token
    }
}

// The built-in Maknoon apps catalog, published from the public
// elabify/maknoon-dapps repo via GitHub Pages. Ships empty and is
// refreshed from `url` at runtime via `AppStoreRegistry.refresh()`; the
// catalog the server returns may legitimately contain no entries (and
// may 404 until the repo is (re)published, which the registry soft-fails).
enum DefaultAppStore {
    static let catalogURL = URL(string: "https://elabify.github.io/maknoon-dapps/catalog.json")!
    static let catalog = AppStoreCatalog(
        id: "elabify.maknoon-dapps",
        name: "Maknoon Apps",
        curator: "Elabify",
        summary: "First-party Apps bundled with Maknoon; cannot be removed.",
        url: catalogURL,
        apps: []
    )
}

extension AppStoreEntry {
    /// Badge text for the release chip: the channel ("Beta"/"Stable"),
    /// falling back to the legacy `statusLabel` for old catalogs.
    var channelLabel: String {
        if let c = channel, !c.isEmpty { return c.prefix(1).uppercased() + c.dropFirst().lowercased() }
        return statusLabel
    }

    /// Color tint for the release chip. Beta = orange, Stable = green,
    /// otherwise grey (covers legacy Live/Demo/Soon too).
    var statusColor: Color {
        switch channelLabel.lowercased() {
        case "stable", "live": return .green
        case "beta", "demo":   return .orange
        default:               return .secondary
        }
    }
}
