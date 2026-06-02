// Mint a SELF-SIGNED credential locally from a scanned passport, with no
// issuer and no on-chain anchor. The holder's ML-DSA-65 master key is the
// issuer: `header.iss == header.sub == holderDID`, and `headerSig` is the
// holder's signature over the canonical header. Another Maknoon client can
// verify it fully offline (Merkle inclusion + the self-signature), and, when
// an App Attest binding is present, raise the trust tier to "app-verified".
//
// The credential carries the SAME schema + Merkle shape an Elabify-issued
// passport credential carries, so the existing Privacy QR / Attribute QR /
// presentation pipeline renders it unchanged.

import Foundation
import ElabifyCore

/// Schema shared with the Elabify passport issuer so self-signed and
/// issuer-signed passport credentials are structurally identical.
let passportSchemaURI = "elabify://schema/global/passport/v1"

enum LocalCredentialError: LocalizedError {
    case noClaims
    case cidDerivationFailed
    case headerCanonicalizationFailed

    var errorDescription: String? {
        switch self {
        case .noClaims:
            return "This document has no fields to put in a credential."
        case .cidDerivationFailed:
            return "Could not derive the credential id."
        case .headerCanonicalizationFailed:
            return "Could not canonicalize the credential header."
        }
    }
}

enum LocalCredentialFactory {

    /// Build a self-signed credential from an ordered claim set. Pure: the
    /// header signature is produced by `signHeader` (the holder's ML-DSA
    /// master key), so this is unit-testable without a real IdentitySandwich.
    static func buildCredential(
        claims: [(key: String, value: Any)],
        holderDID: String,
        schema: String,
        iat: Int64,
        exp: Int64?,
        signHeader: (Data) throws -> Data
    ) throws -> Credential {
        guard !claims.isEmpty else { throw LocalCredentialError.noClaims }

        // Deterministic claim order: sort keys exactly as the spec does.
        var claimMap: [String: Any] = [:]
        for c in claims { claimMap[c.key] = c.value }
        let sortedKeys = sortClaimKeys(claimMap)
        let entries: [(key: String, value: Any)] = sortedKeys.map { ($0, claimMap[$0]!) }

        // Merkle tree over the sorted claims; root + per-leaf hashes.
        let tree = try MerkleTree(entries: entries)
        let rootHex = "0x" + CredentialCanonical.hex(tree.root)
        let leafHashes: [HexString] = try sortedKeys.map {
            "0x" + CredentialCanonical.hex(try claimLeafHash(key: $0, value: claimMap[$0]!))
        }
        let merkle = MerkleTreeDescriptor(
            sortedKeys: sortedKeys, leafHashes: leafHashes, root: rootHex, depth: tree.depth
        )

        // Header with an empty cid first, so deriveCid hashes the exact field
        // set the final (signed) header carries (minus the cid value).
        let header0 = CredentialHeader(
            v: 1, alg: "ML-DSA-65", hash: "RPO-256",
            iss: holderDID, sub: holderDID, iat: iat, exp: exp,
            cid: "", root: rootHex, schema: schema, allowedNetworks: nil
        )
        guard let header0Dict = CredentialCanonical.headerDict(header0) else {
            throw LocalCredentialError.headerCanonicalizationFailed
        }
        guard let cidData = try? deriveCid(headerWithoutCid: header0Dict, iat: UInt64(iat)) else {
            throw LocalCredentialError.cidDerivationFailed
        }
        let cid = "0x" + CredentialCanonical.hex(cidData)

        let header = CredentialHeader(
            v: 1, alg: "ML-DSA-65", hash: "RPO-256",
            iss: holderDID, sub: holderDID, iat: iat, exp: exp,
            cid: cid, root: rootHex, schema: schema, allowedNetworks: nil
        )
        guard let headerBytes = CredentialCanonical.headerBytes(header) else {
            throw LocalCredentialError.headerCanonicalizationFailed
        }
        let sig = try signHeader(headerBytes)
        let headerSig = "0x" + CredentialCanonical.hex(sig)

        let claimsJSON: [String: JSONValue] = claimMap.mapValues { anyToJSONValue($0) }
        return Credential(
            header: header, headerSig: headerSig, claims: claimsJSON,
            merkleTree: merkle, anchor: nil
        )
    }

    /// Mint a self-signed passport credential from a scanned `IDDocument`,
    /// signing the header with the holder's ML-DSA master key (Face ID gated).
    static func mint(from doc: IDDocument, sandwich: IdentitySandwich) throws -> Credential {
        let claims = passportClaims(from: doc)
        return try buildCredential(
            claims: claims,
            holderDID: sandwich.holderDID,
            schema: passportSchemaURI,
            iat: Int64(Date().timeIntervalSince1970),
            exp: nil,
            signHeader: { try sandwich.signWithMaster($0, localizedReason: "Create a local identity credential") }
        )
    }

    /// Passport fields → credential claims, NORMALIZED to match an
    /// Elabify-issued passport credential (issuer-backend
    /// `mapPassportToClaims`) so a self-signed passport and an
    /// issuer-signed one carry the same keys + value formats:
    ///   - dates: MRZ `YYMMDD` → ISO 8601 `YYYY-MM-DD`
    ///   - countries: ISO 3166-1 alpha-3 (MRZ) → alpha-2 (schema)
    ///   - names / placeOfBirth: MRZ `<` filler collapsed to single spaces
    ///   - passportNumber: uppercased, non-alphanumerics stripped
    ///   - issueDate: estimated as expiry − 10y (passports rarely expose it)
    /// Un-normalizable fields are omitted rather than blocking the mint.
    /// Derived booleans (over18/over21/notExpired) are intentionally left
    /// out until the local claim model carries non-string values.
    static func passportClaims(from doc: IDDocument) -> [(key: String, value: Any)] {
        var out: [(key: String, value: Any)] = []
        func addStr(_ key: String, _ value: String?) {
            guard let v = value, !v.isEmpty else { return }
            out.append((key, v))
        }
        addStr("givenName", cleanMRZText(doc.latinGivenNames ?? doc.givenNames))
        addStr("familyName", cleanMRZText(doc.latinSurname ?? doc.surname))
        let passportNumber = doc.documentNumber.uppercased().filter { $0.isLetter || $0.isNumber }
        addStr("passportNumber", passportNumber)
        addStr("issuingCountry", alpha3ToAlpha2(doc.issuingAuthority))
        addStr("nationality", alpha3ToAlpha2(doc.nationality))
        let dateOfBirth = yymmddToISO(doc.dateOfBirth, kind: .birth)
        addStr("dateOfBirth", dateOfBirth)
        let expiryDate = yymmddToISO(doc.dateOfExpiry, kind: .expiry)
        addStr("expiryDate", expiryDate)
        if let expiryDate { addStr("issueDate", estimateIssueDate(fromExpiryISO: expiryDate)) }
        addStr("sex", normalizeSex(doc.sex))
        addStr("placeOfBirth", cleanMRZText(doc.placeOfBirth))

        // Issuer-derived predicate claims, computed against mint time (UTC),
        // matching the issuer's mapPassportToClaims. Emitted as JSON booleans
        // (the schema types them boolean) so a self-signed and an
        // issuer-signed passport carry the same claim set + value types.
        let now = Date()
        if let dateOfBirth, let age = ageYears(fromISO: dateOfBirth, to: now) {
            out.append(("over18", age >= 18))
            out.append(("over21", age >= 21))
        }
        if let expiryDate, let exp = parseISODateUTC(expiryDate) {
            out.append(("notExpired", exp >= now))
        }
        return out
    }

    // MARK: -- passport normalization (mirrors issuer-backend passport-attestation.ts)

    private enum PassportDateKind { case birth, expiry }

    /// Collapse MRZ `<` filler and whitespace runs to single spaces; trim.
    /// `"CHODROFF<<BENJAMIN"` → `"CHODROFF BENJAMIN"`, `"ILLINOIS<USA"` →
    /// `"ILLINOIS USA"`. Matches the issuer's `replace(/[<\s]+/g, ' ').trim()`.
    private static func cleanMRZText(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let parts = s.replacingOccurrences(of: "<", with: " ")
            .split(whereSeparator: { $0 == " " || $0.isWhitespace })
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// MRZ `YYMMDD` → ISO `YYYY-MM-DD`. Birth uses a sliding window
    /// (yy ≤ current 2-digit year → 2000s, else 1900s); expiry is always
    /// 2000s. Returns nil on malformed input (caller omits the claim).
    private static func yymmddToISO(_ yymmdd: String, kind: PassportDateKind) -> String? {
        guard yymmdd.count == 6, yymmdd.allSatisfy({ $0.isNumber }) else { return nil }
        let chars = Array(yymmdd)
        guard let yy = Int(String(chars[0..<2])) else { return nil }
        let mm = String(chars[2..<4])
        let dd = String(chars[4..<6])
        let century: Int
        switch kind {
        case .birth:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let currentYY = cal.component(.year, from: Date()) % 100
            century = yy <= currentYY ? 2000 : 1900
        case .expiry:
            century = 2000
        }
        return "\(century + yy)-\(mm)-\(dd)"
    }

    /// expiry − 10y, keeping month/day. Modal passport validity is 10y; a
    /// shorter validity is off by ≤5y, acceptable for a self-asserted claim.
    private static func estimateIssueDate(fromExpiryISO iso: String) -> String? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]) else { return nil }
        return "\(year - 10)-\(parts[1])-\(parts[2])"
    }

    private static func normalizeSex(_ sex: String?) -> String? {
        guard let s = sex, !s.isEmpty else { return nil }
        let up = s.uppercased()
        return ["M", "F", "X"].contains(up) ? up : "X"
    }

    /// ISO 3166-1 alpha-3 → alpha-2. Mirrors the issuer's map. Returns nil
    /// for an unmapped code (caller omits the claim rather than failing the
    /// mint); the issuer rejects unmapped codes, but a local self-asserted
    /// credential degrades gracefully instead.
    private static func alpha3ToAlpha2(_ alpha3: String) -> String? {
        let map: [String: String] = [
            "ARE": "AE", "AUS": "AU", "AUT": "AT", "BEL": "BE", "BGR": "BG", "BRA": "BR", "CAN": "CA",
            "CHE": "CH", "CHN": "CN", "CZE": "CZ", "DEU": "DE", "DNK": "DK", "ESP": "ES", "EST": "EE",
            "FIN": "FI", "FRA": "FR", "GBR": "GB", "GRC": "GR", "HUN": "HU", "IND": "IN", "IRL": "IE",
            "ISL": "IS", "ITA": "IT", "JPN": "JP", "KOR": "KR", "LTU": "LT", "LUX": "LU", "LVA": "LV",
            "MEX": "MX", "NLD": "NL", "NOR": "NO", "NZL": "NZ", "POL": "PL", "PRT": "PT", "ROU": "RO",
            "SAU": "SA", "SGP": "SG", "SVK": "SK", "SVN": "SI", "SWE": "SE", "TUR": "TR", "UKR": "UA",
            "USA": "US", "ZAF": "ZA",
        ]
        return map[alpha3.uppercased()]
    }

    /// Parse an ISO `YYYY-MM-DD` to a UTC-midnight Date (matches the issuer's
    /// `new Date("YYYY-MM-DD")`, which is UTC). Returns nil on malformed input.
    private static func parseISODateUTC(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: dc)
    }

    /// Completed years between an ISO birth date and a reference instant (UTC).
    private static func ageYears(fromISO dob: String, to ref: Date) -> Int? {
        guard let dobDate = parseISODateUTC(dob) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateComponents([.year], from: dobDate, to: ref).year
    }

    /// Map a claim value to its JSON representation. Bool is matched before the
    /// numeric cases so a Swift boolean never serializes as a number.
    private static func anyToJSONValue(_ v: Any) -> JSONValue {
        switch v {
        case let b as Bool:   return .bool(b)
        case let s as String: return .string(s)
        case let i as Int64:  return .int(i)
        case let i as Int:    return .int(Int64(i))
        case let d as Double: return .double(d)
        default:              return .string("\(v)")
        }
    }
}

/// Shared canonicalization helpers for self-issued credentials, so minting
/// and offline verification agree byte-for-byte.
enum CredentialCanonical {
    /// Lowercase hex, no 0x prefix.
    static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// CredentialHeader -> JSON dict (nil optionals omitted), matching the
    /// reconstruction IssuerIdentityResolver uses for issuer headerSig checks.
    static func headerDict(_ header: CredentialHeader) -> [String: Any]? {
        guard let raw = try? JSONEncoder().encode(header),
              let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        return dict
    }

    /// Canonical bytes the holder signs for `headerSig` (and that a verifier
    /// reconstructs to check it).
    static func headerBytes(_ header: CredentialHeader) -> Data? {
        guard let dict = headerDict(header) else { return nil }
        return try? ElabifyCore.canonicalize(dict)
    }

    /// Holder DID derived from an ML-DSA-65 master public key, byte-identical
    /// to `IdentitySandwich.holderDID`. Used to detect self-issued credentials
    /// (`header.iss == holderDID(fromMasterPublicKey: presentedPk)`).
    static func holderDID(fromMasterPublicKey pk: Data) -> String {
        let tagged = ElabifyCore.rpo256Tagged(0x03, pk)
        let hexId = tagged.prefix(20).map { String(format: "%02x", $0) }.joined()
        return "did:elabify:sepolia:holder:0x" + hexId
    }

    /// The bytes an App Attest assertion signs over, binding the attestation
    /// to this exact credential so it can't be replayed onto another one.
    static func appAttestBindingBytes(cid: String, root: String, holderPkHex: String, schema: String) -> Data? {
        let dict: [String: Any] = ["cid": cid, "root": root, "holderPk": holderPkHex, "schema": schema]
        return try? ElabifyCore.canonicalize(dict)
    }
}
