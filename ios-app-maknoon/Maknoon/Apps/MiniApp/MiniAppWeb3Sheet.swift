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
    /// One selectable EVM wallet in the connect sheet's picker.
    struct WalletChoice: Identifiable, Equatable {
        let id: UUID
        let label: String
        let address: String
    }

    enum Kind: Equatable {
        /// Connect approval; `wallets` lists the app's EVM wallets so the user can
        /// pick which one to connect (the picker only shows when there is >1).
        case connect(wallets: [WalletChoice], activeId: UUID?)
        case signMessage(preview: String)
        case signTypedData(domain: String, preview: String)
        /// `summary` is a decoded action line (nil for a native send); `dataHex`
        /// is the raw calldata for a contract call (nil for a native send).
        case sendTransaction(to: String, amountEth: String, network: String, summary: String?, dataHex: String?)
        case switchChain(fromName: String, toName: String, toChainId: String)
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
    /// Called on connect approval with the wallet the user picked, so the host
    /// can make it active before the bridge returns its address.
    var onSelectWallet: (UUID) -> Void = { _ in }

    @State private var working = false
    @State private var authError: String?
    /// Selected wallet id for the connect picker (defaults to the active one).
    @State private var pickedWalletId: UUID?

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
        case .connect(let wallets, let activeId):
            let selected = pickedWalletId ?? activeId ?? wallets.first?.id
            let current = wallets.first(where: { $0.id == selected }) ?? wallets.first
            Section("Connect wallet") {
                Text("This app wants to see your Ethereum address.")
                    .font(.callout).foregroundStyle(.secondary)
                if wallets.count > 1 {
                    Picker("Wallet", selection: Binding(
                        get: { selected },
                        set: { pickedWalletId = $0 }
                    )) {
                        ForEach(wallets) { w in
                            Text(w.label).tag(Optional(w.id))
                        }
                    }
                } else if let only = current {
                    LabeledContent("Wallet", value: only.label)
                }
                if let addr = current?.address {
                    Text(addr).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        case .signMessage(let preview):
            Section("Sign message") {
                Text("This app wants you to sign a message. No transaction will be sent.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        case .signTypedData(let domain, let preview):
            Section("Sign typed data") {
                Text("This app wants you to sign structured data (EIP-712). No transaction will be sent.")
                    .font(.callout).foregroundStyle(.secondary)
                if !domain.isEmpty { LabeledContent("Domain", value: domain) }
                Text(preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        case .sendTransaction(let to, let amountEth, let network, let summary, let dataHex):
            Section("Send transaction") {
                LabeledContent("Network", value: network)
                if let summary { LabeledContent("Action", value: summary) }
                LabeledContent("Amount", value: "\(amountEth) ETH")
                VStack(alignment: .leading, spacing: 2) {
                    Text("To").font(.caption).foregroundStyle(.secondary)
                    Text(to).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let dataHex, !dataHex.isEmpty {
                Section("Contract data (advanced)") {
                    if summary == nil {
                        Text("This is a contract call the wallet could not decode. Only continue if you trust this app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(dataHex).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(6)
                }
            }
        case .switchChain(let fromName, let toName, _):
            Section("Switch network") {
                Text("This app wants to switch the active network.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("From", value: fromName)
                LabeledContent("To", value: toName)
            }
        }
    }

    private var title: String {
        switch request.kind {
        case .connect: return "Connect"
        case .signMessage: return "Sign message"
        case .signTypedData: return "Sign typed data"
        case .sendTransaction: return "Confirm send"
        case .switchChain: return "Switch network"
        }
    }
    private var confirmLabel: String {
        switch request.kind {
        case .connect: return "Connect"
        case .signMessage, .signTypedData: return "Sign"
        case .sendTransaction: return "Send"
        case .switchChain: return "Switch"
        }
    }
    private var reason: String {
        switch request.kind {
        case .connect: return "Connect your wallet to \(request.appTitle)"
        case .signMessage: return "Sign a message for \(request.appTitle)"
        case .signTypedData: return "Sign typed data for \(request.appTitle)"
        case .sendTransaction: return "Authorize sending from your wallet"
        case .switchChain: return "Switch network for \(request.appTitle)"
        }
    }

    private func approve() async {
        working = true
        defer { working = false }
        // Connect + network switch touch no key material; skip biometrics.
        switch request.kind {
        case .connect(let wallets, let activeId):
            if let chosen = pickedWalletId ?? activeId ?? wallets.first?.id {
                onSelectWallet(chosen)
            }
            onApprove(); return
        case .switchChain: onApprove(); return
        default: break
        }
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
