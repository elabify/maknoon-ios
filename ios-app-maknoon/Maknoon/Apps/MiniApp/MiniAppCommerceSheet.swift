// Merchant side of server-mediated Verify & Pay (ADR-0031). Hosts the signed
// CommerceRequest, shows a SMALL URL QR for the customer to scan (from Identity
// -> Scan verifier), and polls the server for the holder's response. The holder
// has already signed + broadcast the payment and posted {presentation, txHash};
// the merchant verifies the presentation on-device (CommerceMerchantPolicy) and
// returns the verdict + txHash to the dApp.

import SwiftUI

struct MiniAppCommerceSheet: View {
    let request: MiniAppCommerceCoordinator.Request
    let store: HolderStore
    let onResolve: ([String: Any]) -> Void
    let onCancel: () -> Void

    @State private var qr: UIImage?
    @State private var status = "Preparing…"
    @State private var requestId: String?

    private var base: URL { HolderStore.elabifyDropHost }
    private var terms: PaymentTerms { request.commerce.paymentTerms }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                // The merchant's own name (sent by the dApp), not the catalog title.
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
        }
    }

    private func run() async {
        // 1. Host the signed request; render its short URL as a small QR.
        do {
            let id = try await CommerceTransport.hostRequest(baseURL: base, request.commerce)
            requestId = id
            let url = base.appendingPathComponent("/v1/commerce-request/\(id)").absoluteString
            qr = BadgeQR.render(Data(url.utf8), scale: 7)
            status = "Waiting for the customer to confirm…"
        } catch {
            status = "Couldn't reach the server. Check connectivity and try again."
            return
        }
        // 2. Poll for the holder's response.
        guard let id = requestId else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let polled = try? await CommerceTransport.pollResult(baseURL: base, requestId: id)
            guard let env = polled ?? nil else { continue }
            // Opaque to the server; decrypt with our ephemeral keypair.
            do {
                let resp = try CommerceSeal.open(env, keypair: request.responseKeypair,
                                                 as: CommerceServerResponse.self)
                finish(resp)
            } catch {
                status = "Received a response but couldn't decrypt it. Ask the customer to try again."
            }
            return
        }
    }

    private func finish(_ resp: CommerceServerResponse) {
        // The holder already broadcast; verify identity on-device + record txHash.
        // requestId keying + the presentation's echoed verifierRequest bind the
        // response, so reuse the merchant's own nonce for the policy check.
        let cr = CommerceResponse(
            v: 1, presentation: resp.presentation,
            payment: CommercePayment(rail: resp.payment.rail, signedTx: nil, settlementRef: resp.payment.txHash),
            nonce: terms.nonce)
        let verdict = CommerceMerchantPolicy.evaluate(response: cr, request: request.commerce)
        // The dApp records its own receipt (txlog) from the returned result; no
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
