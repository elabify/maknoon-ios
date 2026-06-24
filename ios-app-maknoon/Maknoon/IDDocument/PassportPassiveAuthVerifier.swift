// On-device ICAO 9303 Passive Authentication.
//
// Runs OFF the CoreNFC delegate thread, from persisted chip bytes, by
// re-hydrating an NFCPassportModel via its public `init(from:)` dump initializer
// and calling `verifyPassport(masterListURL:)` against a CSCA CAFile the app
// controls (see CSCATrustStore). This deliberately avoids the library's lazy
// `documentSigningCertificate` accessor on the live session, which crashes some
// chips (see IDDocumentReader.swift).
//
// This is a holder-side SOFT signal: the issuer backend re-runs Passive Auth
// authoritatively at issuance (icao9303.ts). The verdict mirrors the backend's
// reason vocabulary so the on-device result predicts the server's. Trust-store
// skew (the phone's CSCA bundle lagging the server's) yields "integrity-OK but
// CSCA not on file" (amber), never a hard reject.
//
// Only compiled with NFC support; otherwise a stub returns `.unavailable` so the
// app builds + degrades cleanly on simulator / Personal-Team.

import Foundation
#if MAKNOON_NFC
import NFCPassportReader
#endif

/// Outcome of on-device Passive Authentication. `reason` uses the same strings
/// as the backend `verifyPassiveAuthentication()` so they line up.
struct PassiveAuthResult: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case verified      // DG hashes match + SOD signed + DSC chains to a trusted CSCA
        case integrityOnly // chip data intact + SOD self-consistent, but no matching CSCA (stale bundle?)
        case failed        // tamper / bad SOD signature
        case unavailable   // could not run (no SOD, no bundle, NFC-less build)
    }
    let status: Status
    let reason: String       // "ok" or a backend-vocab reason
    let cscaCountry: String?
    let checkedAt: Date
    let bundleVersion: String?
    /// Diagnostic: which signing authority the chip's DSC points at (the CSCA
    /// subject DN the trust list must contain), set when the chain didn't build.
    /// Lets us pinpoint exactly which CSCA is missing. nil when verified.
    let dscIssuer: String?
    let dscFingerprint: String?
}

enum PassportPassiveAuthVerifier {
    /// DG file-key (how Maknoon stores them) -> NFCPassportReader dump key.
    private static let dumpKeyForGroup: [String: String] = [
        "dg1": "DG1", "dg2": "DG2", "dg11": "DG11", "dg12": "DG12", "dg15": "DG15",
    ]

    /// Re-hydrate from stored bytes and run Passive Auth. Pure + synchronous;
    /// call it from a background task (never the CoreNFC delegate thread).
    static func verify(
        sod: Data?,
        dataGroups: [String: Data],
        issuingAlpha3: String?,
        cafileURL: URL?,
        bundleVersion: String?
    ) -> PassiveAuthResult {
        let now = Date()
        func result(
            _ s: PassiveAuthResult.Status,
            _ reason: String,
            csca: String? = nil,
            dscIssuer: String? = nil,
            dscFingerprint: String? = nil
        ) -> PassiveAuthResult {
            PassiveAuthResult(
                status: s, reason: reason, cscaCountry: csca, checkedAt: now,
                bundleVersion: bundleVersion, dscIssuer: dscIssuer, dscFingerprint: dscFingerprint
            )
        }

        #if MAKNOON_NFC
        guard let sod else { return result(.unavailable, "sod_missing") }
        guard let cafileURL, FileManager.default.fileExists(atPath: cafileURL.path) else {
            return result(.unavailable, "csca_bundle_unavailable")
        }

        // Build the library's base64 dump. SOD + the captured data groups.
        var dump: [String: String] = ["SOD": sod.base64EncodedString()]
        for (group, bytes) in dataGroups {
            if let key = dumpKeyForGroup[group] { dump[key] = bytes.base64EncodedString() }
        }

        let model = NFCPassportModel(from: dump)
        // useCMSVerification: false => treat masterListURL as a concatenated-PEM
        // CAFile (what CSCATrustStore writes), the OpenSSL X509_STORE path.
        model.verifyPassport(masterListURL: cafileURL, useCMSVerification: false)

        // Map the three library booleans to a verdict. CRUCIAL distinction:
        //   - passportDataNotTampered       = DG hashes match the SOD (integrity).
        //   - documentSigningCertificateVerified = the SOD's CMS signature
        //         cryptographically verifies (expiry-INDEPENDENT on this path).
        //   - passportCorrectlySigned       = the DSC chains to a CSCA via
        //         X509_verify_cert, which ENFORCES the cert validity window.
        // So an EXPIRED but legitimate passport has intact data + a valid SOD
        // signature, but its (expired) DSC fails the chain build. That is a
        // chain/expiry condition, NOT chip forgery -> amber, never red.
        let errDetail = model.verificationErrors.first.map { String(describing: $0) } ?? ""
        let mentionsExpiry = errDetail.lowercased().contains("expired")
        // The DSC is safe to read off-session after verifyPassport (the crash is
        // only on the live CoreNFC thread). Its issuer DN names the CSCA the
        // trust list must contain -> the exact diagnostic for "CSCA not on file".
        let dscIssuer = model.documentSigningCertificate?.getIssuerName()
        let dscFingerprint = model.documentSigningCertificate?.getFingerprint()

        if !model.passportDataNotTampered {
            return result(.failed, "dg_hash_mismatch", dscIssuer: dscIssuer, dscFingerprint: dscFingerprint)
        }
        if !model.documentSigningCertificateVerified {
            return result(.failed, "sod_signature_invalid", dscIssuer: dscIssuer, dscFingerprint: dscFingerprint)
        }
        if !model.passportCorrectlySigned {
            // Authentic + properly signed, but the signer cert didn't chain to a
            // trusted, in-date CSCA: an expired document/signer, or a stale /
            // missing CSCA in the bundle. Soft-amber with a specific reason +
            // the DSC issuer so we know exactly which CSCA to source.
            return result(
                .integrityOnly,
                mentionsExpiry ? "dsc_or_chain_expired" : "no_matching_csca",
                dscIssuer: dscIssuer, dscFingerprint: dscFingerprint
            )
        }
        return result(.verified, "ok", csca: issuingAlpha3)
        #else
        return result(.unavailable, "nfc_unavailable_build")
        #endif
    }
}

extension HolderStore {
    /// Run passive authentication (the CSCA chain check) for a document and
    /// persist the result. No-op when a result already exists unless `force`.
    /// Centralised so it runs both right after import AND on a detail view's
    /// appear, so the genuineness badge is correct the first time a passport is
    /// shown (not only after opening Advanced).
    func ensurePassiveAuth(for doc: IDDocument, force: Bool = false) async {
        if !force, doc.passiveAuthResult != nil { return }
        let cscaSource = knownIssuers.hosts
            .compactMap { knownIssuers.outboundBaseURL(forEntry: $0) }
            .first
        if let cscaSource {
            await CSCATrustStore.shared.refresh(from: cscaSource, force: force)
        }
        let cafileURL = await CSCATrustStore.shared.cafileURL
        let version = await CSCATrustStore.shared.version

        let sod = idDocuments.sodBytes(for: doc)
        var dgs: [String: Data] = [:]
        for g in ["dg1", "dg2", "dg11", "dg12", "dg15"] {
            if let b = idDocuments.rawDataGroup(g, for: doc) { dgs[g] = b }
        }
        let result = PassportPassiveAuthVerifier.verify(
            sod: sod,
            dataGroups: dgs,
            issuingAlpha3: doc.issuingAuthority,
            cafileURL: cafileURL,
            bundleVersion: version
        )
        idDocuments.setPassiveAuthResult(result, for: doc.id)
    }
}
