// Low-friction native capabilities for mini apps:
//   * device  (auto)      — read host context + a Face ID gate for the dApp's
//                           own sensitive screens (returns only a bool).
//   * haptic  (auto)      — success/error/impact feedback.
//   * clipboard (install) — write-only copy (never reads the pasteboard).
//   * share   (install)   — system share sheet (user-mediated) + file export.
//   * wallet  (install)   — read the user's own wallet addresses per chain.
//
// Nothing here exposes raw sensors or keys: authenticate returns ok/!ok,
// device.info is non-secret context, wallet.getAccounts is public addresses.

import Foundation
import UIKit
import LocalAuthentication

@MainActor
final class DeviceBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "device"
    let requiredPermission: String? = nil
    private let store: HolderStore
    init(store: HolderStore) { self.store = store }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "device.info":
            let dark = UITraitCollection.current.userInterfaceStyle == .dark
            return [
                "theme": dark ? "dark" : "light",
                "locale": Locale.current.identifier,
                "fiatCode": store.fiatPreferences.code.uppercased(),
                "appVersion": MaknoonVersion.currentString,
            ]
        case "device.authenticate":
            let reason = (params as? [String: Any])?["reason"] as? String ?? "Authenticate"
            let ctx = LAContext()
            var err: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
                return ["ok": false, "reason": "unavailable"]
            }
            do {
                let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return ["ok": ok]
            } catch {
                return ["ok": false, "reason": "failed"]
            }
        default:
            throw MiniAppBridgeError.unsupported("device.\(method)")
        }
    }
}

@MainActor
final class HapticBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "haptic"
    let requiredPermission: String? = nil
    func handle(method: String, params: Any?) async throws -> Any? {
        guard method == "haptic.fire" else { throw MiniAppBridgeError.unsupported("haptic.\(method)") }
        let kind = (params as? [String: Any])?["kind"] as? String ?? "light"
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":   UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "heavy":   UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "medium":  UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default:        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        return NSNull()
    }
}

@MainActor
final class ClipboardBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "clipboard"
    let requiredPermission: String? = "clipboard"
    func handle(method: String, params: Any?) async throws -> Any? {
        guard method == "clipboard.write" else { throw MiniAppBridgeError.unsupported("clipboard.\(method)") }
        guard let text = (params as? [String: Any])?["text"] as? String else {
            throw MiniAppBridgeError.invalidParams("clipboard.write requires `text`")
        }
        UIPasteboard.general.string = text
        return NSNull()
    }
}

@MainActor
final class ShareBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "share"
    let requiredPermission: String? = "share"
    func handle(method: String, params: Any?) async throws -> Any? {
        let p = params as? [String: Any] ?? [:]
        var items: [Any] = []
        switch method {
        case "share.text":
            guard let text = p["text"] as? String else { throw MiniAppBridgeError.invalidParams("share.text requires `text`") }
            items = [text]
        case "share.file":
            // { fileName, text } -> write to a temp file and share it (e.g. a CSV receipt).
            guard let name = p["fileName"] as? String, let text = p["text"] as? String else {
                throw MiniAppBridgeError.invalidParams("share.file requires { fileName, text }")
            }
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
            do { try text.data(using: .utf8)?.write(to: url) } catch {
                throw MiniAppBridgeError.internalError("could not write file")
            }
            items = [url]
        default:
            throw MiniAppBridgeError.unsupported("share.\(method)")
        }
        guard let top = Self.topViewController() else {
            throw MiniAppBridgeError.internalError("no presenter")
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
        return NSNull()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

@MainActor
final class WalletBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "wallet"
    let requiredPermission: String? = "wallet"
    private let store: HolderStore
    init(store: HolderStore) { self.store = store }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "wallet.getAccounts":
            guard let chain = (params as? [String: Any])?["chain"] as? String,
                  let network = Self.network(for: chain) else {
                throw MiniAppBridgeError.invalidParams("wallet.getAccounts requires a known `chain`")
            }
            // The user's OWN wallets are mirrored into the address book as
            // system entries; surface just those (label + address).
            let own = store.addressBook.entriesGrouped(for: network).system
            return own.map { ["name": $0.name, "address": $0.address, "network": $0.network.rawValue] }
        default:
            // wallet.signMessage (multi-chain) is a planned follow-on; EVM apps
            // can personal_sign today via window.ethereum.
            throw MiniAppBridgeError.unsupported("wallet.\(method)")
        }
    }

    private static func network(for chain: String) -> AddressBookNetwork? {
        switch chain.lowercased() {
        case "bitcoin", "btc":  return .bitcoin
        case "ethereum", "evm": return .ethereum
        case "solana", "sol":   return .solana
        case "tron", "trx":     return .tron
        default: return nil
        }
    }
}
