// Shared issuer-selection + issuance plumbing used by both the
// post-scan "minted" step (TapIDDocumentSheet) and the full document
// detail screen (IDDocumentDetailView). Keeping the picker, the URL
// resolver, and the submit-and-queue logic in one place means the two
// entry points can't drift apart.

import SwiftUI

/// Resolves the issuer Picker selection (a `KnownIssuersStore` host /
/// `host:port` entry, or the Custom sentinel plus a typed URL) into the
/// outbound base URL the issuance POST should target.
enum IssuerSelection {
    /// Sentinel value placed at the end of the issuer Picker; selecting
    /// it reveals an inline TextField for a one-off URL (e.g. an ngrok
    /// tunnel, or a LAN dev server not yet added to Known Issuers).
    static let customSentinel = "__custom__"

    /// The base URL the issuance / sanctions calls should target.
    /// Returns nil when the user picked Custom and hasn't typed a
    /// parseable URL yet, callers use that nil to disable the submit
    /// action so we don't fire half-formed requests.
    ///
    /// When `selectedEntry` is empty (picker hasn't seeded a selection
    /// yet, or is off screen) we fall back to the first known issuer so
    /// actions stay enabled whenever a trusted issuer is configured.
    static func resolveBaseURL(
        selectedEntry: String,
        customURL: String,
        knownIssuers: KnownIssuersStore
    ) -> URL? {
        let entry = selectedEntry.isEmpty
            ? (knownIssuers.hosts.first ?? customSentinel)
            : selectedEntry
        if entry == customSentinel {
            let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Accept either a full URL (`http://...`) or a bare
            // host[:port]; fall back to the known-issuers helper for the
            // second case so the local-dev scheme heuristic applies.
            if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
                return url
            }
            return knownIssuers.outboundBaseURL(forEntry: trimmed)
        }
        return knownIssuers.outboundBaseURL(forEntry: entry)
    }
}

/// Dropdown of known issuers (host / host:port entries from Settings →
/// Identity → Known Issuers) plus a "Custom URL…" sentinel that reveals
/// a free-form URL field. The selected entry is resolved to a base URL
/// at submit time via `IssuerSelection.resolveBaseURL`.
struct IssuerPickerField: View {
    let knownIssuers: KnownIssuersStore
    @Binding var selectedEntry: String
    @Binding var customURL: String

    var body: some View {
        let entries = knownIssuers.hosts
        Picker("Issuer", selection: $selectedEntry) {
            if entries.isEmpty {
                // The default-seeded store always ships with at least
                // the production issuers; this branch only hits if the
                // user removed every entry. Show the sentinel so the
                // picker remains usable.
                Text("Custom URL").tag(IssuerSelection.customSentinel)
            } else {
                ForEach(entries, id: \.self) { entry in
                    Text(entry).tag(entry)
                }
                Text("Custom URL…").tag(IssuerSelection.customSentinel)
            }
        }
        .pickerStyle(.menu)
        .onAppear {
            // Seed the selection the first time this renders. Prefer a
            // previously-picked entry; otherwise the first known issuer;
            // otherwise drop to Custom.
            if selectedEntry.isEmpty {
                selectedEntry = entries.first ?? IssuerSelection.customSentinel
            }
        }
        if selectedEntry == IssuerSelection.customSentinel {
            TextField("http://192.168.1.50:4000", text: $customURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.callout.monospaced())
        }
    }
}

/// Submit-and-queue logic shared by both issuance entry points. Posts
/// the passport attestation packet and, on an auto-approved ack, queues
/// the background pickup so the credential lands on the Identity tab on
/// its own.
enum IDDocumentIssuance {
    enum Outcome: Equatable {
        /// Issuer auto-approved on submit; pickup is now queued in the
        /// holder's background poller.
        case submittedForAnchor(credentialId: String)
        /// Packet accepted but waiting for an operator to approve (or
        /// pre-verification didn't pass).
        case pendingReview(pendingId: String, proofPreVerified: Bool, reason: String)
    }

    @MainActor
    static func submit(
        doc: IDDocument,
        store: HolderStore,
        baseURL: URL
    ) async throws -> Outcome {
        let ack = try await IDDocumentIssuanceClient.submit(
            document: doc,
            store: store,
            issuerBaseURL: baseURL.absoluteString
        )
        // Auto-mint branch: server pre-verified + auto-approved. Queue
        // the pickup with the holder-store background poller so the user
        // can close this screen and continue while the credential
        // anchors. The pending row appears at the top of the Identity tab
        // with a cancel button.
        if ack.status == "approved",
           let pickup = ack.pickupUrl,
           let credentialId = ack.credentialId {
            let resolvedPickup = rewritePickupURLForLAN(pickup, fallbackBase: baseURL)
            store.pendingPickups.add(
                PendingPickup(
                    id: credentialId,
                    credentialId: credentialId,
                    pickupURL: resolvedPickup,
                    schemaURI: "elabify://schema/global/passport/v1",
                    humanLabel: "Verified Identity",
                    startedAt: Date()
                )
            )
            return .submittedForAnchor(credentialId: credentialId)
        }
        // Pending-review branch: operator approves later (or
        // pre-verification failed and the operator is the backstop).
        return .pendingReview(
            pendingId: ack.pendingId,
            proofPreVerified: ack.proofPreVerified,
            reason: ack.proofPreVerifiedReason
        )
    }

    /// The issuer builds pickup URLs from its configured base (typically
    /// `http://localhost:4000/...` in dev mode). When the holder reaches
    /// the issuer through a LAN IP, the localhost URL won't resolve from
    /// the phone, rewrite it to use the same base we submitted to.
    /// Production deployments configure ELABIFY_PICKUP_BASE_URL with
    /// their public hostname and this rewrite is a no-op.
    static func rewritePickupURLForLAN(_ url: String, fallbackBase: URL) -> String {
        guard let original = URL(string: url),
              let host = original.host,
              host == "localhost" || host == "127.0.0.1"
        else { return url }
        var comps = URLComponents(url: original, resolvingAgainstBaseURL: false)
        comps?.host = fallbackBase.host
        comps?.port = fallbackBase.port
        comps?.scheme = fallbackBase.scheme
        return comps?.url?.absoluteString ?? url
    }
}
