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
    /// Known-issuer hosts to probe for the signed well-known doc that carries the
    /// HAVID X.509 cross-endorsement (ADR-0051). Empty = HAVID stays unresolved.
    var knownIssuerBaseURLs: [URL] = []
    /// Effective RPC per CAIP-2 chain from the app's Ethereum network settings
    /// (honoring per-network overrides). Identity checks use the Sepolia entry;
    /// revocation + root use whichever chain the credential is anchored on (e.g.
    /// Base Sepolia), so anchoring is not limited to a single chain.
    var chainRPCs: [String: String] = [:]

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
    // Holder-independent on-chain verification (ADR-0054, item 7). Runs after the
    // offline verdict is shown; nil while pending / offline.
    @State private var onChain: OnChainVerdict?
    @State private var onChainRunning = false
    // Client-side HAVID cross-endorsement (ADR-0051 / ADR-0054). Local HTTPS+X.509,
    // no chain read; nil while pending / unresolved.
    @State private var havid: HavidResult?
    // Disclosed claims are the point of the scan, so that section opens expanded.
    @State private var disclosedExpanded = true

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
                let s = badgeOverallStatus()
                HStack(spacing: 12) {
                    Image(systemName: s.icon).font(.system(size: 32)).foregroundStyle(s.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.title2.bold())
                        Text(s.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Text("A badge shares no personal data, it is a credential reference. It is confirmed against the chain; only the full signature check needs the complete credential.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What this shows") {
                kv("Issuer", shortIssuerName(b.iss))
                kv("Type",   SchemaPalette.forSchema(b.schema).humanLabel)
                kv("CID",    b.cid)
                kv("Issued", formatDate(b.iat))
                if let exp = b.exp { kv("Expires", formatDate(exp)) }
                let anchors = b.anchors ?? b.anchor.map { [$0] } ?? []
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, a in
                    kv("Anchor · \(caip2Label(a.chain))", shortHex(a.batchTxHash))
                }
            }
            Section {
                DisclosureGroup { onChainContent } label: {
                    groupLabel("Online verification (on-chain)", badgeOnchainStatus())
                }
            }
            Section {
                DisclosureGroup { havidContent } label: {
                    groupLabel("Organization identity (HAVID)", havidStatus())
                }
            }
            Section {
                Button("Scan another") { frames.reset(); phase = .scanning; onChain = nil; havid = nil }
            }
        }
        .task(id: b.cid) { await runBadgeChecks(b) }
    }

    private func verdictView(presentation p: Presentation, verdict v: LocalVerdict) -> some View {
        Form {
            Section {
                let s = overallStatus(p, v)
                HStack(spacing: 12) {
                    Image(systemName: s.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(s.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                            .font(.title2.bold())
                        Text(s.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            // Detail lives in collapsed sections, each headed by one status glyph,
            // so the verdict fits on a screen. The top banner is the answer; expand
            // a section only to audit it.
            if !v.disclosed.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $disclosedExpanded) {
                        ForEach(v.disclosed.keys.sorted(), id: \.self) { k in
                            kv(k, v.disclosed[k]?.prettyText ?? "-")
                        }
                    } label: { groupLabel("Disclosed claims (\(v.disclosed.count))", .neutral) }
                }
            }
            Section {
                DisclosureGroup {
                    kv("Issuer", p.header.iss)
                    kv("Schema", SchemaPalette.forSchema(p.header.schema).humanLabel)
                    kv("CID", p.header.cid)
                } label: { groupLabel("Credential", .neutral) }
            }
            Section {
                DisclosureGroup {
                    // Issuer-bound header signature is verified in the online tier;
                    // shown here only for self-attested (holder key, offline).
                    if v.decision == "SELF_ATTESTED" { row("headerSigValid", v.checks.headerSigValid) }
                    row("merkleValid",       v.checks.merkleValid)
                    row("challengeSigValid", v.checks.challengeSigValid)
                    row("timestampValid",    v.checks.timestampValid)
                    row("expiryValid",       v.checks.expiryValid)
                    // verifierRequestValid is omitted: the open "Verify credential"
                    // flow sends no verifier request, so it is never applicable here.
                } label: { groupLabel("Cryptographic checks", cryptoStatus(v)) }
            }
            if v.decision != "SELF_ATTESTED" {
                Section {
                    DisclosureGroup { onChainContent } label: {
                        groupLabel("Online verification (on-chain)", onchainStatus())
                    }
                }
                Section {
                    DisclosureGroup { havidContent } label: {
                        groupLabel("Organization identity (HAVID)", havidStatus())
                    }
                }
            }
            Section {
                Button("Scan another") { frames.reset(); phase = .scanning; onChain = nil; havid = nil }
            }
        }
        .task(id: p.header.cid) {
            if v.decision != "SELF_ATTESTED" {
                await runOnChain(p, v)
                await runHavid(p)
            }
        }
    }

    /// On-chain verification tier rows (rendered inside a collapsible section).
    @ViewBuilder
    private var onChainContent: some View {
        if onChainRunning && onChain == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking on-chain…").font(.callout).foregroundStyle(.secondary)
            }
        } else if let oc = onChain {
            if oc.reachedChain {
                onchainRow("Issuer registered", oc.issuerRegistered)
                onchainRow("Not revoked", oc.notRevoked)
                onchainRow("Root current", oc.rootCurrent)
                onchainRow("Header signature (on-chain key)", oc.headerSigValid)
                if let csca = oc.cscaProvenance {
                    onchainRow("Passport CSCA provenance", csca)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    Text("Couldn't reach the chain RPC.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Retry online checks") { Task { await runOnChain(p: nil, retry: true) } }
            }
            Text("Checks talk directly to the chain over a read-only RPC (Settings, Networks, Ethereum). No issuer or verifier server is involved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - collapsed-section status glyphs

    private enum SectionStatus { case pass, fail, warn, neutral, pending }

    @ViewBuilder
    private func groupLabel(_ title: String, _ status: SectionStatus) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            switch status {
            case .pass:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .fail:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .warn:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .pending: ProgressView()
            case .neutral: EmptyView()
            }
        }
    }

    private func aggregate(_ results: [LocalCheckResult]) -> SectionStatus {
        if results.contains(where: { if case .fail = $0 { return true } else { return false } }) { return .fail }
        let ok = results.allSatisfy { r in
            if case .pass = r { return true }
            if case .notApplicable = r { return true }
            return false
        }
        return ok ? .pass : .warn
    }

    private func cryptoStatus(_ v: LocalVerdict) -> SectionStatus {
        // Mirror the displayed rows: no verifierRequestValid in the open flow.
        var checks = [v.checks.merkleValid, v.checks.challengeSigValid,
                      v.checks.timestampValid, v.checks.expiryValid]
        if v.decision == "SELF_ATTESTED" { checks.append(v.checks.headerSigValid) }
        return aggregate(checks)
    }

    private func onchainStatus() -> SectionStatus {
        guard let oc = onChain else { return .pending }
        if !oc.reachedChain { return .warn }
        var tiers = [oc.issuerRegistered, oc.notRevoked, oc.rootCurrent, oc.headerSigValid]
        if let csca = oc.cscaProvenance { tiers.append(csca) }
        if tiers.contains(where: { if case .fail = $0 { return true } else { return false } }) { return .fail }
        return oc.fullyVerified ? .pass : .warn
    }

    private func havidStatus() -> SectionStatus {
        guard let h = havid else { return .pending }
        switch h.state {
        case .crossEndorsed: return .pass
        case .keyAlignmentFailure, .integrityFailure, .expiredRevoked: return .fail
        case .noEndorsement, .notResolvable: return .neutral
        }
    }

    private func onchainRow(_ name: String, _ tier: OnChainTier) -> some View {
        HStack {
            Text(name).font(.callout)
            Spacer(minLength: 8)
            switch tier {
            case .pass:
                Label("verified", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
            case .fail(let reason):
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case .unknown(let reason):
                Label(reason, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// Run the online pass. When `p` is nil (a retry), reuse the current verdict's
    /// presentation captured at display time is not available, so retry only
    /// re-runs when a presentation is in scope; the primary path passes it.
    private func runOnChain(_ p: Presentation, _ v: LocalVerdict) async {
        onChainRunning = true
        defer { onChainRunning = false }
        // Passport CSCA cert id, when disclosed, drives the CSCA provenance tier.
        var cscaCertId: String?
        if case .string(let s)? = v.disclosed["cscaCertId"] { cscaCertId = s }
        // Identity checks run on Sepolia (the issuer's identity chain); registry
        // addresses are the bundled Sepolia deployment, RPC from the app settings.
        let identityRPC = chainRPCs["eip155:11155111"] ?? EthereumNetwork.sepolia.defaultRPCURL
        let config = RegistryConfig.sepolia(rpcURL: identityRPC)
        // Revocation + root run on the chain the credential is ACTUALLY anchored
        // on. Pick the first anchor whose chain the app can reach (has an RPC),
        // preferring Sepolia; use the RevocationRegistry address the anchor names.
        let anchors = p.anchor?.anchors ?? []
        let anchor = anchors.first(where: { $0.chain == "eip155:11155111" && chainRPCs[$0.chain] != nil })
            ?? anchors.first(where: { chainRPCs[$0.chain] != nil })
        onChain = await OnChainVerifier(config: config)
            .verify(header: p.header, headerSig: p.headerSig, cscaCertIdHex: cscaCertId,
                    anchorBatchRoot: anchor?.batchRoot,
                    anchorRPCURL: anchor.flatMap { chainRPCs[$0.chain] },
                    anchorRevocationRegistry: anchor?.registry)
    }

    /// Retry shim used by the offline banner button.
    private func runOnChain(p: Presentation?, retry: Bool) async {
        guard case .verdict(let pres, let verdict) = phase else { return }
        await runOnChain(pres, verdict)
    }

    /// HAVID cross-endorsement tier (ADR-0051). A local HTTPS + X.509 check of
    /// the issuer's organisational certificate against its DID, distinct from the
    /// on-chain checks and from passport CSCA provenance.
    @ViewBuilder
    private var havidContent: some View {
        if let h = havid {
            switch h.state {
            case .crossEndorsed:
                Label("Issuer certificate matched", systemImage: "checkmark.shield.fill")
                    .font(.callout).foregroundStyle(.green)
                if let subject = h.subject, !subject.isEmpty {
                    kv("Certificate subject", subject)
                }
            case .keyAlignmentFailure, .integrityFailure, .expiredRevoked:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.shield.fill").foregroundStyle(.red)
                    Text(h.detail ?? "Issuer certificate does not match the DID")
                        .font(.callout).foregroundStyle(.red)
                }
            case .noEndorsement:
                Text("This issuer publishes no X.509 organisational certificate.")
                    .font(.callout).foregroundStyle(.secondary)
            case .notResolvable:
                Text(h.detail ?? "Issuer identity could not be resolved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking issuer certificate…").font(.callout).foregroundStyle(.secondary)
            }
        }
        Text("Confirms the issuer's real-world X.509 certificate cross-endorses its DID. A local check, no server involved.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Resolve the issuer's HAVID binding from the known-issuer well-known docs.
    private func runHavid(_ p: Presentation) async {
        havid = await HavidVerifier()
            .verify(header: p.header, headerSig: p.headerSig, candidateBaseURLs: knownIssuerBaseURLs)
    }

    /// Badge (no-PII reference) checks: the same on-chain issuer-assurance + HAVID
    /// the full presentation runs, minus the header signature (a badge carries no
    /// header). HAVID binds via the issuer's ON-CHAIN key instead.
    private func runBadgeChecks(_ b: BadgePayload) async {
        onChainRunning = true
        defer { onChainRunning = false }
        let identityRPC = chainRPCs["eip155:11155111"] ?? EthereumNetwork.sepolia.defaultRPCURL
        let config = RegistryConfig.sepolia(rpcURL: identityRPC)
        let anchors = b.anchors ?? b.anchor.map { [$0] } ?? []
        let anchor = anchors.first(where: { $0.chain == "eip155:11155111" && chainRPCs[$0.chain] != nil })
            ?? anchors.first(where: { chainRPCs[$0.chain] != nil })
        let ref = await OnChainVerifier(config: config).verifyReference(
            did: b.iss, cid: b.cid, iat: b.iat, cscaCertIdHex: nil,
            anchorBatchRoot: anchor?.batchRoot,
            anchorRPCURL: anchor.flatMap { chainRPCs[$0.chain] },
            anchorRevocationRegistry: anchor.flatMap { $0.registry }
        )
        onChain = ref.verdict
        havid = await HavidVerifier()
            .verifyReference(did: b.iss, candidateBaseURLs: knownIssuerBaseURLs, issuerPubkey: ref.issuerPubkey)
    }

    /// Badge top-line: a reference can confirm the issuer + revocation + root
    /// on-chain, but not the signature (no header), so "verified" here means the
    /// reference is confirmed, with that caveat spelled out.
    private func badgeOverallStatus() -> (icon: String, color: Color, title: String, summary: String) {
        guard let oc = onChain else {
            return ("hourglass", .gray, "Checking on-chain…", "Confirming the reference against the chain.")
        }
        if !oc.reachedChain {
            return ("wifi.slash", .orange, "Reference (offline)",
                    "Couldn't reach the chain to confirm this reference. Tap Scan another to retry.")
        }
        if let failReason = firstOnChainFailure(oc) {
            return ("exclamationmark.shield.fill", .red, "Verification failed", failReason)
        }
        let corePass = oc.issuerRegistered == .pass && oc.notRevoked == .pass && oc.rootCurrent == .pass
        if corePass {
            var summary = "Registered issuer, not revoked, current root, confirmed on-chain. Full signature check needs the complete credential."
            if havid?.state == .crossEndorsed {
                summary = "Registered issuer, not revoked, current root. Issuer certificate matches its DID. Full signature check needs the complete credential."
            }
            return ("checkmark.seal.fill", .green, "Reference verified on-chain", summary)
        }
        return ("checkmark.shield", .orange, "Reference verified, with limits", limitsSummary(oc))
    }

    /// On-chain section glyph for a badge: core issuer-assurance (no headerSig).
    private func badgeOnchainStatus() -> SectionStatus {
        guard let oc = onChain else { return .pending }
        if !oc.reachedChain { return .warn }
        for t in [oc.issuerRegistered, oc.notRevoked, oc.rootCurrent] {
            if case .fail = t { return .fail }
        }
        let corePass = oc.issuerRegistered == .pass && oc.notRevoked == .pass && oc.rootCurrent == .pass
        return corePass ? .pass : .warn
    }

    /// Single plain-language verdict combining the offline crypto checks, the
    /// holder's own on-chain pass, and HAVID. This app IS the online verifier, so
    /// when everything passes it says "Fully verified" rather than "locally valid".
    private func overallStatus(_ p: Presentation, _ v: LocalVerdict) -> (icon: String, color: Color, title: String, summary: String) {
        if v.decision == "DENY" {
            return ("xmark.shield.fill", .red, "Not valid", v.summary)
        }
        if v.decision == "SELF_ATTESTED" {
            switch appAttestResult(p) {
            case .pass:
                return ("checkmark.seal.fill", .green, "Self-issued (app-verified)",
                        "Self-issued by the holder, no third-party issuer. This device's app is genuine.")
            default:
                return ("person.crop.circle.badge.exclamationmark", .orange, "Self-issued",
                        "Self-issued by the holder, no third-party issuer.")
            }
        }
        // Issuer-bound: the top line reflects the on-chain result this app performs.
        guard let oc = onChain else {
            return ("hourglass", .gray, "Checking on-chain…",
                    "Cryptographic checks passed. Confirming issuer registration, revocation, and root on-chain.")
        }
        if !oc.reachedChain {
            return ("wifi.slash", .orange, "Valid on this device (offline)",
                    "Cryptographically valid, but the chain could not be reached to confirm the issuer. Tap retry below.")
        }
        // A genuine on-chain FAILURE (revoked, unregistered, bad signature, stale
        // root) is red. A check we simply couldn't run (unknown, e.g. the
        // presentation carries no anchor for this network) is NOT a failure.
        if let failReason = firstOnChainFailure(oc) {
            return ("exclamationmark.shield.fill", .red, "Verification failed", failReason)
        }
        if oc.fullyVerified {
            var summary = "Registered issuer, not revoked, current root, and issuer signature valid on-chain."
            if havid?.state == .crossEndorsed { summary += " Issuer certificate matches its DID." }
            return ("checkmark.seal.fill", .green, "Fully verified", summary)
        }
        return ("checkmark.shield", .orange, "Verified, with limits", limitsSummary(oc))
    }

    /// The first genuine on-chain failure reason, or nil when nothing FAILED
    /// (some checks may still be "unknown"/unavailable).
    private func firstOnChainFailure(_ oc: OnChainVerdict) -> String? {
        for tier in [oc.issuerRegistered, oc.notRevoked, oc.rootCurrent, oc.headerSigValid] {
            if case .fail(let reason) = tier { return reason }
        }
        if let csca = oc.cscaProvenance, case .fail(let reason) = csca { return reason }
        return nil
    }

    /// Summary for the "verified but not everything could be confirmed" case:
    /// what was confirmed on-chain, and what couldn't be (e.g. anchor freshness).
    private func limitsSummary(_ oc: OnChainVerdict) -> String {
        var confirmed: [String] = []
        var couldNot: [String] = []
        func note(_ name: String, _ t: OnChainTier) {
            if case .pass = t { confirmed.append(name) }
            else if case .unknown = t { couldNot.append(name) }
        }
        note("registration", oc.issuerRegistered)
        note("revocation", oc.notRevoked)
        note("signature", oc.headerSigValid)
        note("anchor freshness", oc.rootCurrent)
        var s = ""
        if !confirmed.isEmpty { s += "Confirmed on-chain: \(confirmed.joined(separator: ", ")). " }
        if !couldNot.isEmpty { s += "Couldn't confirm: \(couldNot.joined(separator: ", "))." }
        return s.isEmpty ? "Some on-chain checks couldn't be completed." : s
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
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Long-press any field (disclosed claim, issuer, schema, CID) to copy its
        // full value; text selection stays available for partial copies.
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
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
