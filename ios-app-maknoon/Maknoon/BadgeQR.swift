// CoreImage QR code generator for the "badge" presentation mode.
//
// The badge payload is a tiny JSON object containing the credential's
// public identifiers (issuer DID, schema, cid, iat) plus the on-chain
// anchor reference. No claims, no holder pubkey, no PII. A verifier
// scanning the QR can resolve the full credential header + signature
// out-of-band via the anchor (Sepolia tx) or via the issuer's pickup
// archive; the QR itself is small enough to fit comfortably in a QR
// version ~10 with high error correction.
//
// ML-DSA-65 signatures are ~3.3 kB and would not fit in any standard QR.
// Putting them inline is therefore impossible; the badge is intentionally
// a "credential reference" rather than a self-contained proof. This is
// the static-replayable model the user picked: a verifier confirms the
// credential exists and is anchored, but does not authenticate the
// holder. PII is never exposed.

import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Wire format for the QR contents. JSON-encoded, UTF-8.
struct BadgePayload: Codable {
    /// Format version. Always "elabify-badge-1" for now.
    let v: String
    /// Issuer DID.
    let iss: String
    /// Subject DID. Often a placeholder ("did:elabify:holder") in the
    /// demo because PII-free badges deliberately do not bind to a
    /// specific holder identity.
    let sub: String
    /// Schema URI.
    let schema: String
    /// Credential ID.
    let cid: String
    /// Issuance time (unix-seconds).
    let iat: Int64
    /// Optional expiry (unix-seconds).
    let exp: Int64?
    /// On-chain anchor reference (the FIRST anchor). Kept for backward
    /// compatibility with `elabify-badge-1` decoders; new code reads `anchors`.
    let anchor: BadgeAnchor?
    /// All on-chain anchors (ADR-0030 multi-network). A credential's batch root
    /// can be anchored on several chains; a verifier may confirm it on any of
    /// them. Additive field: omitted when there are no anchors; old decoders
    /// fall back to `anchor`.
    let anchors: [BadgeAnchor]?
}

struct BadgeAnchor: Codable {
    let chain: String
    let batchTxHash: String
    let batchRoot: String
    /// Registry contract address for this chain. Optional for back-compat with
    /// `elabify-badge-1` payloads that predate the field.
    let registry: String?
}

enum BadgeQR {

    /// Build the JSON payload to encode. Pure function; no UI side effects.
    static func payload(for credential: Credential) -> BadgePayload {
        let all = (credential.anchor?.anchors ?? []).map { a in
            BadgeAnchor(
                chain:       a.chain,
                batchTxHash: a.batchTxHash,
                batchRoot:   a.batchRoot,
                registry:    a.registry
            )
        }
        return BadgePayload(
            v:       "elabify-badge-1",
            iss:     credential.header.iss,
            sub:     credential.header.sub,
            schema:  credential.header.schema,
            cid:     credential.header.cid,
            iat:     credential.header.iat,
            exp:     credential.header.exp,
            anchor:  all.first,
            anchors: all.isEmpty ? nil : all
        )
    }

    /// Build the QR image from a credential. Returns nil only on
    /// programmer error (CoreImage cannot find the filter, etc.).
    static func image(for credential: Credential, scale: CGFloat = 8) -> UIImage? {
        do {
            let payload = payload(for: credential)
            let bytes = try JSONEncoder().encode(payload)
            return render(bytes, scale: scale)
        } catch {
            return nil
        }
    }

    /// Render arbitrary bytes as a QR with medium error correction.
    /// Public so future call-sites (e.g. a presentation-with-challenge
    /// flow) can reuse the same rendering pipeline.
    static func render(_ data: Data, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Medium error correction keeps the QR readable across reasonable
        // lighting / lens situations without blowing up the version too
        // hard for the small badge payload.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
