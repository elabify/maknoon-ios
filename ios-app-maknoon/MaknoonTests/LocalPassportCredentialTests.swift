// Round-trip tests for the self-signed local passport credential:
// LocalCredentialFactory.buildCredential -> Presentation -> verifyOffline.
// Exercises the real app code path (the pure builder + the offline verifier)
// without an IdentitySandwich, by signing with a raw ML-DSA seed.

import XCTest
import ElabifyCore
@testable import Maknoon

final class LocalPassportCredentialTests: XCTestCase {

    private let claims: [(key: String, value: Any)] = [
        ("givenName", "JANE"),
        ("familyName", "DOE"),
        ("nationality", "USA"),
        ("dateOfBirth", "900101"),
        ("documentNumber", "X1234567"),
    ]

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Build a full self-signed Presentation from a fresh master key, then run
    /// the offline verifier. Returns (presentation, masterSeed) so callers can
    /// tamper and re-check.
    private func makeSelfPresentation(
        timestamp: Int64 = 1_700_000_000
    ) throws -> (Presentation, holderPkHex: String) {
        let (masterPk, seed) = try MLDSAClient.generateMaster()
        let holderDID = CredentialCanonical.holderDID(fromMasterPublicKey: masterPk)

        let credential = try LocalCredentialFactory.buildCredential(
            claims: claims,
            holderDID: holderDID,
            schema: passportSchemaURI,
            iat: timestamp,
            exp: nil,
            signHeader: { try MLDSAClient.signWithMaster(seed: seed, message: $0) }
        )

        // Disclose every claim with a freshly recomputed Merkle proof, exactly
        // as the presentation pipeline does (rebuild the tree from claims).
        var claimMap: [String: Any] = [:]
        for c in claims { claimMap[c.key] = c.value }
        let sortedKeys = sortClaimKeys(claimMap)
        let tree = try MerkleTree(entries: sortedKeys.map { ($0, claimMap[$0]!) })
        let disclosed: [DisclosedClaim] = sortedKeys.enumerated().map { idx, key in
            let proof = tree.proof(at: idx).map {
                ProofEntry(sibling: "0x" + hex($0.sibling), isRight: $0.isRight)
            }
            return DisclosedClaim(key: key, value: .string(claimMap[key] as! String), leafIndex: idx, proof: proof)
        }

        let challenge = "0x" + String(repeating: "ab", count: 16)
        let holderPkHex = "0x" + hex(masterPk)
        let challengeMsg: [String: Any] = [
            "cid": credential.header.cid,
            "challenge": challenge,
            "timestamp": timestamp,
            "verifier": "did:elabify:open",
        ]
        let challengeSig = try MLDSAClient.signWithMaster(
            seed: seed, message: try canonicalize(challengeMsg)
        )

        let p = Presentation(
            v: 2,
            header: credential.header,
            headerSig: credential.headerSig,
            challenge: challenge,
            challengeSig: "0x" + hex(challengeSig),
            disclosed: disclosed,
            timestamp: timestamp,
            holderLongTermPk: holderPkHex,
            anchor: nil
        )
        return (p, holderPkHex)
    }

    func testSelfIssuedRoundTripVerifiesOffline() throws {
        let (p, _) = try makeSelfPresentation()
        let v = PresentationVerifier.verifyOffline(p, nowSec: p.timestamp)

        XCTAssertEqual(v.decision, "SELF_ATTESTED", v.summary)
        XCTAssertTrue(v.checks.headerSigValid.isPass, "self-issued header signature should verify")
        XCTAssertTrue(v.checks.merkleValid.isPass)
        XCTAssertTrue(v.checks.challengeSigValid.isPass)
        // On-chain gates do not apply to a self-issued credential.
        if case .notApplicable = v.checks.issuerRegistered {} else {
            XCTFail("issuerRegistered should be notApplicable for self-issued")
        }
        XCTAssertEqual(v.disclosed["givenName"]?.displayText, "JANE")
    }

    func testTamperedClaimFailsMerkle() throws {
        let (p, holderPkHex) = try makeSelfPresentation()
        // Flip a disclosed claim value without touching the root/proof.
        let tampered = p.disclosed.map { d -> DisclosedClaim in
            d.key == "nationality"
                ? DisclosedClaim(key: d.key, value: .string("CAN"), leafIndex: d.leafIndex, proof: d.proof)
                : d
        }
        let bad = Presentation(
            v: p.v, header: p.header, headerSig: p.headerSig, challenge: p.challenge,
            challengeSig: p.challengeSig, disclosed: tampered, timestamp: p.timestamp,
            holderLongTermPk: holderPkHex, anchor: nil
        )
        let v = PresentationVerifier.verifyOffline(bad, nowSec: bad.timestamp)
        XCTAssertEqual(v.decision, "DENY")
        XCTAssertTrue(v.checks.merkleValid.isFail)
    }

    func testForeignHeaderSigDoesNotVerify() throws {
        // A credential whose holderLongTermPk does not match header.iss must
        // not be treated as a valid self-issued credential.
        let (p, _) = try makeSelfPresentation()
        let (otherPk, _) = try MLDSAClient.generateMaster()
        let mismatched = Presentation(
            v: p.v, header: p.header, headerSig: p.headerSig, challenge: p.challenge,
            challengeSig: p.challengeSig, disclosed: p.disclosed, timestamp: p.timestamp,
            holderLongTermPk: "0x" + hex(otherPk), anchor: nil
        )
        let v = PresentationVerifier.verifyOffline(mismatched, nowSec: mismatched.timestamp)
        // iss no longer matches the presented pubkey -> not self-issued ->
        // headerSig is unverified (not a local pass) and challenge sig fails.
        XCTAssertNotEqual(v.decision, "SELF_ATTESTED")
    }
}
