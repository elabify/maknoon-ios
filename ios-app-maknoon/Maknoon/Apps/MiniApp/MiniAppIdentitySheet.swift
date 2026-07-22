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
        // Pool-access disclosure context (nil/false for a plain identity.request):
        /// The issuer host that will RECEIVE this disclosure (shown so the user
        /// knows where their data goes).
        var recipientHost: String? = nil
        /// The EVM wallet address that is ALSO shared and permanently linked to
        /// this KYC on-chain (shown with a warning before the wallet-control sign).
        var walletAddress: String? = nil
        /// When true, the "Will disclose" section shows each claim's VALUE
        /// (expanded JSON) from the selected credential, not just the key.
        var showsDisclosedValues: Bool = false
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
        matches: [Credential],
        recipientHost: String? = nil,
        walletAddress: String? = nil,
        showsDisclosedValues: Bool = false
    ) async throws -> Credential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = Request(
                appTitle: appTitle,
                purpose: purpose,
                requiredClaims: requiredClaims,
                maxAgeSec: maxAgeSec,
                matches: matches,
                recipientHost: recipientHost,
                walletAddress: walletAddress,
                showsDisclosedValues: showsDisclosedValues
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

                if let host = request.recipientHost, !host.isEmpty {
                    Section("Sending to") {
                        Label(host, systemImage: "server.rack")
                            .font(.callout.monospaced())
                    }
                }

                Section("Will disclose") {
                    ForEach(request.requiredClaims, id: \.self) { key in
                        if request.showsDisclosedValues {
                            // Show the actual value being shared (expanded), not just
                            // the attribute name, so the user can see exactly what the
                            // recipient learns (e.g. the sanctions-screen result).
                            VStack(alignment: .leading, spacing: 2) {
                                Label(key, systemImage: "checkmark.seal")
                                    .font(.callout.weight(.medium))
                                Text(disclosedValue(key))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Label(key, systemImage: "checkmark.seal")
                                .font(.callout)
                        }
                    }
                    if let maxAge = request.maxAgeSec {
                        Text("Requires a screening no older than \(humanAge(maxAge)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let wallet = request.walletAddress, !wallet.isEmpty {
                    Section("Wallet address shared") {
                        Text(wallet)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Label(
                            "This wallet is shared with the issuer and permanently linked to this verified identity on-chain.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                                    // The holder identity (0x) this credential attests, so
                                    // the user knows which passport is being disclosed.
                                    Text(holderShort(cred.header.sub))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(issuerShort(cred.header.iss))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
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

    /// The 0x the holder DID encodes (did:elabify:...:holder:0x…), so the user
    /// sees which passport/identity is being disclosed. Falls back to a
    /// shortened DID when no 0x is present.
    private func holderShort(_ did: String) -> String {
        if let r = did.range(of: "0x") {
            let hex = String(did[r.lowerBound...])
            return hex.count > 14 ? String(hex.prefix(8)) + "…" + String(hex.suffix(6)) : hex
        }
        if did.count <= 30 { return did }
        return String(did.prefix(18)) + "…" + String(did.suffix(8))
    }

    /// The selected credential's value for `key`, pretty-printed, so the user
    /// sees exactly what is disclosed (e.g. the sanctions-screen result).
    private func disclosedValue(_ key: String) -> String {
        guard let cred = selected ?? request.matches.first,
              let value = cred.claims[key] else { return "—" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }

    private func humanAge(_ seconds: Int64) -> String {
        let days = seconds / 86_400
        if days % 365 == 0 { return "\(days / 365) year(s)" }
        if days >= 30 { return "\(days / 30) month(s)" }
        return "\(days) day(s)"
    }
}
