// Wire format for a dApps catalog: a curated list of integrations
// that Maknoon can install into the Apps tab. By default Maknoon
// fetches the Maknoon dApps catalog published from the public
// elabify/maknoon-dapps repo via GitHub Pages; users can add additional
// catalog URLs in Settings > Apps so other institutions (issuers,
// verifier consortia, dApp aggregators) can publish their own lists.
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
    let apps: [AppStoreEntry]

    init(id: String, name: String, curator: String, summary: String, url: URL?, apps: [AppStoreEntry]) {
        self.id = id
        self.name = name
        self.curator = curator
        self.summary = summary
        self.url = url
        self.apps = apps
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
    /// Semantic version of the dApp being offered, e.g. "0.1.0". Shown at
    /// install time. Distinct from `MiniAppManifest.version` (the bundle
    /// cache key); for a single-version entry they should match.
    let version: String?
    /// Release channel. "beta" or "stable" (default stable when omitted).
    /// Drives the badge chip in place of the legacy `statusLabel`.
    let channel: String?
    /// Minimum Maknoon (app) version this dApp targets, e.g. "0.4.1".
    /// Used to render a compatibility badge. Omitted ⇒ "unknown support".
    let requiresMaknoonVersion: String?

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

// The built-in Maknoon dApps catalog, published from the public
// elabify/maknoon-dapps repo via GitHub Pages. Ships empty and is
// refreshed from `url` at runtime via `AppStoreRegistry.refresh()`; the
// catalog the server returns may legitimately contain no entries (and
// may 404 until the repo is (re)published, which the registry soft-fails).
enum DefaultAppStore {
    static let catalogURL = URL(string: "https://elabify.github.io/maknoon-dapps/catalog.json")!
    static let catalog = AppStoreCatalog(
        id: "elabify.maknoon-dapps",
        name: "Maknoon dApps",
        curator: "Elabify",
        summary: "First-party dApps curated by Elabify. Bundled with Maknoon; cannot be removed.",
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
