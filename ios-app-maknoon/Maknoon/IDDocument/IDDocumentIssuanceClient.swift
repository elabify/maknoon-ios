// HTTP client for Maknoon's verified-identity credential issuance.
//
// Wire format follows ADR-0026 holder-initiated attestation:
//   - The holder constructs an AttestationPacket envelope with a
//     freshly-generated 16-byte packetId, signs the packetId bytes
//     with the master ML-DSA-65 key, and POSTs to the issuer.
//   - Server pre-verifies the proof (Passive Authentication: SOD →
//     CSCA chain → DG hash table; Active Authentication if captured;
//     holder ML-DSA signature over packetId; App Attest if present).
//   - If pre-verification passes, the packet is queued for operator
//     review (or, in the hybrid auto-mint mode landed in M2 proper,
//     auto-approved). Either path returns a pendingId; the credential
//     becomes available through the standard pickup flow once it's
//     anchored.
//
// Endpoint: POST {issuer}/v1/passport-attestation/submit-packet.
//
// The issuer-side endpoint is being built alongside this client; the
// shape here matches the server's expected AttestationPacket schema so
// the two land integrated.

import Foundation

enum IDDocumentIssuanceError: LocalizedError {
    case missingChipMaterial
    case identityNotLoaded
    case mldsaSignFailed(String)
    case submitFailed(String)
    case malformedResponse(String)
    case issuerDidLookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingChipMaterial:
            return "This document is missing the chip-signed objects needed for issuance. Re-tap the document so Maknoon can capture them."
        case .identityNotLoaded:
            return "Maknoon is locked. Unlock first."
        case .mldsaSignFailed(let m):
            return "Couldn't sign the issuance request: \(m)"
        case .submitFailed(let m):
            return "Issuer rejected the request: \(m)"
        case .malformedResponse(let m):
            return "Unexpected response from issuer: \(m)"
        case .issuerDidLookupFailed(let m):
            return "Couldn't reach the issuer to learn its DID: \(m)"
        }
    }
}

/// Shape of GET /v1/issuer/info, we read just enough to pin the
/// packet to the issuer's actual DID. The endpoint returns more
/// fields (mlDsaPubkey, schemas, anchorManifest, etc.); we ignore
/// them here.
private struct IssuerInfoResponse: Codable {
    let did: String
}

/// What the issuer returns after accepting (or queueing) a submitted
/// packet. Matches the existing ADR-0026 SubmitPacketResponse shape on
/// the issuer-backend so the two endpoints stay symmetric.
struct AttestationSubmitAck: Codable, Sendable {
    let v: Int
    let pendingId: String
    /// `pending_review`, `approved`, or `rejected`. With auto-mint
    /// enabled server-side, pre-verified passport packets come back
    /// as `approved` along with `pickupUrl` and `credentialId` set;
    /// the holder polls the URL and imports the credential. Without
    /// auto-mint, pickup waits for an operator approve.
    let status: String
    let proofPreVerified: Bool
    let proofPreVerifiedReason: String
    /// Set when the issuer auto-approved on submit. The holder polls
    /// this URL to fetch the anchored credential.
    let pickupUrl: String?
    /// Issuer-side credential id for the auto-minted credential; lets
    /// the UI show a "minted" state before the anchor completes.
    let credentialId: String?
    /// Operator hint: the next scheduled batch flush, after which the
    /// credential becomes fetchable through `pickupUrl`.
    let estimatedAnchorAt: Int64?
}

/// AttestationPacket envelope (ADR-0026). The proof block is
/// packet-type specific; for passports it carries the chip blobs +
/// MRZ-derived fields + Active Authentication challenge/response.
private struct AttestationPacket: Codable {
    let v: Int
    let packetId: String
    let packetType: String
    let issuerDid: String
    let holderDid: String
    let generatedAt: Int64
    let proof: PassportProof
    let appAttest: AppAttestBlock?

    struct AppAttestBlock: Codable {
        let keyId: String
        let assertion: String
        let clientDataHashHex: String
        let enrollment: AppAttestEnrollment?
    }
}

private struct PassportProof: Codable {
    let kind: String          // "icao9303-passport"
    let holderMasterPkHex: String
    /// ML-DSA-65 signature over the raw packetId bytes. Proves the
    /// submitter controls the holder master key at submission time
    /// (replay defence: packetId is fresh per submission).
    let holderSigHex: String
    let fields: Fields
    let sodHex: String
    let dataGroupsHex: DataGroupsHex
    let activeAuth: ActiveAuthBlock?

    struct Fields: Codable {
        let documentNumber: String
        /// Library-reported surname (may be native-script for CHN/JPN
        /// passports because the library prefers DG11.fullName when
        /// present). The issuer uses `latinSurname` for the credential
        /// claim; this field is kept for completeness.
        let surname: String
        let givenNames: String
        let latinSurname: String?
        let latinGivenNames: String?
        let nativeFullName: String?
        let nationality: String
        let issuingAuthority: String
        let sex: String?
        let dateOfBirth: String
        let dateOfExpiry: String
        let documentType: String
        let personalNumber: String?
        let placeOfBirth: String?
    }

    struct DataGroupsHex: Codable {
        let dg1: String?
        let dg2: String?
        let dg11: String?
        let dg12: String?
        let dg15: String?
    }

    struct ActiveAuthBlock: Codable {
        let challengeHex: String
        let signatureHex: String
        let verifiedLocally: Bool
    }
}

enum IDDocumentIssuanceClient {

    /// Default issuer endpoint. Configurable in Settings → Identity
    /// → Known issuers if a private issuer needs to be used.
    static let defaultIssuerBaseURL = "https://musnad-issuer.elabify.com"

    /// Default issuer DID the holder is enrolling with. Used as the
    /// `issuerDid` field of the packet envelope. The server validates
    /// that the packet's issuerDid matches its own configured DID.
    static let defaultIssuerDid = "did:elabify:sepolia:musnad:0x0000000000000000000000000000000000000001"

    /// App Attest helper. Bounces onto MainActor (where the
    /// MaknoonAppAttest singleton lives) to fetch the enrollment +
    /// assertion. Returns nil on simulator / unsupported devices.
    @MainActor
    private static func runAppAttest(
        requestBody: Data,
        clientDataChallenge: Data
    ) async -> AttestationPacket.AppAttestBlock? {
        let appAttest = MaknoonAppAttest.shared
        guard appAttest.isSupported else { return nil }
        do {
            var enrollment: AppAttestEnrollment? = nil
            if appAttest.existingKeyId == nil {
                enrollment = try await appAttest.generateAndAttestKey(
                    issuerChallenge: clientDataChallenge
                )
            }
            let assertion = try await appAttest.assert(over: requestBody)
            return .init(
                keyId: assertion.keyId,
                assertion: assertion.assertion,
                clientDataHashHex: assertion.clientDataHash,
                enrollment: enrollment
            )
        } catch {
            LogStore.shared.warn("identity.issuance",
                "App Attest failed: \(error.localizedDescription). Submitting without attestation.")
            return nil
        }
    }

    /// Build and submit a passport attestation packet. Returns the
    /// issuer's ack containing the pendingId.
    @MainActor
    static func submit(
        document: IDDocument,
        store: HolderStore,
        issuerBaseURL: String? = nil,
        issuerDid: String? = nil
    ) async throws -> AttestationSubmitAck {

        // 1. Sanity: SOD is the minimum chip material the issuer needs.
        guard let sodBytes = store.idDocuments.sodBytes(for: document),
              !sodBytes.isEmpty
        else { throw IDDocumentIssuanceError.missingChipMaterial }

        // 2. Identity material.
        guard let sandwich = store.sandwich,
              let masterPk = store.holderPublicKey
        else { throw IDDocumentIssuanceError.identityNotLoaded }
        let holderDid = sandwich.holderDID

        // 2b. Resolve the issuer's DID. Each deployment configures its
        // own ELABIFY_ISSUER_DID, and the canonical place to learn it
        // is GET /v1/issuer/info on the issuer itself. Fetching it
        // dynamically means switching between local-dev, sepolia, and
        // production issuers in the picker Just Works without having
        // to type DIDs by hand.
        let baseURL = (issuerBaseURL ?? defaultIssuerBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedIssuerDid: String
        if let override = issuerDid {
            resolvedIssuerDid = override
        } else {
            resolvedIssuerDid = try await fetchIssuerDid(baseURL: baseURL)
        }

        // 3. Fresh packetId. 16 bytes, hex-encoded with 0x prefix to
        //    match the issuer-backend's PACKET_ID_RE.
        var packetIdRandom = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, packetIdRandom.count, &packetIdRandom)
        guard status == errSecSuccess else {
            throw IDDocumentIssuanceError.mldsaSignFailed("SecRandomCopyBytes returned \(status)")
        }
        let packetIdBytes = Data(packetIdRandom)
        let packetId = "0x" + packetIdBytes.map { String(format: "%02x", $0) }.joined()

        // 4. Holder ML-DSA-65 signature over the packetId bytes.
        // Issuance is a deliberate, high-trust operation so we sign
        // with the master key (Face ID / passcode prompt + hardware
        // second factor when enrolled). The fast-path ephemeral key
        // would be wrong here: the server verifies the signature
        // against `holderMasterPkHex`, which is the master pubkey.
        let holderSig: Data
        do {
            holderSig = try sandwich.signWithMaster(
                packetIdBytes,
                localizedReason: "Authorize identity credential issuance"
            )
        } catch {
            throw IDDocumentIssuanceError.mldsaSignFailed(error.localizedDescription)
        }

        // 5. Bundle the chip blobs as hex.
        let dataGroups = PassportProof.DataGroupsHex(
            dg1:  store.idDocuments.rawDataGroup("dg1",  for: document)?.toHex(),
            dg2:  store.idDocuments.rawDataGroup("dg2",  for: document)?.toHex(),
            dg11: store.idDocuments.rawDataGroup("dg11", for: document)?.toHex(),
            dg12: store.idDocuments.rawDataGroup("dg12", for: document)?.toHex(),
            dg15: store.idDocuments.rawDataGroup("dg15", for: document)?.toHex()
        )
        let activeAuth: PassportProof.ActiveAuthBlock? = {
            guard let challenge = document.activeAuthChallengeHex,
                  let signature = document.activeAuthSignatureHex
            else { return nil }
            return .init(
                challengeHex: challenge,
                signatureHex: signature,
                verifiedLocally: document.activeAuthVerifiedLocally ?? false
            )
        }()

        let proof = PassportProof(
            kind: "icao9303-passport",
            holderMasterPkHex: masterPk.map { String(format: "%02x", $0) }.joined(),
            holderSigHex: holderSig.map { String(format: "%02x", $0) }.joined(),
            fields: .init(
                documentNumber: document.documentNumber,
                surname: document.surname,
                givenNames: document.givenNames,
                latinSurname: document.latinSurname,
                latinGivenNames: document.latinGivenNames,
                nativeFullName: document.nativeFullName,
                nationality: document.nationality,
                issuingAuthority: document.issuingAuthority,
                sex: document.sex,
                dateOfBirth: document.dateOfBirth,
                dateOfExpiry: document.dateOfExpiry,
                documentType: document.documentType,
                personalNumber: document.personalNumber,
                placeOfBirth: document.placeOfBirth
            ),
            sodHex: sodBytes.toHex(),
            dataGroupsHex: dataGroups,
            activeAuth: activeAuth
        )

        var packet = AttestationPacket(
            v: 1,
            packetId: packetId,
            packetType: "icao9303-passport",
            issuerDid: resolvedIssuerDid,
            holderDid: holderDid,
            generatedAt: Int64(Date().timeIntervalSince1970),
            proof: proof,
            appAttest: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bodyData = try encoder.encode(packet)

        // 6. App Attest. The clientData challenge is the packetId
        //    bytes so the attestation binds to this submission.
        if let block = await runAppAttest(requestBody: bodyData, clientDataChallenge: packetIdBytes) {
            packet = AttestationPacket(
                v: packet.v,
                packetId: packet.packetId,
                packetType: packet.packetType,
                issuerDid: packet.issuerDid,
                holderDid: packet.holderDid,
                generatedAt: packet.generatedAt,
                proof: packet.proof,
                appAttest: block
            )
            bodyData = try encoder.encode(packet)
        }

        // 7. POST.
        guard let submitURL = URL(string: "\(baseURL)/v1/passport-attestation/submit-packet") else {
            throw IDDocumentIssuanceError.submitFailed("Bad base URL")
        }
        var req = URLRequest(url: submitURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData
        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw IDDocumentIssuanceError.submitFailed("no response")
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw IDDocumentIssuanceError.submitFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        do {
            return try JSONDecoder().decode(AttestationSubmitAck.self, from: respData)
        } catch {
            throw IDDocumentIssuanceError.malformedResponse(error.localizedDescription)
        }
    }

    /// Look up the issuer's DID via GET {base}/v1/issuer/info. The
    /// response carries other fields (mlDsaPubkey, anchorManifest,
    /// schemas, etc.); we only need the DID here. A separate
    /// long-lived integration could cache this, but for the demo the
    /// extra request per submission is fine.
    private static func fetchIssuerDid(baseURL: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/issuer/info") else {
            throw IDDocumentIssuanceError.issuerDidLookupFailed("bad base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw IDDocumentIssuanceError.issuerDidLookupFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw IDDocumentIssuanceError.issuerDidLookupFailed("no response")
        }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw IDDocumentIssuanceError.issuerDidLookupFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        do {
            let info = try JSONDecoder().decode(IssuerInfoResponse.self, from: data)
            return info.did
        } catch {
            throw IDDocumentIssuanceError.issuerDidLookupFailed("bad info JSON: \(error.localizedDescription)")
        }
    }
}

private extension Data {
    func toHex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
