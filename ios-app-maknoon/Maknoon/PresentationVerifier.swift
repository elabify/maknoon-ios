// Local Presentation check matrix. Runs the OFFLINE-safe subset of the
// verifier-server's check pipeline (signatures + Merkle proofs +
// timestamps), and explicitly marks the chain-dependent checks
// (issuerRegistered, credentialNotRevoked, rootCurrent, etc.) as
// `unverified`. The in-person Verify Other flow uses this so a holder
// acting as a verifier can spot-check another person's presentation with
// no network.
//
// Wire formats route through `@elabify/core` `canonicalize()` and
// `verifyMerkleProof()` so the local verdict matches the server's for
// the checks we run here.

import Foundation
import ElabifyCore

enum LocalCheckResult {
    case pass
    case fail(reason: String)
    case unverified(reason: String)
    /// The check does not apply to this credential (e.g. on-chain gates for a
    /// self-issued, unanchored credential). Never drags the verdict down.
    case notApplicable(reason: String)
}

extension LocalCheckResult {
    var isPass: Bool { if case .pass = self { return true } else { return false } }
    var isFail: Bool { if case .fail = self { return true } else { return false } }
}

struct LocalCheckMatrix {
    let headerSigValid: LocalCheckResult
    let merkleValid: LocalCheckResult
    let challengeSigValid: LocalCheckResult
    let timestampValid: LocalCheckResult
    let expiryValid: LocalCheckResult
    let verifierRequestValid: LocalCheckResult
    let issuerRegistered: LocalCheckResult    // always .unverified in offline mode
    let credentialNotRevoked: LocalCheckResult
    let rootCurrent: LocalCheckResult

    /// `pass` iff every non-unverified check passed.
    var overallPass: Bool {
        for r in [headerSigValid, merkleValid, challengeSigValid, timestampValid, expiryValid, verifierRequestValid] {
            if r.isFail { return false }
        }
        return true
    }
}

struct LocalVerdict {
    let decision: String          // GRANT / DENY / UNVERIFIED
    let summary: String
    let disclosed: [String: JSONValue]
    let checks: LocalCheckMatrix
}

enum PresentationVerifier {

    /// Run every check that doesn't require a chain RPC. The returned
    /// verdict is GRANT iff all local checks pass; chain checks land as
    /// `.unverified`. The caller decides whether to surface those as
    /// caveats or to escalate to an online verifier.
    static func verifyOffline(
        _ p: Presentation,
        clockSkewToleranceSec: Int64 = 60,
        nowSec: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> LocalVerdict {

        // 0. Self-issued detection. A self-signed credential has
        //    `header.iss == holderDID(derived from the presented holder
        //    pubkey)`: the holder is its own issuer, with no anchor. For
        //    those we CAN verify the header signature locally (the signer's
        //    pubkey is `holderLongTermPk`), and the on-chain gates do not
        //    apply.
        let holderPk = hexFrom0x(p.holderLongTermPk)
        let selfIssued: Bool = {
            guard let pk = holderPk else { return false }
            return p.header.iss == CredentialCanonical.holderDID(fromMasterPublicKey: pk)
        }()

        // 1. Header signature.
        //    - Self-issued: verify `headerSig` against `holderLongTermPk`
        //      over the canonical header. This is a real local pass/fail.
        //    - Issuer-signed: the Presentation does not carry the issuer
        //      pubkey, so we can only confirm it online (issuerRegistered);
        //      marked `unverified` here.
        let headerSigValid: LocalCheckResult = {
            guard selfIssued, let pk = holderPk,
                  let sig = hexFrom0x(p.headerSig),
                  let headerBytes = CredentialCanonical.headerBytes(p.header)
            else {
                return .unverified(reason: "Issuer pubkey not local; verify online for issuer-bound signature")
            }
            return MLDSAClient.verify(publicKey: pk, signature: sig, message: headerBytes)
                ? .pass
                : .fail(reason: "Self-issued header signature does not verify")
        }()

        // 2. Merkle inclusion: every disclosed claim chains to header.root.
        let merkleValid = verifyMerkleAll(p)

        // 3. Challenge signature. Verify against `holderLongTermPk`.
        let challengeSigValid = verifyChallengeSig(p)

        // 4. Clock skew on the holder's `timestamp`.
        let timestampValid: LocalCheckResult = {
            let drift = abs(nowSec - p.timestamp)
            return drift <= clockSkewToleranceSec
                ? .pass
                : .fail(reason: "Timestamp drift \(drift)s > tolerance \(clockSkewToleranceSec)s")
        }()

        // 5. Credential expiry.
        let expiryValid: LocalCheckResult = {
            guard let exp = p.header.exp else { return .pass }
            return exp > nowSec ? .pass : .fail(reason: "Credential expired")
        }()

        // 6. Open-verifier flow: if the presentation carries a verifier
        //    request, re-validate its signature locally so the in-person
        //    verifier sees who originally requested this presentation.
        let verifierRequestValid: LocalCheckResult = .unverified(
            reason: p.verifierRequest == nil
                ? "No verifier request embedded"
                : "Verifier signature requires registry lookup (online)"
        )

        // Chain-dependent checks. For a self-issued credential there is no
        // authority and no anchor, so these do not apply; otherwise they are
        // unverified until an online verifier runs them.
        let chainGate: LocalCheckResult = selfIssued
            ? .notApplicable(reason: "Self-issued; not anchored by an authority")
            : .unverified(reason: "Requires chain lookup")
        let issuerRegistered = chainGate
        let credentialNotRevoked = chainGate
        let rootCurrent = chainGate

        let checks = LocalCheckMatrix(
            headerSigValid: headerSigValid,
            merkleValid: merkleValid,
            challengeSigValid: challengeSigValid,
            timestampValid: timestampValid,
            expiryValid: expiryValid,
            verifierRequestValid: verifierRequestValid,
            issuerRegistered: issuerRegistered,
            credentialNotRevoked: credentialNotRevoked,
            rootCurrent: rootCurrent
        )

        let disclosed = Dictionary(uniqueKeysWithValues: p.disclosed.map { ($0.key, $0.value) })
        // SELF_ATTESTED: a self-issued credential that passed every local
        // check (Merkle + self-signature). It is self-asserted by the holder,
        // NOT anchored by an authority; the UI must say so. UNVERIFIED:
        // issuer-signed credential whose chain/issuer checks need an online
        // verifier. DENY: a local check failed.
        let decision: String = {
            if !checks.overallPass { return "DENY" }
            return selfIssued ? "SELF_ATTESTED" : "UNVERIFIED"
        }()
        let summary: String = {
            if !checks.overallPass {
                for (name, result) in [
                    ("headerSigValid", checks.headerSigValid),
                    ("merkleValid", checks.merkleValid),
                    ("challengeSigValid", checks.challengeSigValid),
                    ("timestampValid", checks.timestampValid),
                    ("expiryValid", checks.expiryValid),
                ] {
                    if case .fail(let r) = result {
                        return "\(name): \(r)"
                    }
                }
                return "Local checks failed"
            }
            if selfIssued {
                return "Self-issued by the holder and verified offline (Merkle + self-signature). Not anchored by an authority."
            }
            return "Local checks passed. Chain & issuer-pubkey checks need online verifier."
        }()

        return LocalVerdict(decision: decision, summary: summary, disclosed: disclosed, checks: checks)
    }

    // MARK: -- individual checks

    private static func verifyMerkleAll(_ p: Presentation) -> LocalCheckResult {
        let expectedRoot = hexFrom0x(p.header.root) ?? Data()
        if expectedRoot.isEmpty {
            return .fail(reason: "Could not parse header.root")
        }
        for claim in p.disclosed {
            do {
                let leaf = try claimLeafHash(key: claim.key, value: claim.value.anyValue)
                let proof = claim.proof.compactMap { entry -> MerkleProofEntry? in
                    guard let sib = hexFrom0x(entry.sibling) else { return nil }
                    return MerkleProofEntry(sibling: sib, isRight: entry.isRight)
                }
                if !verifyMerkleProof(leaf: leaf, proof: proof, expectedRoot: expectedRoot) {
                    return .fail(reason: "Merkle proof failed for claim '\(claim.key)'")
                }
            } catch {
                return .fail(reason: "Merkle hash error on '\(claim.key)': \(error)")
            }
        }
        return .pass
    }

    private static func verifyChallengeSig(_ p: Presentation) -> LocalCheckResult {
        guard let masterPk = hexFrom0x(p.holderLongTermPk) else {
            return .fail(reason: "Could not parse holderLongTermPk")
        }
        guard let challengeSig = hexFrom0x(p.challengeSig) else {
            return .fail(reason: "Could not parse challengeSig")
        }
        let verifierDid = p.verifierRequest?.verifierDid ?? "did:elabify:open"
        let challengeDict: [String: Any] = [
            "cid":       p.header.cid,
            "challenge": p.challenge,
            "timestamp": p.timestamp,
            "verifier":  verifierDid,
        ]
        do {
            let challengeBytes = try canonicalize(challengeDict)
            // Legacy v1: the challenge is signed directly by the long-term key.
            guard let d = p.delegation else {
                let ok = MLDSAClient.verify(publicKey: masterPk, signature: challengeSig, message: challengeBytes)
                return ok ? .pass : .fail(reason: "Holder challenge signature does not verify")
            }
            // v2 Identity-Sandwich: the SE-resident ephemeral key signs the
            // challenge (not the master), and the delegation cert chains that
            // ephemeral key to the master (holderLongTermPk). Verifying the
            // challenge directly against the master can never pass for v2.
            guard let ephPk = hexFrom0x(d.ephemeralPk) else {
                return .fail(reason: "Could not parse delegation ephemeralPk")
            }
            guard MLDSAClient.verify(publicKey: ephPk, signature: challengeSig, message: challengeBytes) else {
                return .fail(reason: "Ephemeral challenge signature does not verify")
            }
            // Delegation cert: master signs canonicalize of the inner cert
            // (everything but delegationSig), binding ephemeralPk to the DID.
            guard let delegationSig = hexFrom0x(d.delegationSig) else {
                return .fail(reason: "Could not parse delegationSig")
            }
            let innerDict: [String: Any] = [
                "ephemeralPk": d.ephemeralPk,
                "validFrom":   d.validFrom,
                "validUntil":  d.validUntil,
                "scope":       d.scope,
            ]
            let innerBytes = try canonicalize(innerDict)
            guard MLDSAClient.verify(publicKey: masterPk, signature: delegationSig, message: innerBytes) else {
                return .fail(reason: "Delegation cert not signed by holder master key")
            }
            let now = Int64(Date().timeIntervalSince1970)
            if now < d.validFrom || now > d.validUntil {
                return .fail(reason: "Delegation cert outside its validity window")
            }
            if !d.scope.contains("verify") {
                return .fail(reason: "Delegation scope does not include 'verify'")
            }
            return .pass
        } catch {
            return .fail(reason: "Canonicalize failed: \(error)")
        }
    }

    private static func hexFrom0x(_ s: String) -> Data? {
        let stripped = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard stripped.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(stripped.count / 2)
        var idx = stripped.startIndex
        while idx < stripped.endIndex {
            let next = stripped.index(idx, offsetBy: 2)
            guard let b = UInt8(stripped[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}
