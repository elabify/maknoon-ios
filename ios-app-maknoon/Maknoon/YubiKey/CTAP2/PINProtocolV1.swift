// CTAP2 PIN/UV Auth Protocol v1, just enough to drive hmac-secret on
// a PIN-protected YubiKey 5 series authenticator. Spec ref:
// CTAP2.1 §6.5.4 (authenticatorClientPIN, protocol 1).
//
// Protocol v1 (the version YubiKey 5 supports unconditionally; v2
// arrived in firmware 5.4+):
//
//   sharedSecret = SHA-256(ECDH(platformPriv, authenticatorPub).x)
//   encrypt(key, plaintext) = AES-256-CBC(key, IV = 0^16, plaintext)
//     -- no PKCS#7 padding; CTAP2 v1 only ever encrypts inputs that
//        are already multiples of 16 bytes (pinHash is 16, salts are
//        32 or 64).
//   decrypt(key, ct)        = AES-256-CBC^-1(key, IV = 0^16, ct)
//   authenticate(key, msg)  = LEFT(HMAC-SHA-256(key, msg), 16)
//
// `pinUvAuthParam` (sent on makeCredential / getAssertion) is
// `LEFT(HMAC-SHA-256(pinToken, clientDataHash), 16)`.

import Foundation
import CryptoKit
import CommonCrypto

enum PINProtocolError: LocalizedError {
    case aesFailed(Int32)
    case sharedSecretDeriveFailed(String)
    var errorDescription: String? {
        switch self {
        case .aesFailed(let s):    return "AES-CBC failed (CCCryptorStatus \(s))"
        case .sharedSecretDeriveFailed(let m): return "PIN protocol shared-secret derivation failed: \(m)"
        }
    }
}

enum PINProtocolV1 {

    /// Derive the CTAP2 PIN-protocol-v1 shared secret. Caller supplies
    /// the platform ECDH private key (P-256) and the authenticator's
    /// keyAgreement public key (parsed from the COSE_Key returned by
    /// `authenticatorClientPIN.getKeyAgreement`).
    static func sharedSecret(
        platformPriv: P256.KeyAgreement.PrivateKey,
        authenticatorPub: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret = try platformPriv.sharedSecretFromKeyAgreement(with: authenticatorPub)
        // SharedSecret.withUnsafeBytes yields the 32-byte x-coordinate
        // of the shared ECDH point. CTAP2 v1 hashes that with SHA-256
        // and uses the digest as the symmetric key.
        let raw = secret.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: raw))
    }

    /// AES-256-CBC with IV=0^16 and no padding. Both input length and
    /// output length must be multiples of 16; the caller is
    /// responsible for the size guarantee (CTAP2 always passes 16,
    /// 32, or 64).
    static func encrypt(key: Data, plaintext: Data) throws -> Data {
        try cbc(operation: CCOperation(kCCEncrypt), key: key, input: plaintext)
    }

    static func decrypt(key: Data, ciphertext: Data) throws -> Data {
        try cbc(operation: CCOperation(kCCDecrypt), key: key, input: ciphertext)
    }

    private static func cbc(operation: CCOperation, key: Data, input: Data) throws -> Data {
        precondition(key.count == 32, "PIN protocol v1 key must be 32 bytes")
        precondition(input.count % 16 == 0, "PIN protocol v1 input must be a multiple of 16")
        var output = Data(count: input.count)
        var moved = 0
        let iv = Data(count: 16) // 16 zero bytes
        let keyCount = key.count
        let inputCount = input.count
        let outputCount = output.count
        let status = key.withUnsafeBytes { keyPtr -> Int32 in
            iv.withUnsafeBytes { ivPtr -> Int32 in
                input.withUnsafeBytes { inPtr -> Int32 in
                    output.withUnsafeMutableBytes { outPtr -> Int32 in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // CBC default, no padding
                            keyPtr.baseAddress, keyCount,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, inputCount,
                            outPtr.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PINProtocolError.aesFailed(status)
        }
        return output.prefix(moved)
    }

    /// `pinUvAuthParam` style HMAC: `LEFT(HMAC-SHA-256(key, msg), 16)`.
    static func authenticate(key: Data, message: Data) -> Data {
        let full = Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        ))
        return full.prefix(16)
    }

    /// Full 32-byte HMAC, used as the `saltAuth` for the hmac-secret
    /// extension (per CTAP2 v2 hmac-secret saltAuth is full HMAC; the
    /// extension layer applies its own truncation if needed).
    static func hmacFull(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        ))
    }
}
