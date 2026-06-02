// Wire format for a dApps catalog: a curated list of integrations
// that Maknoon can install into the Apps tab. By default Maknoon
// fetches the Elabify-curated dApps catalog from musnad.elabify.com;
// users can add additional catalog URLs in Settings > Apps so other
// institutions (issuers, verifier consortia, dApp aggregators) can
// publish their own curated lists.
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
    let statusLabel: String   // "Live" / "Demo" / "Soon"
    let curatedBy: String     // human-readable curator label
}

// The built-in Elabify dApps catalog. Ships empty and is refreshed
// from `url` at runtime via `AppStoreRegistry.refresh()`; the catalog
// the server returns may legitimately contain no entries.
enum DefaultAppStore {
    static let catalog = AppStoreCatalog(
        id: "elabify.default",
        name: "Elabify dApps",
        curator: "Elabify",
        summary: "First-party dApps curated by Elabify. Bundled with Maknoon; cannot be removed.",
        url: URL(string: "https://musnad.elabify.com/dapps.json"),
        apps: []
    )
}

extension AppStoreEntry {
    /// Color tint for the status chip. Live = green, Demo = orange,
    /// everything else = secondary grey.
    var statusColor: Color {
        switch statusLabel.lowercased() {
        case "live": return .green
        case "demo": return .orange
        default:     return .secondary
        }
    }
}
