// In-person Verify Other flow. The holder acts as a verifier for a
// person standing in front of them: scan whatever the other person
// shows, validate locally, display the result. One-shot, nothing saved.
//
// Accepted QR payloads:
//   * `BadgePayload`: a no-PII credential reference (issuer + schema +
//     cid + anchor). Validated by inspecting metadata. Cryptographic
//     proof requires an online lookup; surfaced as informational.
//   * `DropEnvelope`: pastebin reference. Fetched from Elabify's drop
//     host and run through `PresentationVerifier.verifyOffline`.
//   * Raw Presentation JSON (large QR is rare but possible). Same
//     validation as the dropped variant.
//
// "Verify" here is intentionally limited: the verifier sees whatever the
// other person chose to disclose. No filter spec, no request, that
// flow lives on the React /verifier page for business-grade verifiers.

import SwiftUI

struct VerifyOtherSheet: View {
    let onClose: () -> Void

    enum Phase {
        case requestingPermission
        case denied
        case scanning
        case collectingFrames(received: Int, total: Int)
        case fetching
        case bleConnecting(String)              // status text from BLECentralClient
        case badge(BadgePayload)
        case verdict(Presentation, LocalVerdict)
        case rejected(reason: String)
    }

    @State private var phase: Phase = .requestingPermission
    @State private var permission: CameraPermissionState = CameraPermission.current
    @StateObject private var frames = LocalFrameReceiver()
    @StateObject private var ble = BLECentralClient()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Verify credential")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { onClose() }
                    }
                }
                .task { await ensurePermission() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .requestingPermission:
            progress("Requesting camera access…")
        case .denied:
            cameraDeniedView
        case .scanning, .collectingFrames:
            // One persistent scanner across both states. Rendering the
            // SAME view for scanning and collecting keeps a single
            // AVCaptureSession alive: splitting them into two switch
            // branches tore the camera down and recreated it the instant
            // the first frame arrived, which froze collection after a
            // frame or two. The frame-progress overlay reads the
            // published receiver state, so it updates without a branch
            // (and therefore camera) change.
            scannerView
        case .fetching:
            progress("Fetching presentation…")
        case .bleConnecting(let status):
            progress("BLE: \(status)")
        case .badge(let payload):
            badgeView(payload)
        case .verdict(let p, let v):
            verdictView(presentation: p, verdict: v)
        case .rejected(let reason):
            rejectedView(reason: reason)
        }
    }

    // MARK: -- subviews

    private var scannerView: some View {
        // `collecting` flips once the first frame of a rotating-QR
        // transmission is ingested; the overlay then shows live progress.
        let collecting = frames.transmissionId != nil
        return ZStack {
            QRScannerView(onCode: { handle($0) }, continuous: true)
                .ignoresSafeArea(edges: .top)
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke((collecting ? Color.green : Color.white).opacity(collecting ? 0.85 : 0.65), lineWidth: 3)
                    .frame(width: 240, height: 240)
                Spacer()
                if collecting {
                    VStack(spacing: 8) {
                        Text("Collecting \(frames.receivedFrames) / \(frames.totalFrames) frames")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                        ProgressView(value: Double(frames.receivedFrames), total: Double(max(1, frames.totalFrames)))
                            .progressViewStyle(.linear)
                            .tint(.green)
                            .frame(width: 240)
                        Text("Hold steady, let the rotating QR cycle once.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 24)
                } else {
                    Text("Scan a badge, a drop envelope, or a rotating QR")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                }
                if !collecting {
                    QRPhotoPickerButton(onCode: { handle($0) }, onNoQR: noQRFound)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(Color.black)
    }

    private func noQRFound() {
        phase = .rejected(reason: "No QR code found in that image. Note: multi-frame / rotating QR can't be read from a still photo, use the live camera for those.")
    }

    private var cameraDeniedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("QR scanning is disabled").font(.title3.bold())
            Text("Grant camera access in Settings to verify in person.")
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

            QRPhotoPickerButton(onCode: { handle($0) }, onNoQR: noQRFound) {
                Label("Choose a QR photo instead", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badgeView(_ b: BadgePayload) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Badge").font(.callout.weight(.semibold))
                        Text("No personal data was shared. The badge proves a credential reference exists; verify on-chain for full proof.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("What this shows") {
                kv("Issuer", shortIssuerName(b.iss))
                kv("Type",   SchemaPalette.forSchema(b.schema).humanLabel)
                kv("Issued", formatDate(b.iat))
                if let exp = b.exp { kv("Expires", formatDate(exp)) }
                // One row per anchored chain (multi-network); fall back to the
                // legacy single `anchor` field.
                let anchors = b.anchors ?? b.anchor.map { [$0] } ?? []
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, a in
                    kv("Anchor · \(caip2Label(a.chain))", shortHex(a.batchTxHash))
                }
            }
            Section {
                Button("Scan another") { frames.reset(); phase = .scanning }
            }
        }
    }

    private func verdictView(presentation p: Presentation, verdict v: LocalVerdict) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    let (icon, color, title): (String, Color, String) = {
                        switch v.decision {
                        case "SELF_ATTESTED":
                            switch appAttestResult(p) {
                            case .pass:
                                return ("checkmark.seal.fill", .green, "Self-issued, app-verified")
                            default:
                                return ("person.crop.circle.badge.exclamationmark", .orange,
                                        "Self-issued, app genuineness unverified")
                            }
                        case "DENY":          return ("xmark.shield.fill", .red, "DENY")
                        default:              return ("checkmark.shield.fill", .green, "Locally valid")
                        }
                    }()
                    Image(systemName: icon)
                        .font(.system(size: 32))
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title2.bold())
                        Text(v.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if !v.disclosed.isEmpty {
                Section("Disclosed claims") {
                    ForEach(v.disclosed.keys.sorted(), id: \.self) { k in
                        kv(k, v.disclosed[k]?.displayText ?? "-")
                    }
                }
            }
            Section("Credential") {
                kv("Issuer", p.header.iss)
                kv("Schema", SchemaPalette.forSchema(p.header.schema).humanLabel)
                kv("CID",    p.header.cid)
            }
            Section("Local check matrix") {
                row("headerSigValid",       v.checks.headerSigValid)
                row("merkleValid",          v.checks.merkleValid)
                row("challengeSigValid",    v.checks.challengeSigValid)
                row("timestampValid",       v.checks.timestampValid)
                row("expiryValid",          v.checks.expiryValid)
                row("verifierRequestValid", v.checks.verifierRequestValid)
                row("issuerRegistered",     v.checks.issuerRegistered)
                row("credentialNotRevoked", v.checks.credentialNotRevoked)
                row("rootCurrent",          v.checks.rootCurrent)
            }
            Section {
                Button("Scan another") { frames.reset(); phase = .scanning }
            }
        }
    }

    private func rejectedView(reason: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Could not verify").font(.title3.bold())
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Scan again") { frames.reset(); phase = .scanning }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// For a self-issued presentation, verify its App Attest binding so the
    /// verdict can distinguish "app-verified" from "key-only". `.unavailable`
    /// when there is no attestation (e.g. minted on a simulator).
    private func appAttestResult(_ p: Presentation) -> AppAttestVerifyResult {
        guard let att = p.selfIssuerAttestation,
              let binding = CredentialCanonical.appAttestBindingBytes(
                  cid: p.header.cid, root: p.header.root,
                  holderPkHex: p.holderLongTermPk, schema: p.header.schema)
        else { return .unavailable }
        return AppAttestVerifier.verify(att, bindingBytes: binding, holderDID: p.header.iss)
    }

    @ViewBuilder
    private func row(_ name: String, _ r: LocalCheckResult) -> some View {
        let (icon, color, suffix): (String, Color, String?) = {
            switch r {
            case .pass:                  return ("checkmark.circle.fill", .green, nil)
            case .fail(let reason):      return ("xmark.circle.fill", .red, reason)
            case .unverified(let reason): return ("circle.dashed", .secondary, reason)
            case .notApplicable(let reason): return ("minus.circle", .secondary, reason)
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(name).font(.caption)
                Spacer()
            }
            if let suffix {
                Text(suffix).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func kv(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    // MARK: -- handlers

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

    @MainActor
    private func handle(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // Engagement (BLE-default path). Try to decode as a transport
        // engagement first; if it's one with a BLE block, kick off the
        // central client.
        if let data = trimmed.data(using: .utf8),
           let engagement = try? JSONDecoder().decode(TransportEngagement.self, from: data),
           engagement.v == TransportEngagement.version,
           engagement.ble != nil {
            phase = .bleConnecting("starting…")
            startBLE(with: engagement)
            return
        }

        // Multi-frame: try to ingest as a frame envelope first. The
        // receiver detects the sentinel `v: "elabify-frames-1"` and
        // returns true iff this was a frame. It accumulates frames
        // across calls; once complete, we decode + verify.
        if frames.ingest(trimmed) {
            if let raw = frames.reassembled {
                if let presentation = try? JSONDecoder().decode(Presentation.self, from: raw) {
                    let verdict = PresentationVerifier.verifyOffline(presentation)
                    phase = .verdict(presentation, verdict)
                    return
                }
                phase = .rejected(reason: "Frame stream reassembled but is not a Presentation")
                return
            }
            if let err = frames.lastError {
                phase = .rejected(reason: err)
                return
            }
            phase = .collectingFrames(received: frames.receivedFrames, total: frames.totalFrames)
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            phase = .rejected(reason: "Could not read payload as text")
            return
        }
        // BadgePayload (small QR).
        if let badge = try? JSONDecoder().decode(BadgePayload.self, from: data),
           badge.v == "elabify-badge-1" {
            phase = .badge(badge)
            return
        }
        // DropEnvelope (online fallback, kept for completeness).
        if let envelope = try? JSONDecoder().decode(DropEnvelope.self, from: data),
           envelope.v == 1, !envelope.dropId.isEmpty {
            phase = .fetching
            Task { await fetchAndVerify(envelope) }
            return
        }
        // Raw Presentation (rare; only fits if the verifier built a
        // very large single QR).
        if let presentation = try? JSONDecoder().decode(Presentation.self, from: data) {
            let verdict = PresentationVerifier.verifyOffline(presentation)
            phase = .verdict(presentation, verdict)
            return
        }
        phase = .rejected(reason: "Unrecognised QR payload (badge, drop envelope, frame, or raw presentation expected)")
    }

    @MainActor
    private func startBLE(with engagement: TransportEngagement) {
        ble.connect(to: engagement)
        // Stream phase updates from the BLE client into our own
        // enum so the scanner view + status block both refresh.
        Task { @MainActor in
            for await _ in ble.$phase.values {
                switch ble.phase {
                case .scanning:
                    phase = .bleConnecting("scanning for holder…")
                case .connecting:
                    phase = .bleConnecting("connecting…")
                case .handshaking:
                    phase = .bleConnecting("handshake (HPKE)…")
                case .receivingPayload:
                    phase = .bleConnecting("receiving sealed payload…")
                case .received(let presentation):
                    let verdict = PresentationVerifier.verifyOffline(presentation)
                    phase = .verdict(presentation, verdict)
                    return
                case .unsupported(let reason), .error(let reason):
                    phase = .rejected(reason: reason)
                    return
                case .idle:
                    break
                }
            }
        }
    }

    @MainActor
    private func fetchAndVerify(_ env: DropEnvelope) async {
        do {
            let p = try await PresentationDrop.fetch(host: HolderStore.elabifyDropHost, dropId: env.dropId)
            let v = PresentationVerifier.verifyOffline(p)
            phase = .verdict(p, v)
        } catch {
            phase = .rejected(reason: "Could not fetch drop: \(error)")
        }
    }

    // MARK: -- formatters

    private func formatDate(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private func shortHex(_ hex: String) -> String {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if s.count <= 14 { return "0x\(s)" }
        return "0x\(s.prefix(8))…\(s.suffix(6))"
    }
}
