// Host-owned, per-app key-value settings for mini apps.
//
// Mini apps reach this through window.maknoon.storage (StorageBridgeHandler).
// The WebView's own localStorage is deliberately ephemeral (the host uses a
// non-persistent data store), so this is the ONLY durable storage a mini app
// has. Because it lives in UserDefaults under a single key that is listed in
// EncryptedBackup.walletStateKeys, mini-app settings ride the existing
// encrypted backup/restore for free (capture -> applyWalletState -> reload()).
//
// Settings are namespaced by the installed-app id ("<storeId>::<appId>"), so
// one mini app can never read or write another's bucket. Quotas keep a single
// app from bloating the backup blob.

import Foundation
import Observation

enum MiniAppSettingsError: LocalizedError {
    case valueTooLarge(maxBytes: Int)
    case tooManyKeys(max: Int)
    case appQuotaExceeded(maxBytes: Int)

    var errorDescription: String? {
        switch self {
        case .valueTooLarge(let m):    return "Value exceeds the \(m)-byte per-value limit."
        case .tooManyKeys(let m):      return "This app already has the maximum of \(m) settings."
        case .appQuotaExceeded(let m): return "This app's settings exceed the \(m)-byte limit."
        }
    }
}

@Observable
final class MiniAppSettingsStore: @unchecked Sendable {
    private static let storeKey = "miniapp.settings.v1"

    // Quotas (per installed app). Generous for config, tight enough that a
    // mini app can't turn the encrypted backup into a data dump.
    static let maxKeysPerApp = 64
    static let maxValueBytes = 8 * 1024
    static let maxAppBytes = 64 * 1024

    /// installedAppId -> (key -> value).
    private var byApp: [String: [String: String]] = [:]

    init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            byApp = decoded
        } else {
            byApp = [:]
        }
    }

    /// Drop in-memory state and re-read UserDefaults (post-restore sync).
    func reload() { load() }

    // MARK: -- per-app access

    func value(appId: String, key: String) -> String? {
        byApp[appId]?[key]
    }

    func all(appId: String) -> [String: String] {
        byApp[appId] ?? [:]
    }

    func keys(appId: String) -> [String] {
        Array((byApp[appId] ?? [:]).keys).sorted()
    }

    func set(appId: String, key: String, value: String) throws {
        guard value.utf8.count <= Self.maxValueBytes else {
            throw MiniAppSettingsError.valueTooLarge(maxBytes: Self.maxValueBytes)
        }
        var bucket = byApp[appId] ?? [:]
        if bucket[key] == nil && bucket.count >= Self.maxKeysPerApp {
            throw MiniAppSettingsError.tooManyKeys(max: Self.maxKeysPerApp)
        }
        bucket[key] = value
        guard byteSize(of: bucket) <= Self.maxAppBytes else {
            throw MiniAppSettingsError.appQuotaExceeded(maxBytes: Self.maxAppBytes)
        }
        byApp[appId] = bucket
        persist()
    }

    func remove(appId: String, key: String) {
        guard var bucket = byApp[appId] else { return }
        bucket.removeValue(forKey: key)
        if bucket.isEmpty { byApp.removeValue(forKey: appId) } else { byApp[appId] = bucket }
        persist()
    }

    /// Remove every setting for an app (called on uninstall).
    func evict(appId: String) {
        guard byApp[appId] != nil else { return }
        byApp.removeValue(forKey: appId)
        persist()
    }

    // MARK: -- persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(byApp) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func byteSize(of bucket: [String: String]) -> Int {
        bucket.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }
}
