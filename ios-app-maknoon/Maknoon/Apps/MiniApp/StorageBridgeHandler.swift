// "storage" namespace handler (window.maknoon.storage).
//
// A durable, backed-up key-value store for the mini app's own settings.
// Always available (no permission needed): it is strictly sandboxed to the
// calling app's installed-app id, so an app can only read/write its own
// bucket. Backed by MiniAppSettingsStore (UserDefaults + encrypted backup).

import Foundation

@MainActor
final class StorageBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "storage"
    let requiredPermission: String? = nil

    private let installedAppId: String
    private let store: MiniAppSettingsStore

    init(installedAppId: String, store: MiniAppSettingsStore) {
        self.installedAppId = installedAppId
        self.store = store
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "storage.get":
            let key = try requireKey(params)
            return store.value(appId: installedAppId, key: key) ?? NSNull()
        case "storage.set":
            let key = try requireKey(params)
            guard let value = (params as? [String: Any])?["value"] as? String else {
                throw MiniAppBridgeError.invalidParams("storage.set requires a string `value`")
            }
            do {
                try store.set(appId: installedAppId, key: key, value: value)
            } catch {
                throw MiniAppBridgeError.invalidParams((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            return NSNull()
        case "storage.remove":
            let key = try requireKey(params)
            store.remove(appId: installedAppId, key: key)
            return NSNull()
        case "storage.keys":
            return store.keys(appId: installedAppId)
        default:
            throw MiniAppBridgeError.unsupported("storage.\(method)")
        }
    }

    private func requireKey(_ params: Any?) throws -> String {
        guard let key = (params as? [String: Any])?["key"] as? String, !key.isEmpty else {
            throw MiniAppBridgeError.invalidParams("requires a non-empty string `key`")
        }
        return key
    }
}
