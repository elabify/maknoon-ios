// Validates the compact codec round-trips losslessly and actually recovers the
// binary density that hex-encoding wastes — the assumption behind the ~10 kB
// NFC tap-lane payload target (ADR-0031).

import XCTest
@testable import Maknoon

final class CompactCodecTests: XCTestCase {

    /// Mirrors the size profile of a minimal sanctions-attribute presentation:
    /// issuer header sig + holder challenge sig (~3.3 kB each) + holder pubkey
    /// (~1.9 kB) + one disclosed claim. Hex fields hold HIGH-ENTROPY bytes, the
    /// realistic case (real signatures don't compress beyond the hex recovery).
    struct FakePresentation: Codable, Equatable {
        let headerSig: String
        let challengeSig: String
        let holderPk: String
        let root: String
        let claimKey: String
        let claimValue: Bool
    }

    private func randomHex(_ bytes: Int) -> String {
        let raw = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
        return "0x" + raw.map { String(format: "%02x", $0) }.joined()
    }

    func testRoundTripIsLossless() throws {
        let p = FakePresentation(
            headerSig: randomHex(3309), challengeSig: randomHex(3309),
            holderPk: randomHex(1952), root: randomHex(32),
            claimKey: "sanctionsClear", claimValue: true)
        let compact = try CompactCodec.encode(p)
        let back = try CompactCodec.decode(FakePresentation.self, from: compact)
        XCTAssertEqual(back, p)
    }

    func testRecoversBinaryDensityAndFitsTap() throws {
        let p = FakePresentation(
            headerSig: randomHex(3309), challengeSig: randomHex(3309),
            holderPk: randomHex(1952), root: randomHex(32),
            claimKey: "sanctionsClear", claimValue: true)
        let jsonSize = try JSONEncoder().encode(p).count       // ~17 kB (hex doubled)
        let compactSize = try CompactCodec.encode(p).count     // ~9 kB

        // High-entropy hex deflates ~2x; assert a real reduction, not a fluke.
        XCTAssertLessThan(compactSize, jsonSize * 6 / 10)
        // The tap-lane budget: a single-attribute presentation should land well
        // under ~12 kB so it moves over ISO-DEP in ~1-2 s.
        XCTAssertLessThan(compactSize, 12_000)
    }
}
