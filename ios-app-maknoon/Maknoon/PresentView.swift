// Open-ended share flow. The holder picks claims, the wallet builds a
// signed Presentation with a self-issued nonce, and the user chooses how
// to deliver it: render as a QR (uploads to the Elabify drop pastebin),
// copy the JSON, or POST to a user-pasted URL.
//
// There is no hardcoded verifier here. Step 2.B replaces the per-call
// master-sign path with the SE-resident ephemeral + delegation cert.

import SwiftUI
import ElabifyCore

struct PresentAttributesView: View {
    let credential: Credential
    /// When this view is opened after scanning a verifier request, the
    /// disclosure toggles pre-populate from `request.filter.requiredClaims`
    /// and the share targets default to the request's response directive.
    /// Slice 4 wires this; Slice 3 ships with `pendingRequest == nil`.
    var pendingRequest: VerifierRequest? = nil
    /// Passport Show-QR (ADR-0039): Build QR moves to the top and the helper
    /// footers are dropped for a lean retail layout.
    var compact: Bool = false
    /// Present the rotating-QR share sheet. Hoisted to the parent
    /// (`CredentialPresentView`) so the sheet is anchored to the screen's
    /// Form rather than to these Form-nested rows: a `.sheet` attached to
    /// content inside a Form is torn down when the Form recomputes its
    /// rows, which dismissed the QR a beat after it opened. Bluetooth
    /// share was removed (complex, not required).
    var onPresentQR: (Presentation) -> Void = { _ in }
    /// Present the network "drop" share: upload the presentation to a
    /// one-shot link and show a small pointer QR. Same Form-hoist reasoning
    /// as onPresentQR. This is the path that actually works for a full
    /// ~32 KB presentation (and across iPhone or web verifiers); a rotating
    /// QR is too many dense frames for a camera to collect.
    var onPresentDrop: (Presentation) -> Void = { _ in }

    @Environment(HolderStore.self) private var store
    @State private var selectedClaims: Set<String> = []
    @State private var built: BuiltShare?
    @State private var working: Bool = false
    @State private var buildError: String?

    @State private var showCopyConfirm = false
    @State private var showCallbackPrompt = false
    @State private var callbackUrl = ""
    @State private var callbackOutcome: OpenVerifierPost.Outcome?
    @State private var callbackError: String?
    @State private var workingShare: ShareKind?

    enum ShareKind { case qr, copy, callback }

    var body: some View {
        Group {
            if let pendingRequest {
                requestSummarySection(pendingRequest)
            }
            if compact {
                // Passport: Build Online QR on top (defaults to the secure
                // link), toggles below, then an Advanced section for the
                // offline rotating QR + copy. No "Send to URL", no helper text.
                buildSection
                claimsSection
                advancedShareSection
            } else {
                claimsSection
                buildSection
                if built != nil {
                    shareSection
                    if let outcome = callbackOutcome {
                        callbackOutcomeSection(outcome)
                    }
                    if let err = callbackError {
                        Section("Callback error") {
                            Text(err).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let buildError {
                Section("Build error") {
                    Text(buildError).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .onAppear { applyPendingDefaults() }
        .alert("Send to URL", isPresented: $showCallbackPrompt) {
            TextField("https://verifier.example.com/v1/verify", text: $callbackUrl)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Send") {
                if let built {
                    Task { await sendToCallback(presentation: built.presentation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Posts the signed Presentation to this URL. Works with any verifier; you can copy the body separately to inspect it first.")
        }
        .alert("Copied", isPresented: $showCopyConfirm) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The signed Presentation is on your clipboard. Paste it into the verifier's tool.")
        }
    }

    // MARK: -- request summary (Respond mode preview; populated in Slice 4)

    private func requestSummarySection(_ r: VerifierRequest) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.verifierName ?? "Verifier")
                        .font(.callout.weight(.semibold))
                    Text(truncated(r.verifierDid))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if !r.filter.requiredClaims.isEmpty {
                Text("Wants: " + r.filter.requiredClaims.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Responding to verifier")
        } footer: {
            Text("The verifier's required fields are pre-selected below. Toggle others if you want to share more.")
                .font(.caption)
        }
    }

    private var claimsSection: some View {
        // Header carries a Select-all / Deselect-all toggle on the
        // right. Required claims (verifier-pinned) stay on regardless;
        // the toggle only flips the non-required ones.
        let allKeys = credential.merkleTree.sortedKeys
        let requiredKeys: Set<String> = Set(pendingRequest?.filter.requiredClaims ?? [])
        let optionalKeys = allKeys.filter { !requiredKeys.contains($0) }
        let allSelected = optionalKeys.allSatisfy { selectedClaims.contains($0) }
        return Section {
            ForEach(allKeys, id: \.self) { key in
                let required = requiredKeys.contains(key)
                let value = credential.claims[key]?.prettyText ?? "-"
                Toggle(isOn: Binding(
                    get: { selectedClaims.contains(key) },
                    set: { on in
                        if on { selectedClaims.insert(key) }
                        else if !required { selectedClaims.remove(key) }
                    }
                )) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(key)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if required {
                                    Text("required")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            // High-contrast, callout-sized value with
                            // tap-and-hold to copy via SwiftUI's text
                            // selection. The dedicated copy button
                            // below gives a one-tap path for users on
                            // SwiftUI versions where text-select-in-Form
                            // is unreliable.
                            Text(value)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button {
                            UIPasteboard.general.string = value
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy \(key)")
                    }
                }
                .disabled(required)
            }
        } header: {
            HStack {
                Text("Attributes")
                Spacer()
                Button {
                    if allSelected {
                        // Strip every non-required key in one go.
                        for k in optionalKeys { selectedClaims.remove(k) }
                    } else {
                        // Add every key (required stays on already).
                        for k in allKeys { selectedClaims.insert(k) }
                    }
                } label: {
                    Text(allSelected ? "Deselect all" : "Select all")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(optionalKeys.isEmpty)
            }
        } footer: {
            if !compact {
                Text("All attributes are selected by default. Tap to remove any field before building the QR; required fields (when the verifier specified them) stay on.")
                    .font(.caption)
            }
        }
    }

    private var buildSection: some View {
        Section {
            Button(action: { Task { if compact { await buildOnlineQR() } else { await build() } } }) {
                HStack {
                    if working { ProgressView() }
                    Text(compact ? "Build Online QR" : (built != nil ? "Re-build QR" : "Build QR"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // Zero disclosed claims is allowed (ADR-0039): a zero-attribute QR
            // still proves a genuine, anchored credential with no PII.
            .disabled(working)
        } footer: {
            if !compact {
                Text("Signs a Presentation with the disclosed claims. The signature is over a fresh nonce, valid for ~5 minutes.")
                    .font(.caption)
            }
        }
    }

    /// Passport (compact) advanced section: the offline rotating QR and a raw
    /// copy of the presentation. Each builds on demand. No "Send to URL".
    private var advancedShareSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                Button { Task { await buildOfflineQR() } } label: {
                    Label("Build Offline QR", systemImage: "qrcode")
                }
                .disabled(working)
                Button { Task { await buildAndCopy() } } label: {
                    Label("Copy Presentation", systemImage: "doc.on.clipboard")
                }
                .disabled(working)
            }
        }
    }

    /// Build then immediately open the secure-link (drop) QR. The default
    /// passport flow.
    @MainActor
    private func buildOnlineQR() async {
        await build()
        if let p = built?.presentation { onPresentDrop(p); recordHistory(presentation: p, via: "drop") }
    }

    @MainActor
    private func buildOfflineQR() async {
        await build()
        if let p = built?.presentation { onPresentQR(p); recordHistory(presentation: p, via: "qr") }
    }

    @MainActor
    private func buildAndCopy() async {
        await build()
        if built != nil { copyPresentation() }
    }

    private var shareSection: some View {
        Section {
            // Responding to a scanned verifier request that asked for a callback:
            // one tap POSTs the signed presentation straight to its callback URL,
            // so the verifier sees the result immediately (no copy-paste).
            if let req = pendingRequest, req.response.mode == "callback",
               let cb = req.response.callbackUrl, !cb.isEmpty {
                Button {
                    callbackUrl = cb
                    if let built {
                        Task { await sendToCallback(presentation: built.presentation) }
                    }
                } label: {
                    shareLabel(
                        icon: "paperplane.fill",
                        title: "Send to \(req.verifierName ?? "verifier")",
                        detail: "POST the signed presentation straight to the verifier's callback. They see the result instantly."
                    )
                }
                .disabled(working || workingShare == .callback)
            }
            Button {
                if let built {
                    onPresentDrop(built.presentation)
                    recordHistory(presentation: built.presentation, via: "drop")
                }
            } label: {
                shareLabel(
                    icon: "link",
                    title: "Share via secure link",
                    detail: "Uploads to a one-shot, 5-minute link and shows a small QR the verifier scans. Works for a full presentation, and across iPhone or web verifiers."
                )
            }
            Button {
                if let built {
                    onPresentQR(built.presentation)
                    recordHistory(presentation: built.presentation, via: "qr")
                }
            } label: {
                shareLabel(
                    icon: "qrcode",
                    title: "Show QR code",
                    detail: "Rotating QR, fully offline with no server. Only practical for very small shares; a full presentation is too many frames to scan."
                )
            }
            Button {
                copyPresentation()
            } label: {
                shareLabel(icon: "doc.on.clipboard", title: "Copy presentation",
                           detail: "Paste into a verifier tool or curl.")
            }
            Button {
                callbackUrl = pendingRequest?.response.callbackUrl ?? callbackUrl
                showCallbackPrompt = true
            } label: {
                shareLabel(icon: "paperplane", title: "Send to URL…",
                           detail: pendingRequest?.response.callbackUrl ?? "Paste any HTTPS verifier endpoint.")
            }
        } header: {
            Text("Share")
        } footer: {
            Text("The Presentation is signed and ready. You decide where it goes, Elabify never mediates the verifier relationship.")
                .font(.caption)
        }
    }

    private func callbackOutcomeSection(_ o: OpenVerifierPost.Outcome) -> some View {
        Section("Verifier response") {
            HStack(spacing: 10) {
                Image(systemName: o.status >= 200 && o.status < 300 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(o.status >= 200 && o.status < 300 ? .green : .orange)
                Text("HTTP \(o.status)").font(.callout.weight(.medium))
            }
            if !o.bodyText.isEmpty {
                Text(o.bodyText.prefix(400))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func shareLabel(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: -- build action

    private struct BuiltShare {
        let presentation: Presentation
        let canonicalJsonText: String
    }

    @MainActor
    private func build() async {
        working = true
        buildError = nil
        callbackOutcome = nil
        callbackError = nil
        defer { working = false }

        do {
            let challenge: HexString
            let verifierDidForChallengeMsg: String
            if let pending = pendingRequest {
                challenge = pending.challenge
                verifierDidForChallengeMsg = pending.verifierDid
            } else {
                challenge = "0x" + PresentationFactory.selfNonceHex()
                verifierDidForChallengeMsg = "did:elabify:open"
            }

            // Single signing path shared with the mini-app identity bridge.
            let presentation = try await PresentationFactory.build(
                credential: credential,
                selectedClaims: selectedClaims,
                challenge: challenge,
                verifierDid: verifierDidForChallengeMsg,
                pendingRequest: pendingRequest,
                store: store
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(presentation)
            let text = String(data: json, encoding: .utf8) ?? "{}"

            built = BuiltShare(presentation: presentation, canonicalJsonText: text)
            // The Share section appears with "Show QR code", "Copy" and
            // "Send to URL". We deliberately do NOT auto-open the QR sheet:
            // the user chooses the channel rather than being dropped into
            // the QR view.
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: -- terminal actions

    private func copyPresentation() {
        guard let built else { return }
        UIPasteboard.general.string = built.canonicalJsonText
        showCopyConfirm = true
        recordHistory(presentation: built.presentation, via: "copy")
    }

    @MainActor
    private func sendToCallback(presentation: Presentation) async {
        callbackOutcome = nil
        callbackError = nil
        let trimmed = callbackUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            callbackError = "Invalid URL, expected http(s)://…"
            return
        }
        workingShare = .callback
        defer { workingShare = nil }
        do {
            let outcome = try await OpenVerifierPost.send(presentation: presentation, to: url)
            callbackOutcome = outcome
            recordHistory(presentation: presentation, via: "callback:\(url.host ?? "url")")
        } catch {
            callbackError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: -- helpers

    private func applyPendingDefaults() {
        if let r = pendingRequest {
            // Verifier-driven flow: the verifier's required-claims set
            // defines the scope. Pre-select only what they asked for;
            // the user can add more if they want.
            for k in r.filter.requiredClaims { selectedClaims.insert(k) }
        } else {
            // User-driven Attribute QR flow: pre-select EVERY claim
            // so "Build QR" can be tapped immediately. The user can
            // deselect individual rows before generating.
            for k in credential.merkleTree.sortedKeys { selectedClaims.insert(k) }
        }
    }

    private func recordHistory(presentation: Presentation, via channel: String) {
        let verifierDid = presentation.verifierRequest?.verifierDid ?? "did:elabify:open"
        let verifierName = presentation.verifierRequest?.verifierName
        let label = verifierName ?? "Open share (\(channel))"
        VerifierHistory.record(
            verifierDid: verifierDid,
            verifierName: verifierName,
            label: label,
            credentialId: presentation.header.cid,
            credentialSchema: presentation.header.schema,
            disclosedKeys: presentation.disclosed.map { $0.key }
        )
    }

    private func truncated(_ s: String) -> String {
        if s.count <= 36 { return s }
        return s.prefix(18) + "…" + s.suffix(12)
    }
}

// MARK: -- Drop QR sheet (deprecated; kept for non-default flows)

/// Originally the default Share-as-QR path. Replaced by
/// `LocalShareQrSheet` per pilot feedback ("no third-party infrastructure
/// in the default share path"). Still compiled because future flows
/// (e.g. very large presentations with hardware-wallet attestations that
/// don't fit even a multi-frame QR) may want to fall back to the drop.
struct DropQrSheet: View {
    let presentation: Presentation
    let onClose: () -> Void

    @Environment(HolderStore.self) private var store
    @State private var envelope: DropEnvelope?
    @State private var qrImage: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let qrImage, let envelope {
                    ScrollView {
                        VStack(spacing: 16) {
                            Image(uiImage: qrImage)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: 360)
                                .padding(20)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Text("Drop ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(envelope.dropId)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text("Server: \(serverLabel)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let exp = envelope.expiresAt {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Text("Expires in \(countdown(to: exp, now: ctx.date))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text("To verify, use Elabify Maknoon app identity to verify credential")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 24)
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await upload() } }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Uploading…").font(.callout).foregroundStyle(.secondary)
                    }
                    .task { await upload() }
                }
            }
            .navigationTitle("Online QR")
            .navigationBarTitleDisplayMode(.inline)
            .maxBrightnessWhilePresented()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                }
            }
        }
    }

    /// Host that stored the drop, shown so the verifier knows which server to
    /// trust for the one-shot fetch.
    private var serverLabel: String {
        HolderStore.elabifyDropHost.host ?? HolderStore.elabifyDropHost.absoluteString
    }

    /// Live "m:ss" remaining until the drop expires; "expired" past the deadline.
    private func countdown(to expiresAt: Int64, now: Date) -> String {
        let remaining = Int(TimeInterval(expiresAt) - now.timeIntervalSince1970)
        if remaining <= 0 { return "expired" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    @MainActor
    private func upload() async {
        errorMessage = nil
        do {
            let env = try await PresentationDrop.upload(
                host: HolderStore.elabifyDropHost,
                presentation: presentation
            )
            envelope = env
            let payload = try JSONEncoder().encode(env)
            qrImage = BadgeQR.render(payload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func formatTime(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
