// Single source of truth for building a signed `Presentation`.
//
// Extracted verbatim from PresentView.build() so the interactive present
// screen and the mini-app identity bridge sign presentations through the
// exact same path. Duplicating this logic risks the two surfaces drifting
// on canonicalization / Merkle proofs / signature shape, which is exactly
// the class of bug that is invisible until a verifier rejects a proof.
//
// The caller decides where the `challenge` comes from:
//   * interactive scan of a VerifierRequest  -> request.challenge + its DID
//   * open self-presentation                 -> a fresh self nonce + did:elabify:open
//   * server-issued challenge (mini-app POS)  -> /v1/challenge value + did:elabify:open
// and passes the matching `verifierDid` used in the signed challenge
// message. `pendingRequest`, when present, is echoed into the presentation
// so a verifier can confirm it is answering its own request.

import Foundation
import ElabifyCore

enum PresentationFactory {

    /// Build and sign a v2 Presentation disclosing `selectedClaims` from
    /// `credential`, binding it to `challenge` (signed together with
    /// `verifierDid`). Requires the Identity Sandwich to be unlocked
    /// (`store.holderPublicKey` / `store.signWithIdentity`).
    @MainActor
    static func build(
        credential: Credential,
        selectedClaims: Set<String>,
        challenge: HexString,
        verifierDid: String,
        pendingRequest: VerifierRequest?,
        store: HolderStore
    ) async throws -> Presentation {
        guard let holderPK = store.holderPublicKey else {
            throw SandwichError.masterUnavailable
        }
        let now = Int64(Date().timeIntervalSince1970)

        let challengeMsgDict: [String: Any] = [
            "cid":       credential.header.cid,
            "challenge": challenge,
            "timestamp": now,
            "verifier":  verifierDid,
        ]
        let msgBytes = try canonicalize(challengeMsgDict)
        let challengeSig = try store.signWithIdentity(msgBytes)

        let entries: [(key: String, value: Any)] = credential.merkleTree.sortedKeys.map { key in
            (key: key, value: credential.claims[key]?.anyValue ?? NSNull())
        }
        let tree = try MerkleTree(entries: entries)

        let requested = Array(selectedClaims).sorted()
        var disclosed: [DisclosedClaim] = []
        for key in requested {
            guard let idx = credential.merkleTree.sortedKeys.firstIndex(of: key),
                  let value = credential.claims[key] else { continue }
            let proof = tree.proof(at: idx).map { entry -> ProofEntry in
                ProofEntry(sibling: "0x" + bytesToHex(entry.sibling), isRight: entry.isRight)
            }
            disclosed.append(DisclosedClaim(
                key: key,
                value: value,
                leafIndex: idx,
                proof: proof
            ))
        }

        // Embed the Identity-Sandwich delegation cert so the verifier's
        // `delegationValid` check can run.
        let delegation: PresentationDelegation? = store.currentDelegation.map { cert in
            PresentationDelegation(
                ephemeralPk: cert.ephemeralPk,
                validFrom: cert.validFrom,
                validUntil: cert.validUntil,
                scope: cert.scope,
                delegationSig: cert.delegationSig
            )
        }

        // Optional hardware attestation, when a device is paired.
        let hardwareAttestation = HardwareWalletManager.loadAttestation()

        // Self-issuer App Attest binding for locally-minted credentials.
        let holderPkHex = "0x" + bytesToHex(holderPK)
        var selfAttestation: SelfIssuerAttestation? = nil
        if credential.header.iss == store.sandwich?.holderDID,
           let binding = CredentialCanonical.appAttestBindingBytes(
               cid: credential.header.cid, root: credential.header.root,
               holderPkHex: holderPkHex, schema: credential.header.schema) {
            selfAttestation = await MaknoonAppAttest.shared.selfIssuerAttestation(
                holderDID: credential.header.iss, bindingBytes: binding)
        }

        return Presentation(
            v: 2,
            header: credential.header,
            headerSig: credential.headerSig,
            challenge: challenge,
            challengeSig: "0x" + bytesToHex(challengeSig),
            disclosed: disclosed,
            timestamp: now,
            holderLongTermPk: holderPkHex,
            anchor: credential.anchor,
            verifierRequest: pendingRequest,
            delegation: delegation,
            hardwareAttestation: hardwareAttestation,
            selfIssuerAttestation: selfAttestation
        )
    }

    /// 32-byte random nonce (hex, no 0x) for open self-presentations.
    static func selfNonceHex() -> String {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytesToHex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
