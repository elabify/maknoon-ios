// SecondFactorWrap is the iOS port of the ADR-0032 second-factor wrap,
// byte-identical to Android's SecondFactorWrap.kt / SecondFactorSignature.kt.
//
// One random 32-byte CEK (content encryption key) seals the 32-byte
// BIP39 entropy ONCE (sealedEntropy). Each enrolled hardware key stores
// only a small wrappedCEK: the same CEK re-encrypted under a key derived
// from that device's deterministic secret. Any one enrolled key unlocks
// (OR), and add/remove touches a single device's wrappedCEK.
//
// Per-device secret:
//   - YubiKey: the 32-byte FIDO2 hmac-secret output (see YubiKeyClient,
//     clientDataHash = SHA256("maknoon-wrap-v1" || deviceSalt || serial)).
//   - Ledger / Trezor: SHA256 of a deterministic EIP-191 personal-sign
//     over the 50-byte challenge ("maknoon-2fa-sig-v1" || deviceSalt).
//
// Crypto contract (must stay identical to Android):
//   wrapKey = HKDF-SHA256(ikm=secret, salt=deviceSalt,
//                         info="maknoon-2fa-wrap-v2", len=32)
//   every GCM blob = nonce(12) || ciphertext || tag(16), hex-encoded, no AAD.
//
// The wrap is local-at-rest only; it is NOT carried in the encrypted
// backup. Lost devices: restore from the password-protected backup
// (which has the entropy) re-creates the wallet with 2FA off; the user
// re-enrolls keys.

import Foundation
import CryptoKit

enum SecondFactorWrapError: LocalizedError {
    case badHex(String)
    case sealFailed(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .badHex(let m):    return "Malformed wrap data: \(m)."
        case .sealFailed(let m): return "Could not seal the wrap: \(m)."
        case .openFailed(let m): return "Could not open the wrap: \(m)."
        }
    }
}

enum SecondFactorWrap {

    /// HKDF info tag. Byte-identical to Android (SecondFactorWrap.kt).
    static let hkdfInfo = "maknoon-2fa-wrap-v2"

    /// The wrap protocol version stored on a device's promotion. v2 is
    /// the CEK scheme; nil/absent means a legacy (pre-CEK) enrollment.
    static let protocolVersion = 2

    // MARK: -- key + salt generation

    static func newCek() -> Data { randomBytes(32) }
    static func newDeviceSalt() -> Data { randomBytes(32) }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: -- entropy sealed once under the CEK

    /// sealedEntropy = AES-256-GCM(CEK, entropy). Returns nonce||ct||tag hex.
    static func sealEntropy(_ entropy: Data, cek: Data) throws -> String {
        try gcmSealHex(plaintext: entropy, key: SymmetricKey(data: cek))
    }

    static func openEntropy(_ hex: String, cek: Data) throws -> Data {
        try gcmOpen(hex: hex, key: SymmetricKey(data: cek))
    }

    // MARK: -- per-device CEK wrap

    /// wrappedCEK = AES-256-GCM(wrapKey, CEK). Returns nonce||ct||tag hex.
    static func wrapCek(_ cek: Data, secret: Data, deviceSalt: Data) throws -> String {
        let key = deriveWrapKey(secret: secret, deviceSalt: deviceSalt)
        return try gcmSealHex(plaintext: cek, key: key)
    }

    static func unwrapCek(_ hex: String, secret: Data, deviceSalt: Data) throws -> Data {
        let key = deriveWrapKey(secret: secret, deviceSalt: deviceSalt)
        return try gcmOpen(hex: hex, key: key)
    }

    /// HKDF-SHA256(ikm=secret, salt=deviceSalt, info="maknoon-2fa-wrap-v2", len=32).
    static func deriveWrapKey(secret: Data, deviceSalt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: deviceSalt,
            info: Data(hkdfInfo.utf8),
            outputByteCount: 32
        )
    }

    // MARK: -- GCM helpers (nonce(12) || ct || tag(16), hex)

    private static func gcmSealHex(plaintext: Data, key: SymmetricKey) throws -> String {
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                throw SecondFactorWrapError.sealFailed("nil combined output")
            }
            return combined.hexString
        } catch let e as SecondFactorWrapError {
            throw e
        } catch {
            throw SecondFactorWrapError.sealFailed("\(error)")
        }
    }

    private static func gcmOpen(hex: String, key: SymmetricKey) throws -> Data {
        guard let blob = Data(hexString: hex) else {
            throw SecondFactorWrapError.badHex("not hex")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SecondFactorWrapError.openFailed(Self.humanize(error))
        }
    }

    /// Map CryptoKit's terse case names to readable text. The most
    /// common failure here is the wrong / foreign device: its derived
    /// wrap key fails the GCM tag, which is the fail-closed OR signal.
    private static func humanize(_ error: Error) -> String {
        if let e = error as? CryptoKit.CryptoKitError {
            switch e {
            case .authenticationFailure:
                return "wrap key did not match (wrong device, or its secret changed since enrollment)"
            case .incorrectKeySize:    return "wrap key was the wrong size"
            case .incorrectParameterSize: return "wrap parameter was the wrong size"
            default:                   return "\(error)"
            }
        }
        return "\(error)"
    }
}

/// Ledger / Trezor deterministic-signature secret. Kept byte-identical
/// to Android's SecondFactorSignature.kt (iOS is the reference; Android
/// mirrors it).
///
/// The signed message is a short, human-readable, all-ASCII string so
/// the hardware device shows plain text ("Maknoon second factor ID:
/// <8 hex>") instead of an opaque hex blob the user is trained to
/// refuse. The 8-hex ID is the first 4 bytes of the deviceSalt, so each
/// enrollment signs a distinct message (a captured signature can't be
/// reused for a different enrollment) while staying short enough for a
/// Ledger screen. The FULL deviceSalt still binds the wrap key via the
/// HKDF salt, so the per-device key is unique per full salt regardless.
/// IDENTICAL at enroll and unlock for a given deviceSalt (so the
/// deterministic signature, and thus the secret, reproduces).
///
/// Changing this string invalidates existing enrollments (the secret
/// differs), so any change MUST be paired with a remove + re-enroll on
/// BOTH platforms.
enum SecondFactorSignature {
    static let messagePrefix = "Maknoon second factor ID: "

    /// The message a Ledger/Trezor signs. EIP-191 personal_sign prepends
    /// its own `\x19Ethereum Signed Message:\n<len>`; this text follows.
    static func challenge(deviceSalt: Data) -> Data {
        let idHex = deviceSalt.prefix(4).map { String(format: "%02x", $0) }.joined()
        return Data("\(messagePrefix)\(idHex)".utf8)
    }

    /// secret = SHA256(rawSignature) of the signed challenge.
    static func secret(fromSignature signature: Data) -> Data {
        Data(SHA256.hash(data: signature))
    }
}

// MARK: -- hex helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let s = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}

#if DEBUG
extension SecondFactorWrap {
    /// Known-answer check that the deterministic pieces match the
    /// cross-platform Android vectors. Run once at first enroll/unlock in
    /// DEBUG so a divergence shows up immediately, before any UI wiring is
    /// trusted. Vectors generated from the documented contract (RFC5869
    /// HKDF-SHA256 + SHA256), see plan KATs.
    static func runParitySelfTest() {
        let secret = Data((1...32).map { UInt8($0) })          // 01..20
        let deviceSalt = Data(repeating: 0xAA, count: 32)
        let wrapKey = deriveWrapKey(secret: secret, deviceSalt: deviceSalt)
        let wrapKeyHex = wrapKey.withUnsafeBytes { Data($0).hexString }
        let expectedWrapKey = "73023f92cdaeec09fcb4cb48b4e89a4bdd676cf4466c58d2cf163842d8dc05a0"

        let sig = Data((0..<16).flatMap { _ in [UInt8(0x11), 0x22, 0x33, 0x44] })
        let sigSecret = SecondFactorSignature.secret(fromSignature: sig).hexString
        let expectedSigSecret = "1dd64e350367959448a7ff0fdea906cdd029b07f8949859f9b1f71cf01a3467f"

        // Readable challenge: "Maknoon second factor ID: <8 hex>" (first
        // 4 bytes of the salt). Must match Android byte-for-byte.
        let challengeText = String(data: SecondFactorSignature.challenge(deviceSalt: deviceSalt), encoding: .utf8) ?? ""
        let challengeOk = challengeText == "Maknoon second factor ID: aaaaaaaa"

        // GCM round-trip (random nonce, so check correctness not bytes).
        var roundTripOk = false
        if let cek = Optional(newCek()),
           let sealed = try? sealEntropy(deviceSalt, cek: cek),
           let opened = try? openEntropy(sealed, cek: cek) {
            roundTripOk = opened == deviceSalt
        }

        let pass = wrapKeyHex == expectedWrapKey
            && sigSecret == expectedSigSecret
            && challengeOk
            && roundTripOk
        if pass {
            LogStore.shared.info("SecondFactorWrap", "parity self-test PASSED")
        } else {
            LogStore.shared.error("SecondFactorWrap",
                "parity self-test FAILED: wrapKey=\(wrapKeyHex) sig=\(sigSecret) challengeOk=\(challengeOk) roundTrip=\(roundTripOk)")
            assertionFailure("SecondFactorWrap parity self-test failed; crypto diverged from Android")
        }
    }
}
#endif
