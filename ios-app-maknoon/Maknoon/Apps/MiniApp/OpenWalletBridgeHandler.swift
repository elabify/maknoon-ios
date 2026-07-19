// window.maknoon.walletView.open({ chainId?, address? })
//
// After a swap (or any tx), a mini app can ask the host to leave the sandbox and
// open the user's Ethereum wallet on the chain the tx used, so they can watch it
// confirm. The handler only records the request on a coordinator; MiniAppHostView
// observes it and performs the navigation (activate the matching wallet + chain,
// switch to the Wallet tab, dismiss the mini app). Registered only for EVM-capable
// apps (see MiniAppHostView), so it needs no permission token of its own, same
// posture as PoolRegistryBridgeHandler.

import Foundation
import Observation

@MainActor
@Observable
final class MiniAppOpenWalletCoordinator {
    struct Request: Equatable {
        let chainId: UInt64?
        let address: String?
    }
    /// Set by the bridge handler; observed + cleared by MiniAppHostView.
    var request: Request?
}

@MainActor
final class OpenWalletBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "walletView"
    let requiredPermission: String? = nil

    private let coordinator: MiniAppOpenWalletCoordinator
    init(coordinator: MiniAppOpenWalletCoordinator) { self.coordinator = coordinator }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "walletView.open":
            let opts = params as? [String: Any]
            coordinator.request = .init(
                chainId: Self.parseChainId(opts?["chainId"]),
                address: opts?["address"] as? String)
            return NSNull()
        default:
            throw MiniAppBridgeError.unsupported("walletView.\(method)")
        }
    }

    /// Accept a JS number (84532) or hex/decimal string ("0x14a34" / "84532").
    private static func parseChainId(_ any: Any?) -> UInt64? {
        switch any {
        case let n as NSNumber: return n.uint64Value
        case let s as String:
            if s.hasPrefix("0x") { return UInt64(s.dropFirst(2), radix: 16) }
            return UInt64(s)
        default: return nil
        }
    }
}
