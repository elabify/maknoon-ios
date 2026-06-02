// Local multi-frame QR transport. The default Share-as-QR path uses this
// instead of uploading to the Elabify drop pastebin: the holder's device
// renders a rotating sequence of small QRs, the verifier's scanner
// collects frames until the payload reassembles. No network, no
// third-party infrastructure.
//
// Frame envelope (each individual QR encodes one of these):
//
//   { "v": "elabify-frames-1",
//     "id": "<16-hex>",      // transmission ID; lets the receiver tell
//                            //   concurrent transmissions apart
//     "idx": 0,              // 0-based frame index
//     "total": 16,           // total number of frames
//     "data": "<base64>" }   // chunk of the source bytes
//
// Source bytes for a Presentation are the JSON-encoded `Presentation`
// value, base64-encoded for QR friendliness. Chunk size targets ~750
// raw bytes which fits a QR version ~25 with medium error correction.
//
// Out of scope: BC-UR fountain codes / loss tolerance / interleaved
// frame ordering. The simple round-robin transmission is fine at the
// 3 fps refresh rate AVFoundation easily keeps up with.

import Foundation
import UIKit

/// Maximum number of source bytes (pre-base64) per frame. Tuned so the
/// JSON envelope plus the base64-encoded chunk stays under ~1 kB, which
/// fits a QR version ~25 at medium error correction.
private let chunkBytes = 750

struct LocalFrameEnvelope: Codable {
    /// Sentinel string that lets the receiver detect this format quickly.
    /// Held at -1 (uncompressed base64 chunks) so the wire format stays
    /// byte-for-byte identical to the React verifier's decoder — that
    /// cross-platform contract is what lets an iOS holder present to a
    /// React verifier. A -2 zlib-compressed variant was tried to shrink
    /// large presentations but reverted: it forced a cross-language
    /// raw-DEFLATE dependency on every verifier for a frame-count win that
    /// selecting fewer claims achieves more simply.
    static let version = "elabify-frames-1"

    let v: String
    let id: String
    let idx: Int
    let total: Int
    let data: String   // base64 of the chunk
}

/// Splits arbitrary bytes into a numbered sequence of frame envelopes.
enum LocalFrames {
    /// Produce the rotating-QR frame sequence for the given source bytes.
    /// All frames share the same `id` and `total`; the receiver
    /// reassembles by collecting one frame per `idx`.
    static func chunks(of source: Data) -> [LocalFrameEnvelope] {
        let base64 = source.base64EncodedString()
        let base64Bytes = Array(base64.utf8)
        var frames: [LocalFrameEnvelope] = []
        let idHex = randomHexId()
        var idx = 0
        var offset = 0
        // Compute total up front so envelopes carry a stable `total`.
        let chunksPerB64: Int = Int((Double(base64Bytes.count) / Double(chunkBytes)).rounded(.up))
        let total = max(1, chunksPerB64)
        while offset < base64Bytes.count {
            let end = min(offset + chunkBytes, base64Bytes.count)
            let slice = String(decoding: base64Bytes[offset..<end], as: UTF8.self)
            frames.append(LocalFrameEnvelope(
                v: LocalFrameEnvelope.version,
                id: idHex,
                idx: idx,
                total: total,
                data: slice
            ))
            offset = end
            idx += 1
        }
        if frames.isEmpty {
            // Edge case: empty source. Emit a single empty frame so the
            // receiver still sees a complete transmission.
            frames.append(LocalFrameEnvelope(
                v: LocalFrameEnvelope.version,
                id: idHex,
                idx: 0,
                total: 1,
                data: ""
            ))
        }
        return frames
    }

    /// Render a single envelope as a QR `UIImage`. Returns nil only on
    /// CoreImage filter setup failure.
    static func renderFrame(_ frame: LocalFrameEnvelope) -> UIImage? {
        guard let json = try? JSONEncoder().encode(frame) else { return nil }
        return BadgeQR.render(json)
    }

    private static func randomHexId() -> String {
        var bytes = Data(count: 8)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 8, ptr.baseAddress!)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: -- Receiver

/// Accumulates frames of a single transmission. The first frame
/// determines the active transmission `id`; frames bearing a different
/// `id` are ignored (so a wallet held next to two simultaneous
/// transmissions doesn't cross-pollute).
final class LocalFrameReceiver: ObservableObject {
    @Published private(set) var totalFrames: Int = 0
    @Published private(set) var receivedFrames: Int = 0
    @Published private(set) var transmissionId: String?
    @Published private(set) var reassembled: Data?
    @Published private(set) var lastError: String?

    private var chunks: [Int: String] = [:]

    /// Try to consume a scanned QR payload as a `LocalFrameEnvelope`.
    /// Returns true when the payload was a recognised frame and has
    /// been ingested; false otherwise (caller can fall back to other
    /// payload formats — Badge, DropEnvelope, raw Presentation, etc.).
    @discardableResult
    func ingest(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let env = try? JSONDecoder().decode(LocalFrameEnvelope.self, from: data),
              env.v == LocalFrameEnvelope.version else {
            return false
        }
        if let existing = transmissionId, existing != env.id {
            return false  // ignore frames from a different transmission
        }
        if transmissionId == nil {
            transmissionId = env.id
            totalFrames = env.total
        }
        chunks[env.idx] = env.data
        receivedFrames = chunks.count
        if chunks.count == totalFrames {
            // Reassemble in index order.
            var b64 = ""
            for i in 0..<totalFrames {
                guard let chunk = chunks[i] else {
                    lastError = "Missing frame \(i)"
                    return true
                }
                b64.append(chunk)
            }
            guard let raw = Data(base64Encoded: b64) else {
                lastError = "Frame stream did not decode as base64"
                return true
            }
            reassembled = raw
        }
        return true
    }

    func reset() {
        chunks.removeAll()
        totalFrames = 0
        receivedFrames = 0
        transmissionId = nil
        reassembled = nil
        lastError = nil
    }
}
