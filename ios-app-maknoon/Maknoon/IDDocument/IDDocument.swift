// One ID document the user has tapped to the phone. Generic enough
// to cover any chip-bearing identity document the phone can read:
// passports, national ID cards, residence permits, future formats.
//
// What we store is the bearer-visible data: name, photo, document
// number, dates. Country code is stored as a raw ISO 3166-1 alpha-3
// string ("USA", "ARE", "GBR", ...) but the UI looks it up to the
// user-readable country name so the rest of the app never has to
// know any country specifically.
//
// We also retain the signed SOD bytes and the signing certificate so
// that, in a follow-up, a verifier can validate the read against the
// issuing authority's PKI without having to trust Maknoon. That's
// what makes this a real credential rather than a typed-in form.

import Foundation
import SwiftUI

/// The kind of ID the user selected on the type-picker before
/// scanning. Drives copy in the entry form (e.g. "Card number on
/// back" vs "Passport number") and the labels we show in the
/// saved-document detail view (e.g. "Emirates ID number" for the
/// TD1 optional-data field).
enum IDDocumentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case passport
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .passport: return "Passport"
        case .other:    return "Other ID document"
        }
    }

    var iconName: String {
        switch self {
        case .passport: return "book.pages.fill"
        case .other:    return "rectangle.and.text.magnifyingglass"
        }
    }

    var blurb: String {
        switch self {
        case .passport:
            return "Any ePassport with the chip symbol on the cover (most passports issued since around 2010)."
        case .other:
            return "Other ICAO-compatible IDs (EU national ID cards, residence permits, similar formats)."
        }
    }

    /// User-facing label for the document-number field in the
    /// entry form. The chip authenticates on this number (plus
    /// DOB + expiry), so it has to be the same number that's
    /// encoded into the MRZ on the data page of the document.
    var documentNumberLabel: String {
        switch self {
        case .passport: return "Passport number"
        case .other:    return "Document number"
        }
    }

    var documentNumberHint: String {
        switch self {
        case .passport:
            return "The 6 to 9-character passport number from the inside of the cover."
        case .other:
            return "The number printed alongside the MRZ block, typically 6 to 9 characters."
        }
    }

    var personalNumberLabel: String {
        "Personal number"
    }
}

struct IDDocument: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var nickname: String?

    // Bearer biographical data. `surname` / `givenNames` are what the
    // NFCPassportReader library reports as the primary name: for most
    // passports that's the Latin/ASCII MRZ form, but for documents
    // that expose DG11.fullName (Chinese e-passports, some Korean and
    // Japanese passports, Arabic-script issuers) the library
    // overrides those fields with the native-script name. The
    // pinyin/transliterated form is preserved separately in
    // `latinSurname` / `latinGivenNames` below, parsed from the MRZ.
    let surname: String
    let givenNames: String
    let documentNumber: String
    let nationality: String      // ISO 3166-1 alpha-3
    let issuingAuthority: String // ISO 3166-1 alpha-3
    let sex: String?             // "M" / "F" / "X" — stored as-read
    let dateOfBirth: String      // YYMMDD as read, or empty if unknown
    let dateOfExpiry: String     // YYMMDD as read
    let documentType: String     // e.g. "P", "ID", "IP" — as read

    /// Latin surname parsed straight from the MRZ (DG1 tag 0x5B,
    /// before any DG11 override). For a Chinese passport reading
    /// "ZHANG<<SAN" this is "ZHANG"; for a US passport it's identical
    /// to `surname`. Always populated when we have an MRZ.
    var latinSurname: String?

    /// Latin given names parsed from the MRZ. Pinyin for CHN
    /// passports, Hepburn romaji for JPN, etc.
    var latinGivenNames: String?

    /// Native-script full name from DG11 tag 0x5F0E ("name of holder
    /// in national characters"). For a CHN passport this is the
    /// Chinese characters; nil if the chip didn't expose DG11 or DG11
    /// didn't include a fullName tag.
    var nativeFullName: String?

    /// What the user declared the document to be on the type
    /// picker before scanning. Decoupled from `documentType`
    /// (which is what the chip reported) because the chip emits
    /// generic codes like "I" for any TD1 card; the user's
    /// declaration tells us whether to render it as "Emirates ID"
    /// vs "EU residence permit" vs "Other ID".
    var userDeclaredKind: IDDocumentKind?

    /// MRZ optional data / DG11 personal number, if the chip
    /// exposed one. For Emirates ID this is the 15-digit Emirates
    /// ID number.
    var personalNumber: String?

    /// Place of birth from DG11 tag 0x5F11. Free-form string the
    /// issuer chose at personalisation time (often a city, sometimes
    /// "City, Country"). Many passports leave DG11 absent entirely.
    var placeOfBirth: String?

    // Bearer photo if the chip exposed one (DG2). Kept as JPEG to keep
    // storage small. Stored separately from the JSON via filename
    // reference so the JSON stays small enough to live in
    // UserDefaults.
    var photoFilename: String?

    // ---- Chain-of-trust material for later verification. -----------------
    // The SOD is a CMS SignedData blob signed by the Document Signing
    // Certificate (DSC); the DSC sits inside the SOD's `certificates`
    // field and is itself signed by the issuing country's Country
    // Signing CA (CSCA). A verifier needs:
    //   1. The SOD bytes (we store them).
    //   2. The DSC (a verifier extracts it from the SOD).
    //   3. The CSCA (obtained out-of-band from the ICAO PKD; not on the
    //      chip, not our responsibility to store).
    //   4. The raw bytes of each data group whose hash is listed in the
    //      SOD, so the verifier can re-hash them and confirm the SOD
    //      hash table matches.
    // We store the raw DGs to disk by filename. Active Authentication
    // proves the chip itself isn't a clone: we send a challenge, the
    // chip signs it with a DG15-protected private key, we keep both
    // the challenge and the chip's signature so a verifier can replay
    // the check against DG15's public key.

    /// Raw SOD bytes (Security Object of the Document, ICAO 9303 §9).
    /// CMS SignedData containing per-data-group hashes plus the DSC.
    var sodFilename: String?

    /// Raw DG1 bytes (MRZ). Hashed by the SOD; needed if a verifier
    /// is asserting any MRZ-derived claim.
    var dg1Filename: String?

    /// Raw DG2 bytes (facial image). Hashed by the SOD; only required
    /// if a credential claims the photo.
    var dg2Filename: String?

    /// Raw DG11 bytes (additional personal details, including the
    /// native-script name + place of birth + personal number).
    var dg11Filename: String?

    /// Raw DG12 bytes (additional document details, including
    /// `dateOfIssue` 0x5F26 and `issuingAuthority` 0x5F19 when the
    /// issuer populated them). Many passports leave DG12 absent.
    var dg12Filename: String?

    /// Raw DG15 bytes (Active Authentication public key). Hashed by
    /// the SOD; the AA signature is verified against it.
    var dg15Filename: String?

    /// Active Authentication challenge we sent to the chip, if AA
    /// was attempted. Hex.
    var activeAuthChallengeHex: String?

    /// Active Authentication signature the chip returned over the
    /// challenge, signed with the DG15-resident private key. Hex.
    var activeAuthSignatureHex: String?

    /// Whether the NFCPassportReader library's local AA check passed
    /// at read time. The issuer is expected to verify independently
    /// using `activeAuthChallengeHex` + `activeAuthSignatureHex` +
    /// DG15, but this lets the UI show a confidence hint.
    var activeAuthVerifiedLocally: Bool?

    let readAt: Date

    /// OpenSanctions screening result, set when the user runs the
    /// opt-in "Check sanctions" action in the detail view. nil means
    /// the document has never been screened. Persisted with the rest
    /// of the IDDocument JSON in UserDefaults.
    var sanctionsResult: SanctionsScreenResult?

    /// On-device ICAO 9303 Passive Authentication result, set when the detail
    /// view runs the verifier against the cached CSCA bundle. nil = not yet run.
    /// Advisory only; the issuer re-verifies authoritatively at issuance.
    var passiveAuthResult: PassiveAuthResult?

    /// User-visible best name. Prefers the Latin MRZ form so foreign
    /// systems, verifiers, and travel infrastructure all see the same
    /// string the user does. Falls back to the library-reported name
    /// (which is the native-script form for CHN/JPN/KOR/etc. when
    /// DG11 was present).
    var displayName: String {
        let latinParts = [latinGivenNames, latinSurname]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !latinParts.isEmpty {
            return latinParts.joined(separator: " ")
        }
        let parts = [givenNames, surname]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Native-script name when distinct from the Latin name (e.g.
    /// Chinese characters on a CHN passport). Returns nil when the
    /// chip didn't expose a separate native form, or when the two are
    /// identical so the UI doesn't have to render the same string
    /// twice. The detail view shows this as a secondary line under
    /// `displayName`. Strips MRZ-style `<` filler from the library's
    /// surname/givenNames pair before comparison and display.
    var nativeDisplayName: String? {
        let nativeParts = [givenNames, surname]
            .map { Self.cleanMRZText($0) }
            .filter { !$0.isEmpty }
        guard !nativeParts.isEmpty else { return nil }
        let native = nativeParts.joined(separator: " ")
        let latin = [latinGivenNames, latinSurname]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return latin.caseInsensitiveCompare(native) == .orderedSame ? nil : native
    }

    /// One-line summary for the card view.
    var summary: String {
        let country = Self.countryName(for: issuingAuthority) ?? issuingAuthority
        return country
    }

    /// User-facing label for the document kind. Prefers the
    /// user-declared kind (set on the type picker) because the
    /// chip's documentType is generic ("I" matches any TD1 card).
    /// Falls back to a chip-derived guess for legacy saved docs
    /// that pre-date the type picker.
    var kindLabel: String {
        if let userDeclaredKind { return userDeclaredKind.displayName }
        switch documentType.prefix(1).uppercased() {
        case "P":  return "Passport"
        case "I":  return "ID card"
        case "A":  return "Residence permit"
        case "V":  return "Visa"
        default:   return "Document"
        }
    }

    /// Place of birth normalized for display. Many issuers pack DG11
    /// fields the same way as the MRZ (space → `<`, double-`<` as a
    /// logical separator between adjacent components), so a US
    /// passport reports `PENNSYLVANIA<USA` rather than
    /// `PENNSYLVANIA, USA`. We undo the MRZ-style filler here without
    /// touching the raw string (which the issuer needs for verification).
    var formattedPlaceOfBirth: String? {
        placeOfBirth.flatMap { Self.cleanMRZText($0) }
    }

    /// Apply the same cleanup to the native-script full name. CHN
    /// passports usually don't put `<` filler into 5F0E (it's UTF-8
    /// Chinese characters), but some issuers reuse MRZ packing in the
    /// native field too. Cheap to apply unconditionally.
    var displayNativeFullName: String? {
        nativeFullName.flatMap { Self.cleanMRZText($0) }
    }

    var formattedDateOfBirth: String? {
        Self.formatYYMMDD(dateOfBirth, kind: .birth)
    }

    var formattedDateOfExpiry: String? {
        Self.formatYYMMDD(dateOfExpiry, kind: .expiry)
    }

    /// SF Symbol shown on the saved-document card. Prefers the
    /// user-declared kind, falls back to a chip-derived guess.
    var iconName: String {
        if let userDeclaredKind { return userDeclaredKind.iconName }
        switch documentType.prefix(1).uppercased() {
        case "P":  return "book.pages.fill"
        case "I":  return "person.text.rectangle.fill"
        case "A":  return "house.and.flag.fill"
        case "V":  return "airplane.circle.fill"
        default:   return "rectangle.and.text.magnifyingglass"
        }
    }

    // MARK: -- helpers

    /// Tidy ICAO 9303 MRZ-style filler used by some issuers inside
    /// DG11 free-text fields. DG11 is UTF-8 (Doc 9303 Part 10), so
    /// `<` here is never a real space substitute — issuers had
    /// regular spaces available and explicitly chose `<` to separate
    /// components. We treat any run of `<` as a comma separator:
    ///   - `PENNSYLVANIA<USA`  → `PENNSYLVANIA, USA`
    ///   - `BEIJING<<CHINA`    → `BEIJING, CHINA`
    ///   - `RIYADH<SAUDI ARABIA` → `RIYADH, SAUDI ARABIA`
    /// Collapses repeated punctuation/whitespace and trims edges.
    static func cleanMRZText(_ s: String) -> String {
        // Use a regex-free reduction: split on `<`, drop empty
        // segments, join with `, `. Then collapse double spaces and
        // trim trailing separators.
        let parts = s.split(separator: "<", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out = parts.joined(separator: ", ")
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        )
    }

    /// Look up an ISO 3166-1 alpha-3 code in CFLocale. Returns nil for
    /// codes Apple doesn't know (rare; this is the same registry
    /// passport authorities pull from).
    static func countryName(for alpha3: String) -> String? {
        let code = alpha3.uppercased()
        if let alpha2 = ISO3166.alpha2(for: code) {
            return Locale.current.localizedString(forRegionCode: alpha2)
        }
        return nil
    }

    /// Which field the YY two-digit year belongs to. Drives the
    /// century-resolution rule.
    enum DateKind {
        /// Date of birth. People born 1925-1999 still have valid
        /// documents, so we use a sliding window anchored at the
        /// current year: YY <= current-year-2-digit → 2000s,
        /// otherwise 1900s. Means a YY of 25 today reads as 2025
        /// (a 1-year-old, valid) and a YY of 26 reads as 1926
        /// (a 99-year-old, still plausible).
        case birth
        /// Date of expiry. Always 2000s — passports valid today
        /// expire between now and 2099. Picking the 1900s window
        /// for expiry is what produced the "1933" bug.
        case expiry
    }

    /// "YYMMDD" → "DD MMM YYYY". Returns nil if the input isn't
    /// six digits. The chip never emits century, so we apply a
    /// context-dependent window per `DateKind`.
    static func formatYYMMDD(_ s: String, kind: DateKind = .birth) -> String? {
        guard s.count == 6, s.allSatisfy(\.isNumber) else { return nil }
        let yy = Int(s.prefix(2)) ?? 0
        let mm = Int(s.dropFirst(2).prefix(2)) ?? 0
        let dd = Int(s.suffix(2)) ?? 0
        let century: Int
        switch kind {
        case .birth:
            let currentYY = Calendar(identifier: .gregorian)
                .component(.year, from: Date()) % 100
            century = (yy <= currentYY) ? 2000 : 1900
        case .expiry:
            century = 2000
        }
        var comps = DateComponents()
        comps.year = century + yy
        comps.month = mm
        comps.day = dd
        guard let d = Calendar(identifier: .gregorian).date(from: comps) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

/// Minimal ISO 3166-1 alpha-3 → alpha-2 mapping so we can hand the
/// alpha-2 to CFLocale for the localized country name. Includes a
/// curated subset; falls back to the alpha-3 string if a code is
/// unknown so the UI never crashes on an exotic passport.
enum ISO3166 {
    static func alpha2(for alpha3: String) -> String? {
        switch alpha3.uppercased() {
        case "AFG": return "AF"; case "ALB": return "AL"; case "DZA": return "DZ"
        case "AND": return "AD"; case "AGO": return "AO"; case "ARG": return "AR"
        case "ARM": return "AM"; case "AUS": return "AU"; case "AUT": return "AT"
        case "AZE": return "AZ"; case "BHR": return "BH"; case "BGD": return "BD"
        case "BLR": return "BY"; case "BEL": return "BE"; case "BLZ": return "BZ"
        case "BEN": return "BJ"; case "BTN": return "BT"; case "BOL": return "BO"
        case "BIH": return "BA"; case "BWA": return "BW"; case "BRA": return "BR"
        case "BRN": return "BN"; case "BGR": return "BG"; case "BFA": return "BF"
        case "BDI": return "BI"; case "KHM": return "KH"; case "CMR": return "CM"
        case "CAN": return "CA"; case "CPV": return "CV"; case "TCD": return "TD"
        case "CHL": return "CL"; case "CHN": return "CN"; case "COL": return "CO"
        case "COM": return "KM"; case "COG": return "CG"; case "COD": return "CD"
        case "CRI": return "CR"; case "CIV": return "CI"; case "HRV": return "HR"
        case "CUB": return "CU"; case "CYP": return "CY"; case "CZE": return "CZ"
        case "DNK": return "DK"; case "DJI": return "DJ"; case "DOM": return "DO"
        case "ECU": return "EC"; case "EGY": return "EG"; case "SLV": return "SV"
        case "GNQ": return "GQ"; case "ERI": return "ER"; case "EST": return "EE"
        case "SWZ": return "SZ"; case "ETH": return "ET"; case "FJI": return "FJ"
        case "FIN": return "FI"; case "FRA": return "FR"; case "GAB": return "GA"
        case "GMB": return "GM"; case "GEO": return "GE"; case "DEU": return "DE"
        case "D":   return "DE"            // some passports emit "D<<<"
        case "GHA": return "GH"; case "GRC": return "GR"; case "GTM": return "GT"
        case "GIN": return "GN"; case "GNB": return "GW"; case "GUY": return "GY"
        case "HTI": return "HT"; case "HND": return "HN"; case "HUN": return "HU"
        case "ISL": return "IS"; case "IND": return "IN"; case "IDN": return "ID"
        case "IRN": return "IR"; case "IRQ": return "IQ"; case "IRL": return "IE"
        case "ISR": return "IL"; case "ITA": return "IT"; case "JAM": return "JM"
        case "JPN": return "JP"; case "JOR": return "JO"; case "KAZ": return "KZ"
        case "KEN": return "KE"; case "KOR": return "KR"; case "PRK": return "KP"
        case "KWT": return "KW"; case "KGZ": return "KG"; case "LAO": return "LA"
        case "LVA": return "LV"; case "LBN": return "LB"; case "LSO": return "LS"
        case "LBR": return "LR"; case "LBY": return "LY"; case "LIE": return "LI"
        case "LTU": return "LT"; case "LUX": return "LU"; case "MDG": return "MG"
        case "MWI": return "MW"; case "MYS": return "MY"; case "MDV": return "MV"
        case "MLI": return "ML"; case "MLT": return "MT"; case "MRT": return "MR"
        case "MUS": return "MU"; case "MEX": return "MX"; case "MDA": return "MD"
        case "MCO": return "MC"; case "MNG": return "MN"; case "MNE": return "ME"
        case "MAR": return "MA"; case "MOZ": return "MZ"; case "MMR": return "MM"
        case "NAM": return "NA"; case "NPL": return "NP"; case "NLD": return "NL"
        case "NZL": return "NZ"; case "NIC": return "NI"; case "NER": return "NE"
        case "NGA": return "NG"; case "MKD": return "MK"; case "NOR": return "NO"
        case "OMN": return "OM"; case "PAK": return "PK"; case "PSE": return "PS"
        case "PAN": return "PA"; case "PNG": return "PG"; case "PRY": return "PY"
        case "PER": return "PE"; case "PHL": return "PH"; case "POL": return "PL"
        case "PRT": return "PT"; case "QAT": return "QA"; case "ROU": return "RO"
        case "RUS": return "RU"; case "RWA": return "RW"; case "SAU": return "SA"
        case "SEN": return "SN"; case "SRB": return "RS"; case "SLE": return "SL"
        case "SGP": return "SG"; case "SVK": return "SK"; case "SVN": return "SI"
        case "SOM": return "SO"; case "ZAF": return "ZA"; case "ESP": return "ES"
        case "LKA": return "LK"; case "SDN": return "SD"; case "SUR": return "SR"
        case "SWE": return "SE"; case "CHE": return "CH"; case "SYR": return "SY"
        case "TWN": return "TW"; case "TJK": return "TJ"; case "TZA": return "TZ"
        case "THA": return "TH"; case "TLS": return "TL"; case "TGO": return "TG"
        case "TON": return "TO"; case "TTO": return "TT"; case "TUN": return "TN"
        case "TUR": return "TR"; case "TKM": return "TM"; case "UGA": return "UG"
        case "UKR": return "UA"; case "ARE": return "AE"; case "GBR": return "GB"
        case "USA": return "US"; case "URY": return "UY"; case "UZB": return "UZ"
        case "VUT": return "VU"; case "VEN": return "VE"; case "VNM": return "VN"
        case "YEM": return "YE"; case "ZMB": return "ZM"; case "ZWE": return "ZW"
        default:    return nil
        }
    }
}
