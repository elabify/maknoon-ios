// window.maknoon.scan() — a native QR/barcode scanner for mini apps.
//
// The dApp never gets the camera stream; it gets back the decoded string.
// Gated by the "scan" capability + the OS camera permission + this explicit
// sheet (the user sees what they're pointing at and can cancel).

import SwiftUI

@MainActor
@Observable
final class MiniAppScanCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        let prompt: String?
    }
    private(set) var active: Request?
    private var continuation: CheckedContinuation<String, Error>?

    func present(appTitle: String, prompt: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = Request(appTitle: appTitle, prompt: prompt)
        }
    }
    func resolve(_ code: String) {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(returning: code)
    }
    func cancel() {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}

struct MiniAppScanSheet: View {
    let request: MiniAppScanCoordinator.Request
    let onCode: (String) -> Void
    let onCancel: () -> Void
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(request.prompt ?? "Scan a code").font(.callout).foregroundStyle(.secondary)
                QRScannerView(onCode: { code in
                    guard !done else { return }
                    done = true
                    onCode(code)
                })
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                QRPhotoPickerButton(onCode: { code in
                    guard !done else { return }
                    done = true
                    onCode(code)
                }) {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .navigationTitle(request.appTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
        }
    }
}

@MainActor
final class ScanBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "scan"
    let requiredPermission: String? = "scan"
    private let appTitle: String
    private let coordinator: MiniAppScanCoordinator

    init(appTitle: String, coordinator: MiniAppScanCoordinator) {
        self.appTitle = appTitle
        self.coordinator = coordinator
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        guard method == "scan.read" else { throw MiniAppBridgeError.unsupported("scan.\(method)") }
        let prompt = (params as? [String: Any])?["prompt"] as? String
        let code = try await coordinator.present(appTitle: appTitle, prompt: prompt)
        return ["value": code]
    }
}
