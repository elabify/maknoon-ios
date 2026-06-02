// HPKE session helpers for the BLE transport. Wraps iOS 26 CryptoKit's
// `HPKE.Sender` / `HPKE.Recipient` with `XWingMLKEM768X25519` (hybrid
// post-quantum + classical KEM).
//
// Ciphersuite: `XWingMLKEM768X25519_SHA256_AES_GCM_256`.
// Phase 0.1 single-shot: holder seals the whole Presentation in one
// `seal()` call. Future revisions chunk for larger payloads.

import CryptoKit
import Foundation

enum TransportSessionError: Error, CustomStringConvertible {
    case keyDecodeFailed
    case sealFailed(String)
    case openFailed(String)

    var description: String {
        switch self {
        case .keyDecodeFailed:   return "Could not decode HPKE public key"
        case .sealFailed(let m): return "HPKE seal failed: \(m)"
        case .openFailed(let m): return "HPKE open failed: \(m)"
        }
    }
}

enum TransportCiphersuite {
    /// Single Phase 0.1 ciphersuite.
    static let value: HPKE.Ciphersuite = .XWingMLKEM768X25519_SHA256_AES_GCM_256
    static let kem: HPKE.KEM = .XWingMLKEM768X25519

    /// `info` parameter that binds the HPKE context to the engagement
    /// (sessionId + serviceUuid). Same bytes on both sides; mismatch
    /// fails AEAD decryption at the receiver.
    static func info(sessionId: String, serviceUuid: String) -> Data {
        let s = "\(TransportEngagement.version)|\(sessionId)|\(serviceUuid)"
        return Data(s.utf8)
    }
}

/// Holder-side. Generates a fresh X-Wing keypair, publishes the
/// public key, and creates the matching HPKE recipient once the
/// verifier has written its encapsulated key.
struct TransportHolder {
    let privateKey: XWingMLKEM768X25519.PrivateKey
    let publicKey: XWingMLKEM768X25519.PublicKey

    init() throws {
        let sk = try XWingMLKEM768X25519.PrivateKey.generate()
        self.privateKey = sk
        self.publicKey = sk.publicKey
    }

    /// Base64 of the X-Wing public key. ~1216 bytes binary → ~1620
    /// chars base64. Goes into the engagement QR.
    var publicKeyBase64: String {
        return publicKey.rawRepresentation.base64EncodedString()
    }

    /// Decap the verifier's encapsulated key + open the HPKE context.
    func makeRecipient(
        encapsulatedKey: Data,
        sessionId: String,
        serviceUuid: String
    ) throws -> HPKE.Recipient {
        do {
            return try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: TransportCiphersuite.value,
                info: TransportCiphersuite.info(sessionId: sessionId, serviceUuid: serviceUuid),
                encapsulatedKey: encapsulatedKey
            )
        } catch {
            throw TransportSessionError.openFailed("HPKE.Recipient init: \(error)")
        }
    }
}

/// Verifier-side. Encapsulates against the holder's engagement public
/// key + returns the HPKE sender plus the `encapsulatedKey` bytes
/// that need to be written to the holder's `handshake` GATT
/// characteristic.
enum TransportVerifier {
    static func makeSender(
        holderPublicKeyBase64: String,
        sessionId: String,
        serviceUuid: String
    ) throws -> (sender: HPKE.Sender, encapsulatedKey: Data) {
        guard let raw = Data(base64Encoded: holderPublicKeyBase64) else {
            throw TransportSessionError.keyDecodeFailed
        }
        let key: XWingMLKEM768X25519.PublicKey
        do {
            key = try XWingMLKEM768X25519.PublicKey(rawRepresentation: raw)
        } catch {
            throw TransportSessionError.keyDecodeFailed
        }
        do {
            let sender = try HPKE.Sender(
                recipientKey: key,
                ciphersuite: TransportCiphersuite.value,
                info: TransportCiphersuite.info(sessionId: sessionId, serviceUuid: serviceUuid)
            )
            return (sender, sender.encapsulatedKey)
        } catch {
            throw TransportSessionError.sealFailed("HPKE.Sender init: \(error)")
        }
    }
}
