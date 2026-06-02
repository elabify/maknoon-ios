// Thin wrapper around NFCPassportReader.
//
// Hides the ICAO 9303 vocabulary from the rest of the app. The
// caller hands in three plain strings the user typed on the
// previous screen (document number, birth date, expiry date) and
// gets back an `IDDocument` plus an optional UIImage. Nothing in
// here leaks "MRZ", "BAC", "PACE", "DG2", "SOD" up the call stack.
//
// Disabled on the Personal-Team build because the NFC reader
// entitlement requires the paid Apple Developer Program. When the
// MAKNOON_NFC compile-time flag is set, the implementation calls
// into AndyQ/NFCPassportReader; otherwise it returns a clean
// "unsupported device" error and the UI hides the entry point.

import Foundation
import UIKit
#if MAKNOON_NFC
import CoreNFC
import NFCPassportReader
#endif

enum IDDocumentReaderError: LocalizedError {
    case nfcUnavailable
    case unsupportedDevice
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .nfcUnavailable:
            return "This phone doesn't support NFC reading. The Tap ID document feature needs an iPhone."
        case .unsupportedDevice:
            return "ID document reading isn't available on this device."
        case .readFailed(let s):
            return s
        }
    }
}

/// Read parameters the user types on the previous screen. Names are
/// intentionally neutral and non-technical.
struct IDDocumentReadParameters: Equatable, Sendable {
    /// What the user declared the document to be. Drives the kind
    /// label we save on the resulting IDDocument so the UI knows
    /// to show "Passport" copy vs generic "ID card" copy.
    var kind: IDDocumentKind
    /// The document or passport number printed on the bio page /
    /// back of the card.
    var documentNumber: String
    /// User's birth date as YYMMDD (the form the chip expects).
    var dateOfBirthYYMMDD: String
    /// Document expiry date as YYMMDD.
    var dateOfExpiryYYMMDD: String

    var isComplete: Bool {
        !documentNumber.isEmpty
            && dateOfBirthYYMMDD.count == 6
            && dateOfExpiryYYMMDD.count == 6
    }
}

/// Result returned from a successful read. The store is what
/// persists; this struct is purely the in-flight handoff.
struct IDDocumentReadResult {
    let document: IDDocument
    let photo: UIImage?
    /// Raw bytes captured off the chip. Keys are the same identifiers
    /// the persistence layer uses for file names (`sod`, `dg1`, ...).
    /// The store writes each entry to its own file and stamps the
    /// resulting filename onto the IDDocument.
    let rawChipData: [String: Data]
}

@MainActor
final class IDDocumentReader {

    /// Whether the running device is capable of reading ID documents
    /// over NFC. False on simulator and on iPads / iPhones without
    /// an NFC reader; the UI uses this to show a friendly
    /// explanation instead of letting the user start a session that
    /// will fail.
    static var isAvailable: Bool {
        #if MAKNOON_NFC && !targetEnvironment(simulator)
        return NFCTagReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    func read(parameters: IDDocumentReadParameters) async throws -> IDDocumentReadResult {
        #if MAKNOON_NFC && !targetEnvironment(simulator)
        guard NFCTagReaderSession.readingAvailable else {
            throw IDDocumentReaderError.nfcUnavailable
        }
        let reader = PassportReader()
        let mrzKey = Self.buildMRZKey(
            documentNumber: parameters.documentNumber.uppercased(),
            dateOfBirthYYMMDD: parameters.dateOfBirthYYMMDD,
            dateOfExpiryYYMMDD: parameters.dateOfExpiryYYMMDD
        )
        let passport: NFCPassportModel
        do {
            passport = try await reader.readPassport(mrzKey: mrzKey)
        } catch let nfcError as NFCPassportReaderError {
            throw IDDocumentReaderError.readFailed(humanMessage(for: nfcError))
        } catch {
            throw IDDocumentReaderError.readFailed(error.localizedDescription)
        }
        // The library's lazy `documentSigningCertificate` accessor
        // crashes the CoreNFC delegate thread on some chips (OpenSSL
        // PKCS7 parsing on the wrong thread). We never call it.
        // Instead we lift the raw SOD bytes off `dataGroupsRead[.SOD]`
        // and let the issuer-side parser do CMS extraction; the DSC
        // is embedded inside the SOD's CMS SignedData so storing the
        // SOD is enough.

        // Pull the Latin name from the MRZ regardless of whether DG11
        // also provided a native-script name. NFCPassportModel's
        // `firstName`/`lastName` get overridden by DG11.fullName when
        // present (a "feature" of the library), which is why Chinese
        // passports come back as Chinese characters with no English.
        let latin = Self.parseMRZName(passport.passportMRZ)
        let nativeFullName = (passport.dataGroupsRead[.DG11] as? DataGroup11)?.fullName

        var rawChipData: [String: Data] = [:]
        if let sodBytes = passport.dataGroupsRead[.SOD]?.data {
            rawChipData["sod"] = Data(sodBytes)
        }
        if let dg1 = passport.dataGroupsRead[.DG1]?.data {
            rawChipData["dg1"] = Data(dg1)
        }
        if let dg2 = passport.dataGroupsRead[.DG2]?.data {
            rawChipData["dg2"] = Data(dg2)
        }
        if let dg11 = passport.dataGroupsRead[.DG11]?.data {
            rawChipData["dg11"] = Data(dg11)
        }
        if let dg12 = passport.dataGroupsRead[.DG12]?.data {
            rawChipData["dg12"] = Data(dg12)
        }
        if let dg15 = passport.dataGroupsRead[.DG15]?.data {
            rawChipData["dg15"] = Data(dg15)
        }

        let aaChallenge = passport.activeAuthenticationChallenge.isEmpty
            ? nil
            : Self.hex(passport.activeAuthenticationChallenge)
        let aaSignature = passport.activeAuthenticationSignature.isEmpty
            ? nil
            : Self.hex(passport.activeAuthenticationSignature)
        let aaVerified: Bool? = (passport.activeAuthenticationChallenge.isEmpty
                                 && passport.activeAuthenticationSignature.isEmpty)
            ? nil
            : passport.activeAuthenticationPassed

        let id = UUID()
        let doc = IDDocument(
            id: id,
            nickname: nil,
            surname: passport.lastName,
            givenNames: passport.firstName,
            documentNumber: passport.documentNumber,
            nationality: passport.nationality,
            issuingAuthority: passport.issuingAuthority,
            sex: passport.gender,
            dateOfBirth: passport.dateOfBirth,
            dateOfExpiry: passport.documentExpiryDate,
            documentType: passport.documentType,
            latinSurname: latin?.surname,
            latinGivenNames: latin?.givenNames,
            nativeFullName: nativeFullName,
            userDeclaredKind: parameters.kind,
            personalNumber: passport.personalNumber,
            placeOfBirth: passport.placeOfBirth,
            photoFilename: nil,
            sodFilename: nil,
            dg1Filename: nil,
            dg2Filename: nil,
            dg11Filename: nil,
            dg12Filename: nil,
            dg15Filename: nil,
            activeAuthChallengeHex: aaChallenge,
            activeAuthSignatureHex: aaSignature,
            activeAuthVerifiedLocally: aaVerified,
            readAt: Date()
        )
        return IDDocumentReadResult(
            document: doc,
            photo: passport.passportImage,
            rawChipData: rawChipData
        )
        #else
        throw IDDocumentReaderError.unsupportedDevice
        #endif
    }

    /// Extract the Latin (ASCII) name from a raw MRZ string. ICAO
    /// 9303 puts the name into a fixed slot:
    ///   - TD3 (passport, 2 lines × 44): line 1, positions 5..43.
    ///   - TD2 (ID card variant, 2 lines × 36): line 1, positions 5..35.
    ///   - TD1 (ID card, 3 lines × 30): line 3, full 30 chars.
    /// Inside the name slot, `<<` separates surname from given names
    /// and `<` is the filler used in place of spaces. Returns nil if
    /// the MRZ isn't recognisable.
    ///
    /// This is the canonical pinyin/romanized form of the holder's
    /// name. The library's `firstName`/`lastName` accessors *prefer*
    /// the DG11 native-script name when present, which is why we
    /// parse the MRZ ourselves rather than reusing those.
    static func parseMRZName(_ mrz: String) -> (surname: String, givenNames: String)? {
        let cleaned = mrz.filter { !$0.isNewline }
        let nameField: String
        switch cleaned.count {
        case 88:  // TD3 (passport): 2 × 44
            let line1 = String(cleaned.prefix(44))
            nameField = String(line1.dropFirst(5))
        case 72:  // TD2: 2 × 36
            let line1 = String(cleaned.prefix(36))
            nameField = String(line1.dropFirst(5))
        case 90:  // TD1: 3 × 30, name on line 3
            nameField = String(cleaned.suffix(30))
        default:
            return nil
        }
        let parts = nameField.components(separatedBy: "<<")
        guard parts.count >= 2 else { return nil }
        let surname = parts[0]
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let givens = parts.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !surname.isEmpty || !givens.isEmpty else { return nil }
        return (surname, givens)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the BAC/PACE MRZ key that ICAO 9303 chips expect.
    /// Three padded fields plus their per-field check digits,
    /// concatenated. Same algorithm the NFCPassportReader sample
    /// app's PassportUtils helper uses, but `PassportUtils` itself
    /// lives in the library's Examples directory rather than the
    /// shipped product, so we compute it locally.
    static func buildMRZKey(
        documentNumber: String,
        dateOfBirthYYMMDD: String,
        dateOfExpiryYYMMDD: String
    ) -> String {
        let docNo = padMRZ(documentNumber, fieldLength: 9)
        let dob   = padMRZ(dateOfBirthYYMMDD, fieldLength: 6)
        let exp   = padMRZ(dateOfExpiryYYMMDD, fieldLength: 6)
        return "\(docNo)\(mrzCheck(docNo))\(dob)\(mrzCheck(dob))\(exp)\(mrzCheck(exp))"
    }

    private static func padMRZ(_ value: String, fieldLength: Int) -> String {
        let padded = (value + String(repeating: "<", count: fieldLength)).prefix(fieldLength)
        return String(padded)
    }

    /// ICAO 9303 7-3-1 weighted check digit. Digits/`<`/space map
    /// to their numeric values; `A`-`Z` map to 10-35.
    private static func mrzCheck(_ s: String) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, ch) in s.enumerated() {
            let value: Int
            if let d = ch.wholeNumberValue {
                value = d
            } else if ch == "<" || ch == " " {
                value = 0
            } else if let scalar = ch.unicodeScalars.first,
                      let ascii = Character(scalar).asciiValue,
                      ascii >= 65, ascii <= 90 {
                value = Int(ascii) - 55  // A=10, B=11, … Z=35
            } else {
                return 0
            }
            sum += value * weights[i % 3]
        }
        return sum % 10
    }

    #if MAKNOON_NFC
    private func humanMessage(for error: NFCPassportReaderError) -> String {
        switch error {
        case .NFCNotSupported:
            return "This phone doesn't support NFC reading."
        case .UserCanceled:
            return "Scan canceled."
        case .InvalidMRZKey:
            return "Couldn't unlock the document. Double-check the document number, birth date, and expiry date and try again."
        case .ResponseError(let reason, let sw1, let sw2):
            // Forward the chip's actual status word so we can
            // diagnose. 0x6A88 = "referenced data not found" — chip
            // refused to read the requested data group, usually
            // because the applet doesn't have it. 0x6982 = security
            // not satisfied. 0x6A82 = file not found. 0x6300 =
            // verification failed (BAC key probably wrong).
            let sw = String(format: "0x%02X%02X", sw1, sw2)
            return swDescription(sw1: sw1, sw2: sw2, reason: reason, sw: sw)
        case .ConnectionError:
            return "Lost connection to the document. Hold the phone steady against the photo page and try again."
        case .UnexpectedError:
            return "Something went wrong. Try again, holding the phone steady against the document."
        default:
            return "Couldn't read the document. \(error.localizedDescription)"
        }
    }

    /// Translate an APDU status word into something the user can act
    /// on. The reason string from the library is usually a one-liner
    /// like "Referenced data was not found" which doesn't tell the
    /// user what to do.
    private func swDescription(sw1: UInt8, sw2: UInt8, reason: String, sw: String) -> String {
        switch (sw1, sw2) {
        case (0x6A, 0x88), (0x6A, 0x82):
            return "This card doesn't expose the standard ICAO data groups (chip rejected the read with \(sw)). Some national-ID cards use vendor-specific applets that require an issuer-registered service to read."
        case (0x63, _), (0x69, 0x82):
            // 0x63xx (incl. 0x6300 and the 0x63Cx "verification failed,
            // retries remaining" family) and 0x6982 all mean BAC/PACE
            // authentication failed: the access key derived from the
            // typed details doesn't match the chip. This is NOT a
            // signal / positioning problem, so don't tell the user to
            // hold the phone steadier. Passports derive their key from
            // printed data and have no permanent lockout, so repeated
            // tries are safe but pointless until the details are fixed.
            return "The chip rejected the document number / birth date / expiry combination (\(sw)). Re-check those three values against the data page (watch O vs 0 and 1 vs I), and make sure the expiry is the document's expiry date, not its issue date. The document won't lock from repeated tries."
        case (0x69, 0x84):
            return "The card is locked (\(sw)). Wait a moment and try again."
        case (0x67, _):
            return "Wrong APDU length (\(sw)). This usually means the document's chip uses a non-standard format that the ICAO 9303 reader can't handle."
        default:
            return "Chip returned \(sw): \(reason). Hold the phone steady against the card and try again."
        }
    }
    #endif
}
