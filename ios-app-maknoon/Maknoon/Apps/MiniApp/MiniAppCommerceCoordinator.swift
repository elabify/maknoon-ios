// Presents the native merchant "Verify & Pay" sheet for the commerce bridge and
// suspends the app's `commerce.collectAndCharge` call until it resolves
// (ADR-0031). Mirrors MiniAppCollectCoordinator.

import SwiftUI

@MainActor
@Observable
final class MiniAppCommerceCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        /// The merchant install whose verifier key signs the request; needed so
        /// the QR sheet can re-mint a fresh request when this one expires.
        let installedAppId: String
        let commerce: CommerceRequest
        /// Ephemeral keypair (merchant) the holder seals its response to; held
        /// only on this device to decrypt the polled response (server-blind).
        let responseKeypair: TransportHolder
    }

    private(set) var active: Request?
    private var continuation: CheckedContinuation<[String: Any], Error>?

    func present(_ r: Request) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = r
        }
    }

    func resolve(_ result: [String: Any]) {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(returning: result)
    }

    func cancel() {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}
