// Server-blind sealing for Verify & Pay (ADR-0031). The holder seals its
// response to the merchant's ephemeral X-Wing public key (published in the
// request) so the relay server only stores ciphertext. Reuses the BLE
// transport's HPKE (XWingMLKEM768X25519 + AES-256-GCM): here the holder is the
// HPKE *sender* and the merchant is the *recipient* (owns the keypair).

import Foundation

/// What the holder POSTs and the merchant polls, opaque to the server.
struct CommerceSealedEnvelope: Codable, Sendable {
    let requestId: String
    let encapsulatedKey: String  // base64
    let sealed: String           // base64 (HPKE ciphertext)
}

enum CommerceSeal {
    /// `serviceUuid` slot of the HPKE info; fixed for the commerce channel.
    private static let context = "commerce"

    /// Holder: seal a Codable response to the merchant's published pubkey,
    /// binding the HPKE context to the requestId.
    static func seal<T: Encodable>(_ value: T, toPublicKeyBase64 pub: String, requestId: String) throws -> CommerceSealedEnvelope {
        let plaintext = try JSONEncoder().encode(value)
        let made = try TransportVerifier.makeSender(
            holderPublicKeyBase64: pub, sessionId: requestId, serviceUuid: context)
        var sender = made.sender
        let ciphertext = try sender.seal(plaintext)
        return CommerceSealedEnvelope(
            requestId: requestId,
            encapsulatedKey: made.encapsulatedKey.base64EncodedString(),
            sealed: ciphertext.base64EncodedString())
    }

    /// Merchant: open a sealed envelope with the ephemeral keypair it generated.
    static func open<T: Decodable>(_ env: CommerceSealedEnvelope, keypair: TransportHolder, as type: T.Type) throws -> T {
        guard let encKey = Data(base64Encoded: env.encapsulatedKey),
              let ciphertext = Data(base64Encoded: env.sealed) else {
            throw TransportSessionError.keyDecodeFailed
        }
        var recipient = try keypair.makeRecipient(
            encapsulatedKey: encKey, sessionId: env.requestId, serviceUuid: context)
        let plaintext = try recipient.open(ciphertext)
        return try JSONDecoder().decode(type, from: plaintext)
    }
}
