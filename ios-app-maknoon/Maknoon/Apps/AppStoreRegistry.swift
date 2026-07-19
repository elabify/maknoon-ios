// Registry of configured apps catalogs + installed apps. Lives on
// HolderStore so views can observe and persist changes.
//
// Default state: the Maknoon apps catalog is always present
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
        /// Capability tokens the user accepted at install (and may later
        /// revoke). nil for apps installed before the consent model; those
        /// fall back to the entry's declared set via `grantedSet`.
        var grantedCapabilities: [String]?

        /// Effective granted capability set used for enforcement.
        var grantedSet: Set<String> {
            if let g = grantedCapabilities { return Set(g.map { $0.lowercased() }) }
            return entry.declaredCapabilityTokens   // back-compat
        }
    }

    /// Always-present Elabify built-in apps catalog. Not part of
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

    /// Installed-app id -> the newer catalog entry available for it, computed by
    /// `refresh()` by diffing each install's pinned manifest hash against the
    /// freshly-fetched catalog. Drives the non-blocking "update available"
    /// banner. Cleared for an app once the user applies its update.
    private(set) var updatesAvailable: [String: AppStoreEntry] = [:]

    /// When false (the default), beta-channel apps are hidden from the browse
    /// list. Installed apps are unaffected. Backed up via `walletStateKeys`.
    private(set) var showBetaApps: Bool = false

    private static let userStoresKey   = "appstore.userStores.v1"
    private static let installedAppsKey = "appstore.installed.v1"
    static let showBetaAppsKey         = "appstore.showBetaApps.v1"

    init() {
        load()
        migrateSeededDappsStore()
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
        // Absent key ⇒ false ⇒ beta apps hidden by default.
        showBetaApps = UserDefaults.standard.bool(forKey: Self.showBetaAppsKey)
    }

    /// Toggle whether beta-channel apps appear in the browse list (persisted).
    func setShowBetaApps(_ on: Bool) {
        showBetaApps = on
        UserDefaults.standard.set(on, forKey: Self.showBetaAppsKey)
    }

    /// A catalog entry is "beta" when its channel is exactly "beta"
    /// (case-insensitive). Pure + static so the browse filter is unit-testable.
    static func isBeta(_ entry: AppStoreEntry) -> Bool {
        (entry.channel ?? "").lowercased() == "beta"
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() { load() }

    /// Maknoon apps is now the built-in `defaultStore`. Earlier builds
    /// seeded it as a *user* store (alongside the retired "Elabify apps"
    /// default). Drop any user store that points at the default catalog URL
    /// so it doesn't appear twice. Idempotent.
    private func migrateSeededDappsStore() {
        let before = userStores.count
        userStores.removeAll { $0.url == DefaultAppStore.catalogURL }
        if userStores.count != before { persistStores() }
        // Retire the old one-shot seed flag if present.
        UserDefaults.standard.removeObject(forKey: "appstore.seeded.maknoon-dapps.v1")
    }

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
        recomputeUpdates()
        lastRefreshedAt = Date()
    }

    /// Diff each installed app's pinned manifest hash against the just-fetched
    /// catalog entry (same store, app id, channel). A different hash that is not
    /// a version downgrade is offered as an available update. Cheap + pure over
    /// in-memory state; safe to call after every refresh.
    private func recomputeUpdates() {
        var out: [String: AppStoreEntry] = [:]
        for inst in installedApps {
            guard inst.entry.isMiniApp, let pinned = inst.entry.manifestSha256 else { continue }
            guard let live = liveEntry(storeId: inst.storeId, appId: inst.appId, channel: inst.entry.channel),
                  live.isMiniApp, let liveSha = live.manifestSha256 else { continue }
            if liveSha.lowercased() == pinned.lowercased() { continue }   // same bundle
            // Ignore downgrades: only offer an update when the live version is
            // not older than what is installed (missing/unparseable versions
            // are treated as offerable, since the hash already differs).
            if let lv = live.version.flatMap(SemVer.init),
               let iv = inst.entry.version.flatMap(SemVer.init), lv < iv { continue }
            out[inst.id] = live
        }
        updatesAvailable = out
    }

    /// The current catalog entry matching an installed app's store, id, and
    /// channel. Prefers a same-channel match, falling back to any same-id entry.
    private func liveEntry(storeId: String, appId: String, channel: String?) -> AppStoreEntry? {
        let apps: [AppStoreEntry]
        if storeId == defaultStore.id {
            apps = defaultStore.apps
        } else if let s = userStores.first(where: { $0.id == storeId }) {
            apps = s.cachedCatalog?.apps ?? []
        } else {
            return nil
        }
        return apps.first { $0.id == appId && ($0.channel ?? "") == (channel ?? "") }
            ?? apps.first { $0.id == appId }
    }

    /// The newer entry available for an installed app, if any (banner query).
    func availableUpdate(forInstalledAppId id: String) -> AppStoreEntry? {
        updatesAvailable[id]
    }

    /// Adopt the newer catalog entry for an installed app (user tapped
    /// "Update"). Swaps the pinned snapshot so the next open downloads + serves
    /// the new bundle, preserving the user's existing capability grants, and
    /// eagerly prefetches the new bundle. Returns the adopted entry so the host
    /// view can reload with it. The old bundle stays cached and keeps working
    /// until this is called.
    @discardableResult
    func applyUpdate(installedAppId: String) -> AppStoreEntry? {
        guard let newer = updatesAvailable[installedAppId],
              let idx = installedApps.firstIndex(where: { $0.id == installedAppId }) else { return nil }
        let old = installedApps[idx]
        installedApps[idx] = InstalledApp(
            id: old.id,
            storeId: old.storeId,
            appId: old.appId,
            installedAt: old.installedAt,
            entry: newer,
            grantedCapabilities: old.grantedCapabilities
        )
        updatesAvailable[installedAppId] = nil
        persistInstalled()
        prefetchBundle(newer, installedAppId: installedAppId)
        return newer
    }

    /// Best-effort background download + verify + cache of an entry's bundle, so
    /// a later open serves it offline (and, for a fresh install, so the bits are
    /// on the phone before the first open). Failures are non-fatal: the open
    /// path re-downloads if the cache is still cold. No-op for metadata-only
    /// (non-mini-app) entries.
    private func prefetchBundle(_ entry: AppStoreEntry, installedAppId: String) {
        guard entry.isMiniApp, let url = entry.manifestURL, let sha = entry.manifestSha256 else { return }
        let appId = entry.id
        Task.detached(priority: .utility) {
            _ = try? await MiniAppBundleStore.shared.ensureBundle(
                installedAppId: installedAppId, appId: appId,
                manifestURL: url, manifestSha256: sha)
        }
    }

    /// One catalog fetch. Returns nil on any non-2xx, transport
    /// error, or decode failure so the caller can keep what it had.
    private static func fetchCatalog(from url: URL) async -> AppStoreCatalog? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // Always pull the LIVE catalog. GitHub Pages serves catalog.json
        // with `Cache-Control: max-age=600`, so the default policy could
        // hand back a stale catalog whose pinned manifestSha256 no longer
        // matches the published bundle, snapshotting an out-of-date pin at
        // install and failing the integrity check at open. Bypass the cache.
        req.cachePolicy = .reloadIgnoringLocalCacheData
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

    /// Install, granting `granted` capability tokens (default: everything the
    /// entry declares). The install UI passes the set the user accepted.
    func install(_ entry: AppStoreEntry, fromStore storeId: String, granted: Set<String>? = nil) {
        let tokens = granted ?? entry.declaredCapabilityTokens
        // Upsert: replace any existing install of this app id so picking a
        // different channel swaps the snapshotted manifest (a channel switch),
        // rather than being a no-op.
        installedApps.removeAll { $0.storeId == storeId && $0.appId == entry.id }
        let installedAppId = "\(storeId)::\(entry.id)"
        installedApps.append(InstalledApp(
            id: installedAppId,
            storeId: storeId,
            appId: entry.id,
            installedAt: Date(),
            entry: entry,
            grantedCapabilities: Array(tokens).sorted()
        ))
        // A freshly-installed app is on its newest pin, so it never carries a
        // pending update. Drop any stale flag from a prior install of this id.
        updatesAvailable[installedAppId] = nil
        persistInstalled()
        // Download the bits now so the first open works offline and never has
        // to hit the network (which is what breaks after an upstream re-publish).
        prefetchBundle(entry, installedAppId: installedAppId)
    }

    /// Replace an installed app's granted capability set (review/revoke UI).
    func setGrantedCapabilities(installedAppId: String, _ tokens: Set<String>) {
        guard let idx = installedApps.firstIndex(where: { $0.id == installedAppId }) else { return }
        installedApps[idx].grantedCapabilities = Array(tokens).sorted()
        persistInstalled()
    }

    func uninstall(installedAppId: String) {
        installedApps.removeAll { $0.id == installedAppId }
        updatesAvailable[installedAppId] = nil
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
