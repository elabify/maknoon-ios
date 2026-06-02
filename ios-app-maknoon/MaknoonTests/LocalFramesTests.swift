// Round-trip tests for the multi-frame QR transport: chunks() -> a
// LocalFrameReceiver -> the original bytes. The wire format is the
// uncompressed `elabify-frames-1` envelope shared with the React verifier.

import XCTest
@testable import Maknoon

final class LocalFramesTests: XCTestCase {

    private func roundTrip(_ source: Data) -> Data? {
        let frames = LocalFrames.chunks(of: source)
        let rx = LocalFrameReceiver()
        // Feed frames out of order to exercise index-keyed reassembly.
        for f in frames.shuffled() {
            let json = try! JSONEncoder().encode(f)
            _ = rx.ingest(String(data: json, encoding: .utf8)!)
        }
        return rx.reassembled
    }

    func testRoundTripReassembles() {
        let source = Data((0..<5000).map { UInt8($0 % 251) })
        XCTAssertEqual(roundTrip(source), source)
    }

    func testFrameCountMatchesUncompressedBase64() {
        // The wire format is uncompressed base64 split into 750-byte chunks.
        // Frame count must match that arithmetic exactly so it stays in
        // lockstep with the React verifier's decoder.
        let source = Data((0..<5000).map { UInt8($0 % 251) })
        let frames = LocalFrames.chunks(of: source)
        let expected = (source.base64EncodedString().count + 749) / 750
        XCTAssertEqual(frames.count, expected)
        XCTAssertEqual(frames.first?.v, "elabify-frames-1")
        XCTAssertEqual(roundTrip(source), source)
    }

    func testEmptySourceRoundTrips() {
        XCTAssertEqual(roundTrip(Data()), Data())
    }

    func testForeignTransmissionIdIgnored() {
        let a = LocalFrames.chunks(of: Data("transmission A payload".utf8))
        let b = LocalFrames.chunks(of: Data("transmission B payload".utf8))
        let rx = LocalFrameReceiver()
        // First A frame fixes the transmission id; B frames must be ignored.
        _ = rx.ingest(String(data: try! JSONEncoder().encode(a[0]), encoding: .utf8)!)
        for f in b {
            let accepted = rx.ingest(String(data: try! JSONEncoder().encode(f), encoding: .utf8)!)
            XCTAssertFalse(accepted, "frames from a different transmission id must be ignored")
        }
    }
}
