// Native "collect a customer's credential" sheet for
// window.maknoon.identity.collect — the cross-device merchant→customer
// verify step.
//
// The merchant runs the camera; the customer presents a credential from
// their own wallet (open share or any presentation QR: a raw presentation,
// a rotating multi-frame QR, or a one-shot drop envelope). We verify it
// offline (signatures, Merkle proofs, delegation, expiry), then enforce the
// merchant's policy: required schema + claims present, and — for the
// sanctions credential — the disclosed `sanctionsScreenedAt` within
// `maxAgeSec`. The cryptographic verification is the shipped
// `PresentationVerifier.verifyOffline`; the freshness check mirrors the
// verifier server's attestationFresh gate on a Merkle-proven claim.
//
// (A merchant-shows-signed-request QR + server /v1/verify path is a
// follow-on: it needs a registered verifier identity or a request_uri host,
// neither of which an ad-hoc device verifier has.)

import SwiftUI

@MainActor
@Observable
final class MiniAppCollectCoordinator {
    struct Request: Identifiable {
        let id = UUID()
        let appTitle: String
        let purpose: String?
        let schema: String?
        let requiredClaims: [String]
        let maxAgeSec: Int64?
        /// Short GET URL of a hosted, signed VerifierRequest the customer can
        /// scan with their wallet. nil when hosting wasn't possible.
        var requestURL: String? = nil
        /// requestId of the hosted request, used to poll the verifier server
        /// for the holder's posted verdict (server-mediated, no scan needed).
        var requestId: String? = nil
    }

    private(set) var active: Request?
    private var continuation: CheckedContinuation<[String: Any], Error>?

    func present(_ r: Request) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.active = r
        }
    }

    func resolve(_ result: [String: Any]) {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(returning: result)
    }
    func cancel() {
        let cont = continuation; continuation = nil; active = nil
        cont?.resume(throwing: MiniAppBridgeError.userRejected())
    }
}

struct MiniAppCollectSheet: View {
    let request: MiniAppCollectCoordinator.Request
    let onResolve: ([String: Any]) -> Void
    let onCancel: () -> Void

    @StateObject private var frames = LocalFrameReceiver()
    @State private var status: String = "Ask the customer to present their credential"
    @State private var busy = false
    @State private var banner: Banner = .info
    /// True after a terminal outcome (a denial or an unreadable scan): scanning
    /// is paused so re-scanned rotating frames can't clobber the message, and a
    /// "Scan again" button is shown.
    @State private var showRetry = false
    /// The most recent DENY verdict, kept so the merchant can return it to the
    /// dApp via "Decline" instead of the sheet auto-closing on a fixable miss.
    @State private var lastDenied: [String: Any]?
    /// Set once a result has been returned to the dApp (via scan OR server
    /// poll), so the two paths can't both resolve.
    @State private var done = false

    enum Banner {
        case info, working, warn, error
        var color: Color {
            switch self {
            case .info:    return .gray
            case .working: return .blue
            case .warn:    return .orange
            case .error:   return .red
            }
        }
        var icon: String {
            switch self {
            case .info:    return "qrcode.viewfinder"
            case .working: return "arrow.triangle.2.circlepath"
            case .warn:    return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(request.appTitle).font(.headline)
                Text("Requesting: \(request.requiredClaims.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // Customer can scan THIS to present (easiest), or the merchant
                // can scan the customer's presentation below — first wins.
                if let url = request.requestURL, let img = BadgeQR.render(Data(url.utf8), scale: 7) {
                    VStack(spacing: 4) {
                        ZStack {
                            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 180, maxHeight: 180)
                            Image(systemName: "person.text.rectangle.fill")
                                .font(.caption).padding(5)
                                .background(.background, in: Circle())
                                .overlay(Circle().stroke(.purple, lineWidth: 2))
                        }
                        Text("Customer scans this").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("…or scan the customer").font(.caption2).foregroundStyle(.tertiary)
                QRScannerView(onCode: { handle($0) }, continuous: true)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                if !showRetry {
                    QRPhotoPickerButton(onCode: { handle($0) }, onNoQR: {
                        banner = .warn
                        status = "No QR code found in that image. Pick the customer's single Attribute or drop QR; a rotating code needs the live camera."
                    }) {
                        Label("Choose photo", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }
                if frames.totalFrames > 0 {
                    ProgressView(value: Double(frames.receivedFrames), total: Double(max(frames.totalFrames, 1)))
                    Text("Receiving \(frames.receivedFrames)/\(frames.totalFrames) frames…").font(.caption2)
                }
                statusBanner
                if showRetry {
                    Button { resumeScanning() } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Verify customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                if lastDenied != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Decline") { if let d = lastDenied { done = true; onResolve(d) } }
                    }
                }
            }
            .task(id: request.requestId) {
                guard let requestId = request.requestId else { return }
                await pollForServerVerdict(requestId: requestId)
            }
        }
    }

    /// High-contrast status line so messages are legible over the camera feed.
    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            if busy && !showRetry {
                ProgressView().tint(.white)
            } else {
                Image(systemName: banner.icon).foregroundStyle(.white)
            }
            Text(status)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(banner.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Stop scanning after a terminal outcome and surface the message + a
    /// "Scan again" affordance. Resetting frames keeps a still-cycling rotating
    /// QR from re-reassembling and overwriting the message.
    private func pauseForRetry(_ message: String, banner: Banner = .error) {
        status = message
        self.banner = banner
        busy = true
        showRetry = true
        frames.reset()
    }

    private func resumeScanning() {
        status = "Ask the customer to present their credential"
        banner = .info
        busy = false
        showRetry = false
        lastDenied = nil
        frames.reset()
    }

    // MARK: -- ingest

    private func handle(_ payload: String) {
        guard !busy, !done else { return }
        // 1) one-shot drop envelope -> fetch the presentation.
        if let env = try? JSONDecoder().decode(DropEnvelope.self, from: Data(payload.utf8)),
           env.v == 1, !env.dropId.isEmpty {
            busy = true; banner = .working; status = "Fetching the customer's presentation…"
            Task {
                do {
                    let p = try await PresentationDrop.fetch(host: HolderStore.elabifyDropHost, dropId: env.dropId)
                    finish(p)
                } catch {
                    pauseForRetry("Could not fetch the customer's presentation. Ask them to show it again.")
                }
            }
            return
        }
        // 2) multi-frame presentation. `ingest` returns true when this string
        //    was a valid frame; `reassembled` is non-nil only once every frame
        //    is in. Report progress so a partial scan is not silent.
        if frames.ingest(payload) {
            if let data = frames.reassembled {
                if let p = try? JSONDecoder().decode(Presentation.self, from: data) {
                    finish(p)
                } else {
                    pauseForRetry("Scanned \(frames.totalFrames) frames but couldn't read them as a credential. Ask for the customer's Attribute QR.")
                }
            } else {
                banner = .working
                status = "Receiving frames \(frames.receivedFrames)/\(frames.totalFrames)… hold steady."
            }
            return
        }
        // 3) raw presentation JSON.
        if let p = try? JSONDecoder().decode(Presentation.self, from: Data(payload.utf8)) {
            finish(p); return
        }
        // 4) a privacy badge carries no attributes, so it can't satisfy a
        //    collect request. Say so instead of silently ignoring it.
        if let badge = try? JSONDecoder().decode(BadgePayload.self, from: Data(payload.utf8)),
           badge.v == "elabify-badge-1" {
            banner = .warn
            status = "That's a privacy badge — it shares no attributes. Ask the customer to show their Attribute QR (single or rotating)."
            return
        }
        // 5) anything else: an unrecognized code (a payment QR, a website, etc.).
        banner = .warn
        status = "Unrecognized code. Ask the customer to show their Attribute QR (single or rotating)."
    }

    private func finish(_ p: Presentation) {
        busy = true
        let verdict = PresentationVerifier.verifyOffline(p)
        let disclosed = Dictionary(uniqueKeysWithValues: p.disclosed.map { ($0.key, $0.value.anyValue) })

        // Policy enforcement on top of the cryptographic verdict.
        var reasons: [String] = []
        if let schema = request.schema, p.header.schema != schema {
            reasons.append("wrong_schema")
        }
        let disclosedKeys = Set(p.disclosed.map { $0.key })
        let missing = request.requiredClaims.filter { !disclosedKeys.contains($0) }
        if !missing.isEmpty { reasons.append("missing_claims") }

        // Sanctions gate, shared with the commerce policy: reads the passport
        // `sdnScreen` object (clean + fresh) or the legacy flat key.
        let sanctions = CommerceMerchantPolicy.extractSanctions(fromDisclosed: disclosed)
        let sanctionsReason = CommerceMerchantPolicy.sanctionsReason(
            sanctions, maxAgeSec: request.maxAgeSec, nowSec: Int64(Date().timeIntervalSince1970))
        let fresh = (sanctionsReason != "stale_screening")
        if let sanctionsReason { reasons.append(sanctionsReason) }

        let cryptoOK = verdict.checks.overallPass
        if !cryptoOK { reasons.append("verification_failed") }

        let decision = (cryptoOK && reasons.isEmpty) ? "GRANT" : "DENY"
        let message = Self.denialMessage(
            reasons: reasons,
            missing: missing,
            disclosedKeys: p.disclosed.map { $0.key },
            requestedSchema: request.schema,
            actualSchema: p.header.schema,
            summary: verdict.summary
        )
        let result: [String: Any] = [
            "decision": decision,
            "reason": reasons.first ?? "ok",
            // Named missing claims + a human message so the dApp (and the
            // merchant) can say exactly which attributes the customer must add.
            "missing": missing,
            "message": message ?? "",
            "schema": p.header.schema,
            "disclosed": disclosed,
            "checks": [
                "verified": cryptoOK,
                "fresh": fresh,
                "summary": verdict.summary,
            ],
            // Issuer-signed credentials' on-chain checks can't run offline, so
            // a real deployment should also hit /v1/verify. Flag that here.
            "offline": true,
        ]

        if decision == "GRANT" {
            done = true
            onResolve(result)
            return
        }
        // A denial is usually fixable (the customer disclosed the wrong fields,
        // or showed the wrong QR). Pause + show exactly what's wrong; "Scan
        // again" retries without an app round-trip, and the toolbar's "Decline"
        // returns this verdict to the dApp.
        lastDenied = result
        pauseForRetry(message ?? "The customer's credential was declined.")
    }

    // MARK: -- server-mediated poll (round trip)

    /// Poll the verifier server for the holder's posted verdict. After the
    /// customer scans the hosted request and taps Approve, their wallet POSTs
    /// the Presentation to /v1/verify/callback; the server verifies it and
    /// stashes the verdict keyed by requestId. We poll /v1/verify/result/:id
    /// until it appears — completing the round trip without the merchant
    /// scanning the customer.
    private func pollForServerVerdict(requestId: String) async {
        let base = HolderStore.elabifyDropHost
        while !Task.isCancelled && !done {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if done || Task.isCancelled { return }
            let url = base.appendingPathComponent("/v1/verify/result/\(requestId)")
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else { continue }
            struct Poll: Decodable { let found: Bool; let verdict: VerifyResponse? }
            guard let poll = try? JSONDecoder().decode(Poll.self, from: data),
                  poll.found, let verdict = poll.verdict else { continue }
            finishFromServer(verdict)
            return
        }
    }

    /// Map the verifier server's authoritative verdict to the dApp result.
    /// GRANT resolves immediately; DENY pauses with the reason + Decline
    /// affordance (mirrors the scan path).
    private func finishFromServer(_ verdict: VerifyResponse) {
        guard !done else { return }
        let disclosed = (verdict.disclosed ?? [:]).reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue }
        let checks = verdict.checks.reduce(into: [String: Any]()) { $0[$1.key] = $1.value?.anyValue ?? NSNull() }
        let granted = verdict.decision == "GRANT"
        let result: [String: Any] = [
            "decision": verdict.decision,
            "reason": verdict.reason,
            "missing": [String](),
            "message": granted ? "" : "The verifier server declined: \(verdict.reason).",
            "disclosed": disclosed,
            "checks": checks,
            "offline": false,
        ]
        if granted {
            done = true
            onResolve(result)
        } else {
            lastDenied = result
            pauseForRetry("The customer's credential was declined by the verifier (\(verdict.reason)).")
        }
    }

    /// Build a merchant-facing explanation for a DENY. Pure + internal so it is
    /// unit-testable. Returns nil only when there is no reason (a GRANT).
    static func denialMessage(
        reasons: [String],
        missing: [String],
        disclosedKeys: [String],
        requestedSchema: String?,
        actualSchema: String,
        summary: String
    ) -> String? {
        guard let first = reasons.first else { return nil }
        switch first {
        case "missing_claims":
            let shared = disclosedKeys.isEmpty
                ? "nothing"
                : disclosedKeys.sorted().joined(separator: ", ")
            return "Missing: \(missing.joined(separator: ", ")). The customer shared: \(shared). Ask them to include the missing attributes and present again."
        case "wrong_schema":
            return "Wrong credential type. Expected \(requestedSchema ?? "a different credential"), but the customer presented \(actualSchema)."
        case "stale_screening":
            return "The customer's sanctions screening is missing or older than allowed. Ask for a fresh screening."
        case "sanctioned":
            return "The customer's sanctions screening is not clean (flagged). Payment blocked."
        case "verification_failed":
            return "Could not verify the credential. \(summary)"
        default:
            return "Declined: \(first)"
        }
    }
}
