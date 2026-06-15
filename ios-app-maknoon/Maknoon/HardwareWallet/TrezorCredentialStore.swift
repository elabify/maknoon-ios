// Persists the THP host static key (one per app install) and the
// most-recent Trezor reconnection credential. With these, identity
// and signing operations reconnect to a paired Trezor WITHOUT making
// the user re-enter the 6-digit code each time: the handshake replays
// the credential and reaches the encrypted session directly.
//
// Single-device for now (one stored credential). Per-device keying
// for users with multiple Trezors is a follow-up; the credential is
// bound to the host static key, which is why that key is persistent.

import Foundation
import Security

enum TrezorCredentialStore {
    private static let hostKeyId = "trezor.thp.hostkey.v1"
    private static let credentialId = "trezor.thp.credential.v1"

    /// The app's persistent THP host X25519 secret (32 bytes),
    /// created on first use. The reconnection credential is bound to
    /// this key, so it must stay stable across connects.
    static func hostStaticKey() throws -> Data {
        if let existing = try KeyStore.load(forKey: hostKeyId), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HardwareWalletError.transport("could not generate a Trezor host key")
        }
        let data = Data(bytes)
        try KeyStore.save(data, forKey: hostKeyId, requireBiometric: false)
        return data
    }

    static func saveCredential(_ credential: Data) throws {
        try KeyStore.save(credential, forKey: credentialId, requireBiometric: false)
    }

    static func loadCredential() throws -> Data? {
        try KeyStore.load(forKey: credentialId)
    }
}
