// Minimal COSE_Key parser, just enough to extract a P-256 public key
// from the authenticator's `keyAgreement` response. COSE_Key for
// secp256r1 ECDH (alg = -25) is a CBOR map of int keys:
//
//   1 (kty) = 2  (EC2)
//   3 (alg) = -25 (ECDH-ES + HKDF-256)  // CTAP2 reuses this label
//  -1 (crv) = 1  (P-256)
//  -2 (x)   = 32-byte big-endian x coordinate
//  -3 (y)   = 32-byte big-endian y coordinate
//
// We don't validate every field exhaustively; we only need x and y.
// Building a CryptoKit `P256.KeyAgreement.PublicKey` requires the
// 65-byte x9.63-uncompressed representation (0x04 || x || y), which
// we assemble here.

import Foundation
import CryptoKit

enum COSEKeyError: LocalizedError {
    case notAMap
    case missingX
    case missingY
    case wrongLength
    case keyImportFailed(String)
    var errorDescription: String? {
        switch self {
        case .notAMap:                return "COSE_Key payload was not a CBOR map"
        case .missingX:               return "COSE_Key was missing the x coordinate"
        case .missingY:               return "COSE_Key was missing the y coordinate"
        case .wrongLength:            return "COSE_Key x/y coordinates were not 32 bytes each"
        case .keyImportFailed(let m): return "Could not import COSE_Key as P-256 public: \(m)"
        }
    }
}

enum COSEKey {
    /// Parse a COSE_Key (CBOR map) into a CryptoKit P-256 public key.
    static func parseP256Public(_ value: CBORValue) throws -> P256.KeyAgreement.PublicKey {
        guard case .map = value else { throw COSEKeyError.notAMap }
        guard let xVal = value.entry(forIntKey: -2), let x = xVal.asBytes else {
            throw COSEKeyError.missingX
        }
        guard let yVal = value.entry(forIntKey: -3), let y = yVal.asBytes else {
            throw COSEKeyError.missingY
        }
        guard x.count == 32, y.count == 32 else { throw COSEKeyError.wrongLength }
        var x963 = Data([0x04])
        x963.append(x)
        x963.append(y)
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: x963)
        } catch {
            throw COSEKeyError.keyImportFailed(error.localizedDescription)
        }
    }

    /// Serialize a CryptoKit P-256 public key back to a COSE_Key CBOR
    /// map (the shape we send the authenticator inside the hmac-secret
    /// extension's `keyAgreement` field and the clientPIN
    /// getPinToken's `keyAgreement` field).
    static func encodeP256Public(_ key: P256.KeyAgreement.PublicKey) -> CBORValue {
        let raw = key.x963Representation  // 65 bytes: 0x04 || x || y
        let x = raw.subdata(in: 1..<33)
        let y = raw.subdata(in: 33..<65)
        // CTAP2 spec for COSE_Key sent to the authenticator:
        //   1 (kty)  = 2  (EC2)
        //   3 (alg)  = -25
        //  -1 (crv)  = 1  (P-256)
        //  -2 (x)
        //  -3 (y)
        return .map([
            CBORMapEntry(key: .intKey(1),  value: .unsignedInt(2)),
            CBORMapEntry(key: .intKey(3),  value: .negativeInt(-25)),
            CBORMapEntry(key: .intKey(-1), value: .unsignedInt(1)),
            CBORMapEntry(key: .intKey(-2), value: .byteString(x)),
            CBORMapEntry(key: .intKey(-3), value: .byteString(y)),
        ])
    }
}
