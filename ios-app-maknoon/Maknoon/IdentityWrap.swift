// IdentityWrap is the crypto layer for hardware-backed Identity
// Sandwich unlocking. A registered hardware device (Ledger Nano X
// via its Ethereum app's personal_sign APDU, or the Mock device on
// the simulator) deterministically signs a random challenge; we
// HKDF that signature into a 32-byte AES-GCM key, then encrypt the
// existing master material with it.
//
// Originally the plan (per DeviceDetailView footers) was to use
// FIDO2 hmac-secret over BLE. Ledger Nano X's BLE transport doesn't
// actually speak CTAP2 (the "Security Key" app over BLE is FIDO U2F
// /CTAP1 only; CTAP2 is USB-HID via Ledger Live). personal_sign is
// the substitute: same deterministic-per-(device, message) property
// because Ledger uses RFC6979 nonces. The Ethereum app's APDU
// (CLA=0xE0 INS=0x08) is already implemented over our BLE transport.
//
// Security boundary: the wrap key never exists in iOS Keychain. The
// only persistent state is (a) the AES-GCM-sealed master material
// and (b) the salt + device identifier needed to reconstruct the
// wrap key on demand. Unlocking the sandwich therefore requires
// physical access to the registered Ledger AND iOS device unlock.
// Face ID is intentionally NOT a second gate on the sealed item:
// the hardware button is the stronger factor.

import Foundation
import CryptoKit

enum IdentityWrapError: LocalizedError {
    case signatureTooShort(Int)
    case sealFailed(String)
    case openFailed(String)
    case deviceSerialMismatch(expected: String, actual: String)
    var errorDescription: String? {
        switch self {
        case .signatureTooShort(let n):
            return "Hardware-wallet wrap signature was \(n) bytes; need at least 32."
        case .sealFailed(let m):
            return "Could not seal master material: \(m)"
        case .openFailed(let m):
            // Stay device-agnostic: this error fires for any hardware
            // device whose wrap key didn't match. The "different
            // device" hypothesis is also separately surfaced by
            // `deviceSerialMismatch`, so we don't repeat it here.
            return "Could not unseal master material: \(m)."
        case .deviceSerialMismatch(let exp, let act):
            return "Identity Sandwich is locked by a different device (expected \(exp), connected \(act))."
        }
    }
}

/// Map CryptoKit's terse enum-case-name `description` (e.g.
/// `authenticationFailure`) into something a human can read. Falls
/// through to the underlying error description otherwise. Used at
/// the call site that catches `AES.GCM.open` failures inside the
/// wrap path so the user doesn't see camelCase noise.
func humanReadableWrapError(_ error: Error) -> String {
    if let cryptoErr = error as? CryptoKit.CryptoKitError {
        switch cryptoErr {
        case .authenticationFailure:
            return "wrap key did not match (wrong device, or device signature drifted since enrollment)"
        case .incorrectKeySize:
            return "wrap key was the wrong size"
        case .incorrectParameterSize:
            return "wrap parameter was the wrong size"
        case .underlyingCoreCryptoError(let code):
            return "internal Crypto error (\(code))"
        case .wrapFailure:
            return "wrap failure"
        case .unwrapFailure:
            return "unwrap failure"
        @unknown default:
            return "Crypto error: \(error)"
        }
    }
    return "\(error)"
}

/// One device's wrap of the master material. The same plaintext
/// MasterMaterialPersisted JSON is sealed once per enrolled device,
/// each with its own random salt and its own device-derived key.
/// Any one of these blobs is sufficient to recover the plain
/// material — they're OR-equivalents, not threshold shares.
struct WrappedMaterialPersisted: Codable, Hashable, Identifiable {
    let deviceId: UUID
    let deviceSerial: String
    /// Random 32-byte HKDF salt, generated at wrap time.
    let salt: Data
    /// AES-256-GCM combined output: nonce (12B) || ciphertext || tag (16B).
    let sealedBox: Data
    let wrappedAt: Date

    var id: UUID { deviceId }
}

/// Versioned envelope holding every enrolled device's wrap. Persisted
/// at `KeyStoreKeys.wrappedMasterMaterial`. Storing all devices under
/// one Keychain item keeps the "are we wrapped?" check a single
/// read; the list shape lets any device unlock without a primary /
/// backup hierarchy.
struct WrapEnvelope: Codable {
    /// Schema version. v1 was the single-blob shape (decoded via
    /// `WrappedMaterialPersisted` directly); v2 is this envelope.
    let v: Int
    let blobs: [WrappedMaterialPersisted]

    static let currentVersion = 2

    init(blobs: [WrappedMaterialPersisted]) {
        self.v = Self.currentVersion
        self.blobs = blobs
    }
}

enum IdentityWrap {

    /// Domain-separation prefix included in the signed challenge so
    /// a signature collected here can never collide with a chain-tx
    /// signature. EIP-191 personal_sign prepends its own prefix
    /// (`\x19Ethereum Signed Message:\n<len>`); this string then
    /// goes after that.
    static let challengePrefix = "Maknoon wrap "

    /// Build the message a hardware device should sign for a wrap
    /// promotion.
    ///
    /// Earlier versions of this code put the raw salt + device
    /// serial into the signed message. The result was a ~150-char
    /// string that took the user 15+ right-button presses to scroll
    /// through on a Ledger Nano X, and frequently timed out before
    /// they got to "Approve" — surfacing as "device disconnected"
    /// on the iPhone.
    ///
    /// This version hashes (prefix, salt, deviceSerial) into a 32
    /// -byte SHA-256 digest and displays only the hex. The message
    /// Ledger shows is ~77 ASCII chars, fits on 2 screens, ~5 button
    /// presses to approve. Same security property: signature is
    /// deterministically bound to (salt, serial) via the hash, so
    /// captured signatures from one promotion can't be replayed
    /// against a different one.
    static func challenge(salt: Data, deviceSerial: String) -> Data {
        var input = Data()
        input.append(Data(challengePrefix.utf8))
        input.append(salt)
        input.append(Data(deviceSerial.utf8))
        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Data("\(challengePrefix)\(hex)".utf8)
    }

    /// HKDF-SHA256 derive a 32-byte AES key from the hardware
    /// signature. Salt is the same random value persisted with the
    /// wrapped blob; info string carries the version tag so a future
    /// rotation (e.g. switching from personal_sign to FIDO2 hmac
    /// -secret) can rederive cleanly without re-prompting the device.
    static func deriveWrapKey(signature: Data, salt: Data) throws -> SymmetricKey {
        guard signature.count >= 32 else {
            throw IdentityWrapError.signatureTooShort(signature.count)
        }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: signature), salt: salt)
        let key = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("maknoon-identity-wrap-v1".utf8),
            outputByteCount: 32
        )
        return SymmetricKey(data: key)
    }

    /// AES-256-GCM encrypt the plain `MasterMaterialPersisted` bytes
    /// and produce the persistable blob. Device serial goes into
    /// `authenticatedData` so opening a blob with a different
    /// device's reported serial fails verification at the GCM tag.
    static func seal(plaintext: Data, key: SymmetricKey, deviceSerial: String) throws -> Data {
        do {
            let nonce = AES.GCM.Nonce()
            let box = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: Data(deviceSerial.utf8)
            )
            guard let combined = box.combined else {
                throw IdentityWrapError.sealFailed("AES.GCM.SealedBox returned nil combined output")
            }
            return combined
        } catch let e as IdentityWrapError {
            throw e
        } catch {
            throw IdentityWrapError.sealFailed("\(error)")
        }
    }

    /// AES-256-GCM decrypt. Throws `openFailed` for tag mismatch
    /// (most likely cause: wrong device, wrong key derivation, or
    /// corrupted blob).
    static func open(sealedBox: Data, key: SymmetricKey, deviceSerial: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealedBox)
            return try AES.GCM.open(
                box,
                using: key,
                authenticating: Data(deviceSerial.utf8)
            )
        } catch {
            throw IdentityWrapError.openFailed(humanReadableWrapError(error))
        }
    }
}
