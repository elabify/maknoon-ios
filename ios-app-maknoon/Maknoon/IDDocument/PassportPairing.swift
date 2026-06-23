// Pairs a scanned `IDDocument` with the issuer-issued `Credential` minted from
// the same physical passport, matched on the normalized identity tuple
// {passportNumber, dateOfBirth(ISO), expiryDate(ISO)}. That tuple is produced by
// the SAME normalization both sides already use — `LocalCredentialFactory
// .passportClaims` for the document and the issuer's `mapPassportToClaims` for
// the credential — so a document and its credential agree byte-for-byte.
//
// Display-only: no new model fields, no wire change. Used to (a) fold the
// duplicate passport credential out of the Identity tab and (b) drive the
// pinned-network strip on the merged passport card from the credential's
// `anchor.anchors`.

import Foundation

enum PassportPairing {
    struct Key: Hashable {
        let number: String
        let dob: String
        let exp: String
    }

    /// Normalized key for a scanned document, reusing the mint normalization so
    /// it matches the credential side exactly. nil when the document lacks the
    /// fields (then it simply never folds / pairs).
    static func key(for doc: IDDocument) -> Key? {
        var claims: [String: Any] = [:]
        for c in LocalCredentialFactory.passportClaims(from: doc) { claims[c.key] = c.value }
        guard let number = claims["passportNumber"] as? String, !number.isEmpty,
              let dob = claims["dateOfBirth"] as? String, !dob.isEmpty,
              let exp = claims["expiryDate"] as? String, !exp.isEmpty
        else { return nil }
        return Key(number: number, dob: dob, exp: exp)
    }

    /// Normalized key for a passport credential. nil for non-passport schemas or
    /// when the credential is missing any of the three fields.
    static func key(for cred: Credential) -> Key? {
        guard cred.header.schema == passportSchemaURI else { return nil }
        func str(_ k: String) -> String? {
            if case let .string(v)? = cred.claims[k] { return v }
            return nil
        }
        guard let number = str("passportNumber"), !number.isEmpty,
              let dob = str("dateOfBirth"), !dob.isEmpty,
              let exp = str("expiryDate"), !exp.isEmpty
        else { return nil }
        return Key(number: number, dob: dob, exp: exp)
    }

    /// The best credential representing a scanned document: prefer one that is
    /// anchored, then an issuer-issued one (iss != holder), then the newest.
    /// nil when no credential matches (scan-only → card shows "NFC verified",
    /// no chain logos).
    static func matchedCredential(for doc: IDDocument, in credentials: [Credential], holderDID: String?) -> Credential? {
        guard let k = key(for: doc) else { return nil }
        return credentials
            .filter { key(for: $0) == k }
            .sorted { lhs, rhs in
                let la = (lhs.anchor?.anchors.isEmpty == false)
                let ra = (rhs.anchor?.anchors.isEmpty == false)
                if la != ra { return la }
                let li = (lhs.header.iss != holderDID)
                let ri = (rhs.header.iss != holderDID)
                if li != ri { return li }
                return lhs.header.iat > rhs.header.iat
            }
            .first
    }

    /// Keys of all scanned documents, used to fold matching passport credentials
    /// out of the Identity-tab credential list.
    static func documentKeys(_ docs: [IDDocument]) -> Set<Key> {
        Set(docs.compactMap { key(for: $0) })
    }
}
