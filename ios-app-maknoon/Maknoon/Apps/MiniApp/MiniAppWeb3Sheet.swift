// Approval coordinator + sheet for window.ethereum (EIP-1193).
//
// Like the identity coordinator, the Web3BridgeHandler can't present
// SwiftUI, so it routes connect / sign-message / send-transaction
// approvals through this coordinator. The host observes `active` and
// presents the sheet. Approve runs a Face ID check then resumes the
// continuation; cancel / dismiss resumes with userRejected.
//
// The wallet and account are the user's active Ethereum wallet; the demo
// does not offer account selection. Every privileged web3 call therefore
// boils down to a yes/no consent over a clearly described action.

import SwiftUI
import LocalAuthentication

@MainActor
@Observable
final class MiniAppWeb3Coordinator {
    enum Kind: Equatable {
        case connect(address: String)
        case signMessage(preview: String)
        case sendTransaction(to: String, amountEth: String, network: String)
    }

    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        let kind: Kind
    }

    private(set) var active: Request?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Present an approval and await the user. Throws userRejected on
    /// decline. Returns normally when approved (after Face ID).
    func present(appTitle: String, kind: Kind) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            self.active = Request(appTitle: appTitle, kind: kind)
        }
    }

    func approve() {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(returning: ())
    }

    func cancel() {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}

struct MiniAppWeb3Sheet: View {
    let request: MiniAppWeb3Coordinator.Request
    let onApprove: () -> Void
    let onCancel: () -> Void

    @State private var working = false
    @State private var authError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(request.appTitle, systemImage: "square.grid.2x2.fill").font(.headline)
                }
                detailSection
                if let authError {
                    Section { Text(authError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) { Task { await approve() } }.disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        switch request.kind {
        case .connect(let address):
            Section("Connect wallet") {
                Text("This app wants to see your Ethereum address.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(address).font(.caption.monospaced()).textSelection(.enabled)
            }
        case .signMessage(let preview):
            Section("Sign message") {
                Text("This app wants you to sign a message. No transaction will be sent.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        case .sendTransaction(let to, let amountEth, let network):
            Section("Send transaction") {
                LabeledContent("Network", value: network)
                LabeledContent("Amount", value: "\(amountEth) ETH")
                VStack(alignment: .leading, spacing: 2) {
                    Text("To").font(.caption).foregroundStyle(.secondary)
                    Text(to).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var title: String {
        switch request.kind {
        case .connect: return "Connect"
        case .signMessage: return "Sign message"
        case .sendTransaction: return "Confirm send"
        }
    }
    private var confirmLabel: String {
        switch request.kind {
        case .connect: return "Connect"
        case .signMessage: return "Sign"
        case .sendTransaction: return "Send"
        }
    }
    private var reason: String {
        switch request.kind {
        case .connect: return "Connect your wallet to \(request.appTitle)"
        case .signMessage: return "Sign a message for \(request.appTitle)"
        case .sendTransaction: return "Authorize sending from your wallet"
        }
    }

    private func approve() async {
        working = true
        defer { working = false }
        // Connect is low-risk (address is public); skip biometrics for it.
        if case .connect = request.kind { onApprove(); return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            onApprove(); return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { onApprove() } else { authError = "Authentication failed." }
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "Authentication canceled."
        }
    }
}
