import XCTest
@testable import Maknoon

// Locks the on-chain credential verdict composition: fullyVerified is true only
// when the three chain gates (issuerRegistered, notRevoked, rootCurrent) AND
// the on-chain header signature all pass. Any fail or unknown (e.g. RPC
// unreachable) must drop it to false. Mirrors Android OnChainVerdictTest.
final class OnChainVerdictTests: XCTestCase {

    private func verdict(
        issuer: OnChainTier = .pass,
        revoked notRevoked: OnChainTier = .pass,
        root: OnChainTier = .pass,
        header: OnChainTier = .pass,
        csca: OnChainTier? = nil
    ) -> OnChainVerdict {
        OnChainVerdict(
            reachedChain: true,
            issuerRegistered: issuer,
            notRevoked: notRevoked,
            rootCurrent: root,
            headerSigValid: header,
            cscaProvenance: csca)
    }

    func testAllGatesPassIsFullyVerified() {
        XCTAssertTrue(verdict().fullyVerified)
        // cscaProvenance does not affect the core verdict.
        XCTAssertTrue(verdict(csca: .fail("bad")).fullyVerified)
    }

    func testAnyFailBreaksVerification() {
        XCTAssertFalse(verdict(issuer: .fail("not registered")).fullyVerified)
        XCTAssertFalse(verdict(revoked: .fail("revoked")).fullyVerified)
        XCTAssertFalse(verdict(root: .fail("stale root")).fullyVerified)
        XCTAssertFalse(verdict(header: .fail("bad sig")).fullyVerified)
    }

    func testAnyUnknownBreaksVerification() {
        XCTAssertFalse(verdict(issuer: .unknown("rpc")).fullyVerified)
        XCTAssertFalse(verdict(header: .unknown("key not published")).fullyVerified)
    }

    func testUnreachableDegradesToUnverified() {
        let v = OnChainVerdict.unreachable("RPC unreachable")
        XCTAssertFalse(v.reachedChain)
        XCTAssertFalse(v.fullyVerified)
    }
}
