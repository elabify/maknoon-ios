// Scan a verifier's request QR. After the camera reads a payload, the
// sheet:
//   1. Decodes + cryptographically validates the request (via
//      `VerifierRequestValidator`). Both trust tiers are accepted; the UI
//      surfaces the tier as a coloured badge.
//   2. Filters the user's wallet via `MatchingEngine`. If at least one
//      credential matches, lists them. The user picks one.
//   3. Pushes `CredentialPresentView` with the request pre-populated so
//      the Share Attributes section opens in Respond mode (the required
//      claim toggles are pre-selected and locked).
//
// "No matching credential" is the terminal state when nothing matches.
// Out of scope: explaining what the user is missing.

import SwiftUI

struct ScanVerifierSheet: View {
    let store: HolderStore
    let onClose: () -> Void

    enum Phase {
        case scanning
        case requestingPermission
        case denied
        case validating(payload: String)
        case noMatch(VerifierRequestValidator.Decision)
        case rejected(VerifierRequestValidator.Decision?)
        /// Single-confirm Approve/Reject screen shown for every match.
        case confirm(VerifierRequestValidator.Decision, [Credential])
        /// Terminal success after the presentation was posted to the verifier.
        case sent(String)
    }

    @State private var phase: Phase = .requestingPermission
    @State private var permission: CameraPermissionState = CameraPermission.current
    /// Credential chosen on the single-confirm screen.
    @State private var confirmCredId: String?
    @State private var sending = false
    @State private var sendError: String?
    /// Set when the scanned code is recognized as a different flow's code (e.g.
    /// a Verify & Pay request) so we can redirect instead of a generic reject.
    @State private var rejectionHint: String?
    /// Set when the scanned URL resolves to a server-hosted CommerceRequest, so
    /// the single-confirm Verify & Pay sheet opens here (unified entry).
    @State private var commercePay: CommercePayContext?

    struct CommercePayContext: Identifiable {
        let id = UUID()
        let request: CommerceRequest
        let baseURL: URL
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan verifier")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { onClose() }
                    }
                }
                .task { await ensurePermission() }
                .sheet(item: $commercePay) { ctx in
                    CommercePaySheet(
                        store: store, request: ctx.request, responseBaseURL: ctx.baseURL,
                        onClose: { commercePay = nil; onClose() })
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .requestingPermission:
            VStack(spacing: 12) {
                ProgressView()
                Text("Requesting camera access…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            cameraDeniedView
        case .scanning:
            scannerView
        case .validating:
            VStack(spacing: 12) {
                ProgressView()
                Text("Validating verifier signature…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rejected(let decision):
            rejectedView(decision)
        case .noMatch(let decision):
            noMatchView(decision)
        case .confirm(let decision, let matches):
            confirmView(decision, matches: matches)
        case .sent(let verifierName):
            sentView(verifierName)
        }
    }

    // MARK: -- scanner

    private var scannerView: some View {
        ZStack {
            QRScannerView(onCode: { handleScannedCode($0) })
                .ignoresSafeArea(edges: .top)
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.65), lineWidth: 3)
                    .frame(width: 240, height: 240)
                Spacer()
                Text("Scan the verifier's QR code")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                QRPhotoPickerButton(onCode: { handleScannedCode($0) }, onNoQR: noQRFound)
                    .padding(.bottom, 24)
            }
        }
        .background(Color.black)
    }

    private func noQRFound() {
        rejectionHint = "No QR code found in that image."
        phase = .rejected(nil)
    }

    private var cameraDeniedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("QR scanning is disabled").font(.title3.bold())
            Text("Open Settings and grant camera access, then return to the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            QRPhotoPickerButton(onCode: { handleScannedCode($0) }, onNoQR: noQRFound) {
                Label("Choose a QR photo instead", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rejectedView(_ decision: VerifierRequestValidator.Decision?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Request rejected").font(.title3.bold())
            Text(rejectionHint ?? decision?.reason ?? "Scanned payload is not a valid verifier request.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Scan again") { phase = .scanning }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    private func noMatchView(_ decision: VerifierRequestValidator.Decision) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                trustBadge(tier: decision.tier, verifierName: decision.request.verifierName ?? "Verifier")
                Text("No matching credential").font(.title3.weight(.semibold))
                Text("This verifier needs a credential you don't have. Try receiving one from an issuer first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button("Scan again") { phase = .scanning }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: -- single-confirm (Approve / Reject)

    @ViewBuilder
    private func confirmView(_ decision: VerifierRequestValidator.Decision, matches: [Credential]) -> some View {
        let selected = matches.first { $0.id == confirmCredId } ?? matches[0]
        let claims = decision.request.filter.requiredClaims
        Form {
            Section {
                trustBadge(tier: decision.tier, verifierName: decision.request.verifierName ?? "Verifier")
                Text(verifierDidDisplay(decision.request.verifierDid))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } header: { Text("Verifier") }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: SchemaPalette.forSchema(selected.header.schema).iconSystemName)
                        .font(.title3).foregroundStyle(.purple).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SchemaPalette.forSchema(selected.header.schema).humanLabel)
                            .font(.callout.weight(.semibold))
                        Text(shortIssuerName(selected.header.iss))
                            .font(.caption).foregroundStyle(.secondary)
                        if let nick = store.nickname(for: selected.id), !nick.isEmpty {
                            Text(nick).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if matches.count > 1 {
                    Picker("Use credential", selection: $confirmCredId) {
                        ForEach(matches) { c in Text(credLabel(c)).tag(Optional(c.id)) }
                    }
                }
            } header: { Text("Your matching credential") }

            Section {
                if claims.isEmpty {
                    Text("No personal attributes requested.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(claims, id: \.self) { key in
                        HStack(alignment: .top) {
                            Text(key).font(.callout.weight(.medium))
                            Spacer(minLength: 12)
                            Text(Self.attrValue(selected, key)).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            } header: { Text("You will share") } footer: {
                Text("Approve signs these attributes and sends them to the verifier over the network. Your keys never leave this device.")
                    .font(.caption)
            }

            if let sendError {
                Section { Text(sendError).font(.callout).foregroundStyle(.red) }
            }

            Section {
                Button(action: { approve(decision, selected) }) {
                    HStack {
                        if sending { ProgressView() } else { Image(systemName: "checkmark.shield.fill") }
                        Text(sending ? "Sending…" : "Approve & share").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending)
                Button(role: .destructive) { onClose() } label: {
                    Text("Reject").frame(maxWidth: .infinity)
                }
                .disabled(sending)
            }
        }
    }

    private func approve(_ decision: VerifierRequestValidator.Decision, _ cred: Credential) {
        sending = true
        sendError = nil
        Task {
            do {
                let presentation = try await PresentationFactory.build(
                    credential: cred,
                    selectedClaims: Set(decision.request.filter.requiredClaims),
                    challenge: decision.request.challenge,
                    verifierDid: decision.request.verifierDid,
                    pendingRequest: decision.request,
                    store: store)
                guard let cb = decision.request.response.callbackUrl, let url = URL(string: cb) else {
                    sendError = "This verifier did not provide a delivery URL."
                    sending = false
                    return
                }
                let outcome = try await OpenVerifierPost.send(presentation: presentation, to: url)
                if (200..<300).contains(outcome.status) {
                    phase = .sent(decision.request.verifierName ?? "the verifier")
                } else {
                    sendError = "Verifier responded HTTP \(outcome.status). \(outcome.bodyText.prefix(200))"
                }
                sending = false
            } catch {
                sendError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                sending = false
            }
        }
    }

    private func sentView(_ verifierName: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("Shared with \(verifierName)").font(.title3.bold())
            Text("Your verified attributes were sent.").font(.callout).foregroundStyle(.secondary)
            Button("Done") { onClose() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            onClose()
        }
    }

    /// Short label for the credential picker.
    private func credLabel(_ c: Credential) -> String {
        let base = SchemaPalette.forSchema(c.header.schema).humanLabel
        if let nick = store.nickname(for: c.id), !nick.isEmpty { return "\(base) · \(nick)" }
        return base
    }

    /// sdnScreen-aware display value (mirrors CommercePaySheet).
    private static func attrValue(_ c: Credential, _ key: String) -> String {
        if key == "sdnScreen", let obj = c.claims[key]?.anyValue as? [String: Any] {
            let result = (obj["result"] as? String) ?? "?"
            let when = (obj["screenedAt"] as? String).map { String($0.prefix(10)) } ?? ""
            return when.isEmpty ? "Sanctions: \(result)" : "Sanctions: \(result) (screened \(when))"
        }
        return c.claims[key]?.displayText ?? "-"
    }

    // MARK: -- trust badge

    @ViewBuilder
    private func trustBadge(tier: VerifierRequestValidator.TrustTier, verifierName: String) -> some View {
        let (color, label, systemImage): (Color, String, String) = {
            switch tier {
            case .registered: return (.green, "Registered verifier", "checkmark.seal.fill")
            case .selfSigned: return (.orange, "Self-signed verifier", "exclamationmark.shield.fill")
            case .unknown:    return (.red, "Unverified", "xmark.shield.fill")
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(verifierName).font(.callout.weight(.semibold))
                Text(label).font(.caption).foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: -- handlers

    @MainActor
    private func handleScannedCode(_ code: String) {
        rejectionHint = nil
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unified entry: a merchant Verify & Pay code is a short request URL.
        // Fetch it; if it resolves to a CommerceRequest (has payment terms), open
        // the single-confirm Verify & Pay sheet. Otherwise it's a plain verifier
        // request_uri, fall through to the identity validate path.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            phase = .validating(payload: code)
            Task {
                if let commerce = try? await CommerceTransport.fetchRequest(url: url) {
                    commercePay = CommercePayContext(request: commerce, baseURL: Self.origin(of: url))
                    return
                }
                await validate(code)
            }
            return
        }
        // Legacy serverless multi-frame Verify & Pay code -> redirect.
        if let frame = try? JSONDecoder().decode(LocalFrameEnvelope.self, from: Data(code.utf8)),
           frame.v == LocalFrameEnvelope.version {
            rejectionHint = "This is a Verify & Pay code. Open Wallet → Verify & Pay to scan it."
            phase = .rejected(nil)
            return
        }
        phase = .validating(payload: code)
        Task { await validate(code) }
    }

    /// scheme://host[:port] of a request URL, where the response is posted.
    private static func origin(of url: URL) -> URL {
        var c = URLComponents()
        c.scheme = url.scheme
        c.host = url.host
        c.port = url.port
        return c.url ?? url
    }

    @MainActor
    private func validate(_ payload: String) async {
        let decision = await VerifierRequestValidator.validate(
            scannedJsonString: payload,
            registryHost: HolderStore.elabifyDropHost
        )
        guard let decision else {
            phase = .rejected(nil)
            return
        }
        guard decision.isValid else {
            phase = .rejected(decision)
            return
        }
        let matches = MatchingEngine.match(
            credentials: store.credentials,
            filter: decision.request.filter
        )
        if matches.isEmpty {
            phase = .noMatch(decision)
        } else {
            // Every match goes straight to the single Approve/Reject screen.
            confirmCredId = matches.first?.id
            sendError = nil
            phase = .confirm(decision, matches)
        }
    }

    @MainActor
    private func ensurePermission() async {
        switch permission {
        case .authorized:
            phase = .scanning
        case .notDetermined:
            let next = await CameraPermission.request()
            permission = next
            phase = (next == .authorized) ? .scanning : .denied
        case .denied:
            phase = .denied
        }
    }

    private func verifierDidDisplay(_ did: String) -> String {
        if did.count <= 42 { return did }
        return String(did.prefix(20)) + "…" + String(did.suffix(16))
    }
}
