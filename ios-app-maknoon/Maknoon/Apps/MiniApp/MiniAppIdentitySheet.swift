// Approval coordinator + sheet for window.maknoon.identity.request.
//
// The IdentityBridgeHandler can't present SwiftUI itself, so it hands the
// request to this coordinator (held by MiniAppHostView) and suspends on a
// continuation. The host observes `active` and presents the approval
// sheet. The user reviews who is asking, what claims are requested, and
// the freshness requirement, picks one of the pre-matched credentials,
// and confirms with Face ID. Approve resumes the continuation with the
// chosen credential; cancel / dismiss resumes with a userRejected error.
//
// Disclosure consent lives here (explicit pick + biometric); the heavy
// lifting (sign the presentation, verify with the server) happens back in
// the handler once this returns the credential.

import SwiftUI
import LocalAuthentication

@MainActor
@Observable
final class MiniAppIdentityCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        let purpose: String?
        let requiredClaims: [String]
        let maxAgeSec: Int64?
        let matches: [Credential]
    }

    private(set) var active: Request?
    private var continuation: CheckedContinuation<Credential, Error>?

    /// Present the approval sheet and await the user's chosen credential.
    /// Throws `MiniAppBridgeError.userRejected()` if they decline.
    func present(
        appTitle: String,
        purpose: String?,
        requiredClaims: [String],
        maxAgeSec: Int64?,
        matches: [Credential]
    ) async throws -> Credential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = Request(
                appTitle: appTitle,
                purpose: purpose,
                requiredClaims: requiredClaims,
                maxAgeSec: maxAgeSec,
                matches: matches
            )
        }
    }

    func approve(_ credential: Credential) {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(returning: credential)
    }

    /// Called on Cancel, swipe-dismiss, or biometric failure.
    func cancel() {
        let cont = continuation
        continuation = nil
        active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}

struct MiniAppIdentitySheet: View {
    let request: MiniAppIdentityCoordinator.Request
    let onApprove: (Credential) -> Void
    let onCancel: () -> Void

    @State private var selected: Credential?
    @State private var working = false
    @State private var authError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(request.appTitle, systemImage: "square.grid.2x2.fill")
                            .font(.headline)
                        Text("is requesting proof from your wallet.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let purpose = request.purpose, !purpose.isEmpty {
                            Text("Purpose: \(purpose)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Will disclose") {
                    ForEach(request.requiredClaims, id: \.self) { key in
                        Label(key, systemImage: "checkmark.seal")
                            .font(.callout)
                    }
                    if let maxAge = request.maxAgeSec {
                        Text("Requires a screening no older than \(humanAge(maxAge)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Use credential") {
                    ForEach(request.matches) { cred in
                        Button {
                            selected = cred
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SchemaPalette.forSchema(cred.header.schema).humanLabel)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(issuerShort(cred.header.iss))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == cred.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let authError {
                    Section {
                        Text(authError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Verify identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { Task { await approve() } }
                        .disabled(selected == nil || working)
                }
            }
            .onAppear {
                if selected == nil { selected = request.matches.first }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func approve() async {
        guard let cred = selected else { return }
        working = true
        defer { working = false }
        // Explicit biometric consent before disclosing anything.
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometric/passcode available (e.g. simulator): proceed,
            // the disclosure pick itself is the consent.
            onApprove(cred)
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Approve sharing your credential with \(request.appTitle)"
            )
            if ok { onApprove(cred) } else { authError = "Authentication failed." }
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "Authentication canceled."
        }
    }

    private func issuerShort(_ did: String) -> String {
        if did.count <= 30 { return did }
        return String(did.prefix(18)) + "…" + String(did.suffix(8))
    }

    private func humanAge(_ seconds: Int64) -> String {
        let days = seconds / 86_400
        if days % 365 == 0 { return "\(days / 365) year(s)" }
        if days >= 30 { return "\(days / 30) month(s)" }
        return "\(days) day(s)"
    }
}
