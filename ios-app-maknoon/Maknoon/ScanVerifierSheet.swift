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
        case matched(VerifierRequestValidator.Decision, [Credential])
    }

    @State private var phase: Phase = .requestingPermission
    @State private var permission: CameraPermissionState = CameraPermission.current
    @State private var selectedCredentialId: String?

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
                .navigationDestination(item: $selectedCredentialId) { credId in
                    if case .matched(let decision, let matches) = phase,
                       let cred = matches.first(where: { $0.id == credId }) {
                        CredentialPresentView(
                            credential: cred,
                            initialMode: .attributes,
                            pendingRequest: decision.request,
                            nicknameInjection: store.nickname(for: cred.id)
                        )
                    }
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
        case .matched(let decision, let matches):
            matchedView(decision, matches: matches)
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
                    .padding(.bottom, 24)
            }
        }
        .background(Color.black)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rejectedView(_ decision: VerifierRequestValidator.Decision?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Request rejected").font(.title3.bold())
            Text(decision?.reason ?? "Scanned payload is not a valid verifier request.")
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

    private func matchedView(_ decision: VerifierRequestValidator.Decision, matches: [Credential]) -> some View {
        Form {
            Section {
                trustBadge(tier: decision.tier, verifierName: decision.request.verifierName ?? "Verifier")
                Text(verifierDidDisplay(decision.request.verifierDid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Verifier")
            }

            Section {
                if !decision.request.filter.requiredClaims.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Required:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(decision.request.filter.requiredClaims.joined(separator: ", "))
                            .font(.caption)
                    }
                }
                if decision.request.filter.issuers?.mode == "allow",
                   let list = decision.request.filter.issuers?.list, !list.isEmpty {
                    Text("Issuers allowed: " + list.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if decision.request.filter.schemas?.mode == "allow",
                   let list = decision.request.filter.schemas?.list, !list.isEmpty {
                    Text("Schemas accepted: " + list.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Response: " + decision.request.response.mode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What they need")
            }

            Section {
                ForEach(matches) { c in
                    Button {
                        selectedCredentialId = c.id
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: SchemaPalette.forSchema(c.header.schema).iconSystemName)
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SchemaPalette.forSchema(c.header.schema).humanLabel)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(shortIssuerName(c.header.iss))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let nick = store.nickname(for: c.id), !nick.isEmpty {
                                    Text(nick).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(matches.count == 1 ? "1 matching credential" : "\(matches.count) matching credentials")
            } footer: {
                Text("Tap a credential to review what you'll share, then sign + send.")
                    .font(.caption)
            }

            Section {
                Button("Scan again") { phase = .scanning }
            }
        }
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
        phase = .validating(payload: code)
        Task { await validate(code) }
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
            phase = .matched(decision, matches)
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
