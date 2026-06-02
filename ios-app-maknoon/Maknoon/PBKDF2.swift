// Thin wrapper around CommonCrypto's PBKDF2.
//
// CryptoKit on iOS 26 still does not ship PBKDF2 (it has HKDF, which is
// not iteration-based and therefore not appropriate for stretching a
// user-typed passphrase). PBKDF2 lives in CommonCrypto via the
// `CCKeyDerivationPBKDF` C function, which we bridge here.
//
// Two callers in this app:
//
//   1. BIP39 mnemonic-to-seed derivation: SHA-512, 2048 iterations,
//      64-byte output. Standard BIP39 spec.
//
//   2. iCloud encrypted-backup key derivation: SHA-256, 600 000
//      iterations, 32-byte output. The high iteration count makes
//      offline brute-force of weak passphrases expensive enough that
//      a stolen blob is not a one-machine-week project.

import Foundation
import CommonCrypto

enum PBKDF2 {
    enum HashFunction {
        case sha256
        case sha512

        var ccPRF: CCPseudoRandomAlgorithm {
            switch self {
            case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case .sha512: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            }
        }
    }

    /// Run PBKDF2 over `password` and `salt`, producing `outputLength`
    /// bytes of derived key material. Throws if CommonCrypto returns
    /// a non-success status (e.g. memory pressure, parameter error).
    static func derive(
        password: Data,
        salt: Data,
        iterations: UInt32,
        hash: HashFunction,
        outputLength: Int
    ) throws -> Data {
        precondition(outputLength > 0, "PBKDF2 outputLength must be positive")

        var out = Data(count: outputLength)
        let status = out.withUnsafeMutableBytes { outBytes -> Int32 in
            return password.withUnsafeBytes { pwBytes -> Int32 in
                return salt.withUnsafeBytes { saltBytes -> Int32 in
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        hash.ccPRF,
                        iterations,
                        outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(
                domain: "PBKDF2",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CCKeyDerivationPBKDF failed with status \(status)"]
            )
        }
        return out
    }
}
