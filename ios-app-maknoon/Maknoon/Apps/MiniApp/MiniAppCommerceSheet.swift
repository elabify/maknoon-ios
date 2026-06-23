// Merchant side of server-mediated Verify & Pay (ADR-0031). Hosts the signed
// CommerceRequest, shows a SMALL URL QR for the customer to scan (from Identity
// -> Scan verifier), and polls the server for the holder's response. The holder
// has already signed + broadcast the payment and posted {presentation, txHash};
// the merchant verifies the presentation on-device (CommerceMerchantPolicy) and
// returns the verdict + txHash to the app.

import SwiftUI

struct MiniAppCommerceSheet: View {
    let request: MiniAppCommerceCoordinator.Request
    let store: HolderStore
    let onResolve: ([String: Any]) -> Void
    let onCancel: () -> Void

    @State private var qr: UIImage?
    @State private var status = "Preparing…"
    @State private var requestId: String?
    /// expiresAt (unix s) of the request currently on screen; drives the
    /// countdown. The QR auto-rotates (re-mints a fresh request) on expiry.
    @State private var activeExpiresAt: Int64 = 0
    @State private var remaining: Int = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var base: URL { HolderStore.elabifyDropHost }
    private var terms: PaymentTerms { request.commerce.paymentTerms }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // The merchant's own name (sent by the app), not the catalog title.
                Text(request.commerce.merchantName ?? request.appTitle).font(.headline)
                // Show the merchant-specified crypto amount + network as the
                // headline (testnets have no fiat); fiat only when provided.
                if let rail = terms.acceptedRails.first, let amt = rail.amount {
                    Text("\(amt) \(rail.asset)").font(.title2.weight(.bold))
                    Text(rail.displayNetwork).font(.caption).foregroundStyle(.secondary)
                }
                if terms.hasFiatValue {
                    Text("≈ \(terms.fiatAmount) \(terms.fiatCode)").font(.subheadline).foregroundStyle(.secondary)
                }
                if !request.commerce.verifierRequest.filter.requiredClaims.isEmpty {
                    Text("Requesting: \(request.commerce.verifierRequest.filter.requiredClaims.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .padding(12).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 14))
                    Text("Customer scans this with Identity → Scan verifier")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    // Countdown: the request expires server-side, so show the
                    // remaining validity and auto-rotate to a fresh code at zero.
                    Text(remaining > 0 ? "Code refreshes in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Refreshing code…")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Verify & Pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
            .task { await run() }
            .onReceive(tick) { _ in
                if activeExpiresAt > 0 {
                    remaining = max(0, Int(activeExpiresAt - Int64(Date().timeIntervalSince1970)))
                }
            }
        }
    }

    private func run() async {
        // The request currently on screen. Rotates (re-mints) on expiry so a QR
        // left up past its validity window stops 404-ing the customer.
        var commerce = request.commerce
        var keypair = request.responseKeypair
        while !Task.isCancelled {
            // 1. Host the current signed request; render its short URL as a QR.
            let id: String
            do {
                id = try await CommerceTransport.hostRequest(baseURL: base, commerce)
            } catch {
                status = "Couldn't reach the server. Check connectivity and try again."
                return
            }
            requestId = id
            activeExpiresAt = commerce.paymentTerms.expiresAt
            remaining = max(0, Int(activeExpiresAt - Int64(Date().timeIntervalSince1970)))
            let url = base.appendingPathComponent("/v1/commerce-request/\(id)").absoluteString
            qr = BadgeQR.render(Data(url.utf8), scale: 7)
            status = "Waiting for the customer to confirm…"

            // 2. Poll until the holder responds OR the request expires.
            var expired = false
            while !Task.isCancelled {
                if Int64(Date().timeIntervalSince1970) >= commerce.paymentTerms.expiresAt {
                    expired = true
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let env = (try? await CommerceTransport.pollResult(baseURL: base, requestId: id)) ?? nil
                else { continue }
                // Opaque to the server; decrypt with our current ephemeral keypair.
                do {
                    let resp = try CommerceSeal.open(env, keypair: keypair, as: CommerceServerResponse.self)
                    finish(resp, commerce: commerce)
                } catch {
                    status = "Received a response but couldn't decrypt it. Ask the customer to try again."
                }
                return
            }

            // 3. Expired with no response -> re-mint a fresh request + keypair.
            guard expired, !Task.isCancelled else { return }
            status = "Refreshing code…"
            guard let rebuilt = try? await rebuild(from: commerce) else {
                status = "This code expired. Tap Cancel and charge again."
                return
            }
            commerce = rebuilt.request
            keypair = rebuilt.responseKeypair
        }
    }

    /// Re-mint a CommerceRequest with the same terms but a fresh challenge,
    /// nonce, ephemeral keypair, and validity window (QR rotation on expiry).
    private func rebuild(from old: CommerceRequest) async throws -> (request: CommerceRequest, responseKeypair: TransportHolder) {
        let vr = old.verifierRequest
        return try await CommerceRequestFactory.build(
            store: store,
            installedAppId: request.installedAppId,
            merchantName: old.merchantName ?? request.appTitle,
            schema: vr.filter.schemas?.list?.first,
            requiredClaims: vr.filter.requiredClaims,
            issuers: vr.filter.issuers?.list,
            identityMaxAgeSec: old.identityMaxAgeSec,
            fiatAmount: old.paymentTerms.fiatAmount,
            fiatCode: old.paymentTerms.fiatCode,
            acceptedRails: old.paymentTerms.acceptedRails,
            reference: old.paymentTerms.reference,
            floorMinor: old.paymentTerms.floorMinor,
            lane: old.lane)
    }

    private func finish(_ resp: CommerceServerResponse, commerce: CommerceRequest) {
        // The holder already broadcast; verify identity on-device + record txHash.
        // Evaluate against the request the holder actually answered (which may be
        // a rotated re-mint), so the nonce + echoed verifierRequest bind.
        let cr = CommerceResponse(
            v: 1, presentation: resp.presentation,
            payment: CommercePayment(rail: resp.payment.rail, signedTx: nil, settlementRef: resp.payment.txHash),
            nonce: commerce.paymentTerms.nonce)
        let verdict = CommerceMerchantPolicy.evaluate(response: cr, request: commerce)
        // The app records its own receipt (txlog) from the returned result; no
        // duplicate native store.
        onResolve([
            "decision": verdict.granted ? "GRANT" : "DENY",
            "reason": verdict.reason,
            "missing": verdict.missing,
            "message": verdict.message ?? "",
            "txHash": resp.payment.txHash,
            "disclosed": resp.presentation.disclosed.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.anyValue },
        ])
    }
}
