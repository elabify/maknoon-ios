// Native side of the mini-app JS bridge.
//
// The injected provider shim (MiniAppProvider.js) posts every privileged
// call as `{ id, namespace, method, params }` to the "maknoonBridge"
// message handler and awaits a reply. This class is that handler. It:
//   1. validates the message shape,
//   2. enforces the installed app's declared permissions (a call into a
//      namespace the app was not granted is refused before any handler
//      runs),
//   3. routes to the namespace handler ("eth" -> Web3BridgeHandler,
//      "maknoon" -> IdentityBridgeHandler, "host" -> built-in),
//   4. always replies with a JSON envelope { ok: true, result } or
//      { ok: false, error: { code, message } } so the shim can resolve or
//      reject the JS promise, including EIP-1193 error codes.
//
// Trust boundary: handlers run native code, show their own approval UI,
// and gate sensitive actions on Face ID. Nothing here ever hands key
// material back to JS.

import Foundation
import WebKit

/// EIP-1193 / bridge error with a numeric code the shim maps onto a
/// rejected promise. Codes follow EIP-1193 where applicable (4001 user
/// rejected, 4100 unauthorized, 4200 unsupported, -32602 invalid params,
/// -32603 internal).
struct MiniAppBridgeError: Error {
    let code: Int
    let message: String

    static func unsupported(_ what: String) -> MiniAppBridgeError {
        .init(code: 4200, message: "Unsupported: \(what)")
    }
    static func unauthorized(_ what: String) -> MiniAppBridgeError {
        .init(code: 4100, message: "Not authorized: \(what)")
    }
    static func userRejected() -> MiniAppBridgeError {
        .init(code: 4001, message: "User rejected the request")
    }
    static func invalidParams(_ what: String) -> MiniAppBridgeError {
        .init(code: -32602, message: "Invalid parameters: \(what)")
    }
    static func internalError(_ what: String) -> MiniAppBridgeError {
        .init(code: -32603, message: what)
    }
}

/// One JS namespace (e.g. "eth", "maknoon"). Returns a JSON-serializable
/// value or throws a `MiniAppBridgeError`.
@MainActor
protocol MiniAppNamespaceHandler: AnyObject {
    var namespace: String { get }
    /// Permission token (in `AppStoreEntry.permissions`) the app must hold
    /// to use this namespace. nil = always allowed.
    var requiredPermission: String? { get }
    func handle(method: String, params: Any?) async throws -> Any?
}

@MainActor
final class MiniAppBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "maknoonBridge"
    private static let category = "MiniApp"

    private let entry: AppStoreEntry
    private let granted: Set<String>
    private var handlers: [String: MiniAppNamespaceHandler] = [:]

    init(entry: AppStoreEntry, granted: Set<String>, handlers: [MiniAppNamespaceHandler]) {
        self.entry = entry
        self.granted = granted
        super.init()
        for h in handlers { self.handlers[h.namespace] = h }
        self.handlers["host"] = HostNamespaceHandler(entry: entry)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let namespace = body["namespace"] as? String,
              let method = body["method"] as? String else {
            replyHandler(Self.envelope(error: .invalidParams("malformed bridge message")), nil)
            return
        }
        let params = body["params"]

        guard let handler = handlers[namespace] else {
            replyHandler(Self.envelope(error: .unsupported("namespace \(namespace)")), nil)
            return
        }
        if let needed = handler.requiredPermission, !granted.contains(needed) {
            LogStore.shared.warn(Self.category, "app \(entry.id) called \(namespace).\(method) without '\(needed)' permission")
            replyHandler(Self.envelope(error: .unauthorized("app lacks '\(needed)' permission")), nil)
            return
        }

        Task { @MainActor in
            do {
                let result = try await handler.handle(method: method, params: params)
                replyHandler(Self.envelope(result: result), nil)
            } catch let e as MiniAppBridgeError {
                replyHandler(Self.envelope(error: e), nil)
            } catch {
                replyHandler(Self.envelope(error: .internalError(error.localizedDescription)), nil)
            }
        }
    }

    // MARK: -- envelope

    private static func envelope(result: Any?) -> [String: Any] {
        ["ok": true, "result": result ?? NSNull()]
    }
    private static func envelope(error: MiniAppBridgeError) -> [String: Any] {
        ["ok": false, "error": ["code": error.code, "message": error.message]]
    }
}

/// Built-in, always-available namespace: metadata + a ping for hello-world
/// bring-up. No permission required, no sensitive surface.
@MainActor
private final class HostNamespaceHandler: MiniAppNamespaceHandler {
    let namespace = "host"
    let requiredPermission: String? = nil
    private let entry: AppStoreEntry

    init(entry: AppStoreEntry) { self.entry = entry }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "ping":
            return "pong"
        case "appInfo":
            return [
                "id": entry.id,
                "title": entry.title,
                "permissions": Array(entry.grantedPermissions),
                "bridgeVersion": 1,
            ]
        default:
            throw MiniAppBridgeError.unsupported("host.\(method)")
        }
    }
}
