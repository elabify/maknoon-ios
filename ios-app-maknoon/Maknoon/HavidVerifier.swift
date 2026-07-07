// Client-side HAVID cross-endorsement (ADR-0051, completed under ADR-0054).
//
// HAVID binds an issuer's real-world X.509 organisational identity to its DID,
// bidirectionally, and the holder can confirm it with NO chain read and NO
// verifier server, purely over local HTTPS + crypto:
//
//   DID  -> cert : the issuer's .well-known doc carries the cert chain (havid.x5c)
//                  and is ML-DSA self-signed by the issuer key. We reconfirm that
//                  key by checking it ALSO signed the credential being presented
//                  (the same bind IssuerIdentityResolver uses), so the endorsing
//                  key provably is the issuer's, not some MITM key.
//   cert -> DID : the leaf certificate's subjectAltName carries URI:<issuerDid>.
//
// Both directions holding => cross-endorsed. This is an ISSUER-assurance badge,
// never a credential gate (a missing / weak binding never turns a GRANT into a
// DENY); it answers "did this come from a verifiable real-world organisation?",
// which is distinct from the passport<->CSCA document link (ADR-0050, surfaced
// separately as the on-chain CSCA provenance tier).
//
// SCOPE (research-quality, matching the verifier-server minus trusted-root
// anchoring): iOS ships no swift-certificates (an SPM build issue, see
// project.yml), so the leaf is parsed with a minimal DER walk that extracts the
// SAN URIs, validity window, and subject CN. We do NOT bundle CA roots, so the
// client caps at "cross-endorsed" and never claims the server's "full_havid"
// (chain-anchored-to-a-trusted-root) tier. No CRL/OCSP, no full RFC 5280 path
// build. certFingerprintSha256 integrity is checked; validity window is enforced.

import Foundation
import CryptoKit
import ElabifyCore

/// HAVID assurance state, holder-side. Mirrors verifier-server/src/havid.ts but
/// caps at `crossEndorsed` (no bundled trusted roots on the client).
enum HavidState: Sendable, Equatable {
    /// Bidirectional cross-endorsement holds and the leaf is within validity.
    case crossEndorsed
    /// Leaf SAN does not carry the issuer DID (cert does not endorse the DID).
    case keyAlignmentFailure
    /// Cert cannot be parsed, or its fingerprint disagrees with the advertised one.
    case integrityFailure
    /// Leaf certificate is outside its validity window.
    case expiredRevoked
    /// The issuer publishes a well-known doc but no HAVID binding.
    case noEndorsement
    /// The issuer's well-known doc could not be reached / did not bind to this
    /// credential (offline, unknown host, or key mismatch). Not a failure of the
    /// binding itself, so shown as "unknown", never red.
    case notResolvable
}

struct HavidResult: Sendable, Equatable {
    var state: HavidState
    var detail: String?
    /// Leaf certificate subject (common name), when parsed, for display.
    var subject: String?
}

struct HavidVerifier {
    /// Resolve + validate the issuer's HAVID binding for a presented credential.
    /// `candidateBaseURLs` are the known-issuer hosts to probe for the signed
    /// well-known doc (same source as IssuerIdentityResolver).
    func verify(header: CredentialHeader, headerSig: String, candidateBaseURLs: [URL]) async -> HavidResult {
        guard let headerBytes = Self.canonicalHeaderBytes(header),
              let sigData = Self.hexData(headerSig) else {
            return HavidResult(state: .notResolvable, detail: "Malformed credential header")
        }
        // DID -> cert binding: the doc key must ALSO have signed this credential's
        // header. Proves the endorsing key is the key that signed the credential.
        return await resolve(did: header.iss, candidateBaseURLs: candidateBaseURLs) { doc in
            MLDSAClient.verify(publicKey: doc.pubkey, signature: sigData, message: headerBytes)
        }
    }

    /// HAVID for a credential REFERENCE (a badge) that carries no headerSig. The
    /// DID -> cert binding is instead the doc key equalling the issuer's ON-CHAIN
    /// registered key (`issuerPubkey`, from OnChainVerifier.verifyReference). When
    /// no on-chain key is available the check falls back to the doc self-signature
    /// only (weaker, still confirms the SAN cross-endorsement).
    func verifyReference(did: String, candidateBaseURLs: [URL], issuerPubkey: Data?) async -> HavidResult {
        return await resolve(did: did, candidateBaseURLs: candidateBaseURLs) { doc in
            guard let expected = issuerPubkey, !expected.isEmpty else { return true }
            return doc.pubkey == expected
        }
    }

    /// Fetch + verify the issuer doc (self-signature + the caller's `bind` check),
    /// then evaluate the X.509 cross-endorsement.
    private func resolve(did: String, candidateBaseURLs: [URL], bind: (FetchedDoc) -> Bool) async -> HavidResult {
        var sawIssuerDoc = false
        for base in candidateBaseURLs {
            guard let doc = await Self.fetchDoc(base: base), doc.did == did else { continue }
            var unsigned = doc.full
            unsigned.removeValue(forKey: "signature")
            guard let docBytes = try? ElabifyCore.canonicalize(unsigned),
                  MLDSAClient.verify(publicKey: doc.pubkey, signature: doc.signature, message: docBytes),
                  bind(doc)
            else { continue } // a host serving a non-binding doc for this DID: skip
            sawIssuerDoc = true
            return Self.evaluateCert(doc: doc, did: did)
        }
        return HavidResult(
            state: .notResolvable,
            detail: sawIssuerDoc
                ? "Issuer identity did not bind to this credential"
                : "Could not reach the issuer's published identity"
        )
    }

    /// The cert -> DID direction: fingerprint integrity, SAN carries the DID, and
    /// the validity window. Assumes the DID -> cert direction already held.
    private static func evaluateCert(doc: FetchedDoc, did: String) -> HavidResult {
        guard let havid = doc.havid, let leafB64 = havid.x5c.first,
              let leafDER = Data(base64Encoded: leafB64) else {
            return HavidResult(state: .noEndorsement,
                               detail: "Issuer publishes no X.509 cross-endorsement")
        }
        let fp = SHA256.hash(data: leafDER).map { String(format: "%02x", $0) }.joined()
        if fp != havid.certFingerprintSha256.lowercased() {
            return HavidResult(state: .integrityFailure, detail: "Leaf certificate fingerprint mismatch")
        }
        guard let cert = MinimalX509(der: leafDER) else {
            return HavidResult(state: .integrityFailure, detail: "Leaf certificate could not be parsed")
        }
        if !cert.sanURIs.contains(did) {
            return HavidResult(state: .keyAlignmentFailure,
                               detail: "Certificate SAN does not carry \(did)",
                               subject: cert.subjectCN)
        }
        if let (notBefore, notAfter) = cert.validity {
            let now = Date()
            if now < notBefore || now > notAfter {
                return HavidResult(state: .expiredRevoked,
                                   detail: "Certificate is outside its validity window",
                                   subject: cert.subjectCN)
            }
        }
        return HavidResult(state: .crossEndorsed, subject: cert.subjectCN)
    }

    // MARK: - well-known doc fetch (mirrors IssuerIdentityResolver)

    private struct FetchedDoc {
        let full: [String: Any]
        let did: String
        let pubkey: Data
        let signature: Data
        let havid: HavidBlock?
    }

    private struct HavidBlock {
        let x5c: [String]
        let certFingerprintSha256: String
    }

    private static func fetchDoc(base: URL) async -> FetchedDoc? {
        guard let url = URL(string: base.absoluteString + "/v1/issuer/well-known-doc") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let did = dict["did"] as? String,
              let pkHex = dict["mlDsaPubkey"] as? String, let pubkey = hexData(pkHex),
              let sigHex = dict["signature"] as? String, let signature = hexData(sigHex)
        else { return nil }
        var havid: HavidBlock?
        if let h = dict["havid"] as? [String: Any],
           let x5c = h["x5c"] as? [String],
           let fp = h["certFingerprintSha256"] as? String {
            havid = HavidBlock(x5c: x5c, certFingerprintSha256: fp)
        }
        return FetchedDoc(full: dict, did: did, pubkey: pubkey, signature: signature, havid: havid)
    }

    private static func canonicalHeaderBytes(_ header: CredentialHeader) -> Data? {
        guard let raw = try? JSONEncoder().encode(header),
              let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        return try? ElabifyCore.canonicalize(dict)
    }

    private static func hexData(_ hex: String) -> Data? {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}

/// A deliberately small X.509 DER reader: it extracts only what HAVID needs from
/// a leaf certificate (SAN URIs, validity window, subject CN). It performs NO
/// signature or chain verification, that trust comes from the ML-DSA-signed
/// well-known doc (DID -> cert) plus the SAN (cert -> DID).
struct MinimalX509 {
    let sanURIs: [String]
    let validity: (Date, Date)?
    let subjectCN: String?

    init?(der: Data) {
        let b = [UInt8](der)
        // Certificate ::= SEQUENCE { tbsCertificate, sigAlg, sigValue }
        guard let cert = Self.tlv(b, 0), cert.tag == 0x30 else { return nil }
        self.sanURIs = Self.findSANUris(b, cert.start, cert.end) ?? []
        self.validity = Self.findValidity(b, cert.start, cert.end)
        self.subjectCN = Self.findLastCN(b, cert.start, cert.end)
    }

    // MARK: - DER primitives

    private struct TLV { let tag: UInt8; let start: Int; let end: Int } // content [start, end)

    /// Parse one tag-length-value at offset `i`. Returns the content bounds.
    private static func tlv(_ d: [UInt8], _ i: Int) -> TLV? {
        guard i + 1 < d.count else { return nil }
        let tag = d[i]
        var j = i + 1
        let first = Int(d[j]); j += 1
        var length: Int
        if first < 0x80 {
            length = first
        } else {
            let n = first & 0x7F
            guard n > 0, n <= 4, j + n <= d.count else { return nil }
            length = 0
            for _ in 0..<n { length = (length << 8) | Int(d[j]); j += 1 }
        }
        let end = j + length
        guard end <= d.count else { return nil }
        return TLV(tag: tag, start: j, end: end)
    }

    /// Immediate children of a constructed node's content range.
    private static func children(_ d: [UInt8], _ start: Int, _ end: Int) -> [TLV] {
        var out: [TLV] = []
        var i = start
        while i < end {
            guard let node = tlv(d, i) else { break }
            out.append(node)
            i = node.end
        }
        return out
    }

    private static func isConstructed(_ tag: UInt8) -> Bool { (tag & 0x20) != 0 }

    // MARK: - field extraction

    /// SubjectAltName OID 2.5.29.17 == DER content bytes 55 1D 11.
    private static func isSanOid(_ d: [UInt8], _ n: TLV) -> Bool {
        n.tag == 0x06 && (n.end - n.start) == 3 &&
            d[n.start] == 0x55 && d[n.start + 1] == 0x1D && d[n.start + 2] == 0x11
    }

    /// Find the SAN extension and return its URI GeneralNames (context tag [6]).
    private static func findSANUris(_ d: [UInt8], _ start: Int, _ end: Int, _ depth: Int = 0) -> [String]? {
        if depth > 24 { return nil }
        let kids = children(d, start, end)
        // Extension ::= SEQUENCE { extnID OID, critical BOOL DEFAULT FALSE, extnValue OCTET STRING }
        if let first = kids.first, isSanOid(d, first) {
            guard let octet = kids.first(where: { $0.tag == 0x04 }) else { return [] }
            // extnValue wraps the DER of SubjectAltName ::= GeneralNames ::= SEQUENCE OF GeneralName
            guard let seq = tlv(d, octet.start), seq.tag == 0x30 else { return [] }
            var uris: [String] = []
            for gn in children(d, seq.start, seq.end) where gn.tag == 0x86 { // [6] URI (IA5String)
                if let s = String(bytes: d[gn.start..<gn.end], encoding: .utf8) { uris.append(s) }
            }
            return uris
        }
        for k in kids where isConstructed(k.tag) {
            if let found = findSANUris(d, k.start, k.end, depth + 1) { return found }
        }
        return nil
    }

    private static func isTimeTag(_ tag: UInt8) -> Bool { tag == 0x17 || tag == 0x18 }

    /// Validity ::= SEQUENCE { notBefore Time, notAfter Time } is the only
    /// two-element SEQUENCE of Time values in a certificate.
    private static func findValidity(_ d: [UInt8], _ start: Int, _ end: Int, _ depth: Int = 0) -> (Date, Date)? {
        if depth > 24 { return nil }
        let kids = children(d, start, end)
        if kids.count == 2, isTimeTag(kids[0].tag), isTimeTag(kids[1].tag),
           let nb = parseTime(d, kids[0]), let na = parseTime(d, kids[1]) {
            return (nb, na)
        }
        for k in kids where isConstructed(k.tag) {
            if let v = findValidity(d, k.start, k.end, depth + 1) { return v }
        }
        return nil
    }

    private static func parseTime(_ d: [UInt8], _ n: TLV) -> Date? {
        guard let str = String(bytes: d[n.start..<n.end], encoding: .ascii) else { return nil }
        let c = Array(str)
        func num(_ off: Int, _ len: Int) -> Int? {
            guard off + len <= c.count else { return nil }
            return Int(String(c[off..<off + len]))
        }
        var comp = DateComponents()
        var idx: Int
        if n.tag == 0x17 { // UTCTime YYMMDDHHMMSSZ
            guard let yy = num(0, 2) else { return nil }
            comp.year = yy >= 50 ? 1900 + yy : 2000 + yy
            idx = 2
        } else { // GeneralizedTime YYYYMMDDHHMMSSZ
            guard let yyyy = num(0, 4) else { return nil }
            comp.year = yyyy
            idx = 4
        }
        guard let mo = num(idx, 2), let da = num(idx + 2, 2),
              let hh = num(idx + 4, 2), let mi = num(idx + 6, 2) else { return nil }
        comp.month = mo; comp.day = da; comp.hour = hh; comp.minute = mi
        comp.second = num(idx + 8, 2) ?? 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comp)
    }

    /// commonName OID 2.5.4.3 == DER content bytes 55 04 03. Returns the LAST CN
    /// (issuer CN precedes subject CN in TBS, so the last is the subject's).
    private static func isCnOid(_ d: [UInt8], _ n: TLV) -> Bool {
        n.tag == 0x06 && (n.end - n.start) == 3 &&
            d[n.start] == 0x55 && d[n.start + 1] == 0x04 && d[n.start + 2] == 0x03
    }

    private static func findLastCN(_ d: [UInt8], _ start: Int, _ end: Int, _ depth: Int = 0) -> String? {
        if depth > 24 { return nil }
        var last: String?
        for k in children(d, start, end) {
            if k.tag == 0x30 || k.tag == 0x31 || isConstructed(k.tag) {
                // AttributeTypeAndValue ::= SEQUENCE { type OID, value DirectoryString }
                let kids = children(d, k.start, k.end)
                if kids.count == 2, isCnOid(d, kids[0]),
                   let s = String(bytes: d[kids[1].start..<kids[1].end], encoding: .utf8) {
                    last = s
                }
                if let deeper = findLastCN(d, k.start, k.end, depth + 1) { last = deeper }
            }
        }
        return last
    }
}
