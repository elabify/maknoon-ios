// Registry of configured dApps catalogs + installed apps. Lives on
// HolderStore so views can observe and persist changes.
//
// Default state: the Elabify curated dApps catalog is always present
// (it ships with the app and cannot be removed). The user can add
// other catalog URLs in Settings > Apps. `refresh()` fetches every
// catalog URL (the built-in one plus any user-added) and populates
// each catalog's `apps` from the network; a catalog that returns no
// entries simply renders empty.
//
// Installed apps are referenced by `storeId + appId` so the same
// app id appearing in two different catalogs can be installed
// independently if the user opts in.

import Foundation
import Observation

@Observable
final class AppStoreRegistry: @unchecked Sendable {
    struct UserStoreRef: Codable, Identifiable, Hashable, Sendable {
        let id: String
        var name: String
        var url: URL
        /// Local cache of the last successfully-fetched catalog. Nil
        /// until the first fetch lands. The catalog id inside should
        /// match `id`.
        var cachedCatalog: AppStoreCatalog?
    }

    struct InstalledApp: Codable, Identifiable, Hashable, Sendable {
        let id: String          // "<storeId>::<appId>"
        let storeId: String
        let appId: String
        let installedAt: Date
        /// Snapshot of the app entry at install time. Used to render
        /// the Apps tab without needing the store to be online.
        let entry: AppStoreEntry
    }

    /// Always-present Elabify built-in dApps catalog. Not part of
    /// `userStores`. Starts as the bundled (empty) catalog and is
    /// replaced in place when `refresh()` fetches its URL.
    private(set) var defaultStore: AppStoreCatalog = DefaultAppStore.catalog

    /// Set while a `refresh()` is in flight (for a spinner / pull-to-
    /// refresh affordance). Last successful refresh timestamp.
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?

    /// Additional appstores configured by the user.
    private(set) var userStores: [UserStoreRef] = []

    /// Apps the user has installed into the Apps tab.
    private(set) var installedApps: [InstalledApp] = []

    private static let userStoresKey   = "appstore.userStores.v1"
    private static let installedAppsKey = "appstore.installed.v1"

    init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.userStoresKey),
           let stores = try? JSONDecoder().decode([UserStoreRef].self, from: data) {
            userStores = stores
        } else {
            userStores = []
        }
        if let data = UserDefaults.standard.data(forKey: Self.installedAppsKey),
           let apps = try? JSONDecoder().decode([InstalledApp].self, from: data) {
            installedApps = apps
        } else {
            installedApps = []
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() { load() }

    // MARK: -- store management

    func addStore(name: String, url: URL) {
        let id = "user.\(UUID().uuidString)"
        userStores.append(UserStoreRef(id: id, name: name, url: url, cachedCatalog: nil))
        persistStores()
    }

    func removeStore(id: String) {
        userStores.removeAll { $0.id == id }
        // Removing a store leaves its installed apps alone; the user
        // can uninstall them from the Apps tab.
        persistStores()
    }

    // MARK: -- remote fetch

    /// Fetch the built-in Elabify catalog and every user-added
    /// catalog, replacing each catalog's contents in place. Soft-
    /// fails: a 404, timeout, or malformed body leaves the previous
    /// (or bundled-empty) catalog untouched, so the Apps tab never
    /// surfaces a network error, it just shows whatever it last had.
    @MainActor
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        if let url = DefaultAppStore.catalog.url,
           let fetched = await Self.fetchCatalog(from: url) {
            defaultStore = fetched
        }

        for idx in userStores.indices {
            if let fetched = await Self.fetchCatalog(from: userStores[idx].url) {
                userStores[idx].cachedCatalog = fetched
            }
        }
        persistStores()
        lastRefreshedAt = Date()
    }

    /// One catalog fetch. Returns nil on any non-2xx, transport
    /// error, or decode failure so the caller can keep what it had.
    private static func fetchCatalog(from url: URL) async -> AppStoreCatalog? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode else { return nil }
            return try JSONDecoder().decode(AppStoreCatalog.self, from: data)
        } catch {
            return nil
        }
    }

    /// All known catalogs (default + user-added). User-added stores
    /// without a cached catalog appear with an empty `apps` array.
    var allCatalogs: [AppStoreCatalog] {
        var out: [AppStoreCatalog] = [defaultStore]
        for s in userStores {
            if let cached = s.cachedCatalog {
                out.append(cached)
            } else {
                out.append(AppStoreCatalog(
                    id: s.id,
                    name: s.name,
                    curator: s.name,
                    summary: "Pending fetch. The catalog has not been downloaded yet.",
                    url: s.url,
                    apps: []
                ))
            }
        }
        return out
    }

    // MARK: -- installation

    func isInstalled(storeId: String, appId: String) -> Bool {
        installedApps.contains { $0.storeId == storeId && $0.appId == appId }
    }

    func install(_ entry: AppStoreEntry, fromStore storeId: String) {
        guard !isInstalled(storeId: storeId, appId: entry.id) else { return }
        installedApps.append(InstalledApp(
            id: "\(storeId)::\(entry.id)",
            storeId: storeId,
            appId: entry.id,
            installedAt: Date(),
            entry: entry
        ))
        persistInstalled()
    }

    func uninstall(installedAppId: String) {
        installedApps.removeAll { $0.id == installedAppId }
        persistInstalled()
    }

    // MARK: -- persistence

    private func persistStores() {
        if let data = try? JSONEncoder().encode(userStores) {
            UserDefaults.standard.set(data, forKey: Self.userStoresKey)
        }
    }

    private func persistInstalled() {
        if let data = try? JSONEncoder().encode(installedApps) {
            UserDefaults.standard.set(data, forKey: Self.installedAppsKey)
        }
    }
}
