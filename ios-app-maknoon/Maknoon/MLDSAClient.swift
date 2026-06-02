// CryptoKit ML-DSA-65 wrappers used by the Identity Sandwich.
//
// Two key flavours:
//
//   * **Master** (`MLDSA65.PrivateKey`): software, deterministic from a
//     32-byte seed. Lives in Keychain (biometric-gated). We reconstruct
//     it briefly when we need to sign a delegation cert, sign, and let
//     Swift zero the local binding on scope exit.
//
//   * **Ephemeral** (`SecureEnclave.MLDSA65.PrivateKey`): hardware-
//     resident, private bits never leave the SE. We persist its
//     `dataRepresentation` (an opaque, encrypted handle, not the
//     private bits) in Keychain and reconstruct an in-memory handle
//     each time we sign.
//
// Apple's CryptoKit MLDSA65 API (verified against the iOS 26.5 SDK):
//   - `MLDSA65.PrivateKey()` throws on entropy failure.
//   - The compact software-private-key serialization is
//     `seedRepresentation` (32 bytes); reconstruct via
//     `MLDSA65.PrivateKey(seedRepresentation:publicKey:)`.
//   - `MLDSA65.PublicKey.rawRepresentation` is the on-the-wire pubkey.
//   - `SecureEnclave.MLDSA65.PrivateKey.init(accessControl:)` generates
//     the hardware key. The matching reconstruct is
//     `init(dataRepresentation:)`.

import Foundation
import CryptoKit
import LocalAuthentication
import Security

enum MLDSAClient {

    // MARK: -- Software master (deterministic from 32-byte seed)

    /// Generate a fresh ML-DSA-65 master keypair plus the seed needed
    /// to reconstruct it. Returns (publicKey, seed) where seed is the
    /// 32-byte entropy that the BIP39 mnemonic encodes.
    static func generateMaster() throws -> (publicKey: Data, seed: Data) {
        let pk = try MLDSA65.PrivateKey()
        return (pk.publicKey.rawRepresentation, pk.seedRepresentation)
    }

    /// Reconstruct a master public key from a 32-byte seed without
    /// holding the secret beyond the function scope.
    static func masterPublicKey(fromSeed seed: Data) throws -> Data {
        let pk = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        return pk.publicKey.rawRepresentation
    }

    /// Sign `message` with the master derived from `seed`. The master
    /// only exists for the duration of this call. Used to sign the
    /// delegation cert at onboarding and on every 24h renewal.
    static func signWithMaster(seed: Data, message: Data) throws -> Data {
        let key = try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil)
        return try key.signature(for: message)
    }

    // MARK: -- Secure-Enclave ephemeral

    /// Generate a new ML-DSA-65 keypair inside the Secure Enclave and
    /// return both the public key (raw bytes) and the opaque key
    /// handle (`dataRepresentation`) that lets us re-open the key on
    /// subsequent launches without ever touching the private bits.
    ///
    /// Access policy: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// (matches Apple's default), no per-sign biometric prompt. We rely
    /// on device unlock as the gate, which matches the daily-use
    /// pattern of presenting a credential without a Face ID interruption.
    ///
    /// Simulator fallback: the iOS Simulator has no Secure Enclave, so
    /// we substitute a software `MLDSA65.PrivateKey` and persist its
    /// 32-byte `seedRepresentation` as the "handle". Sign + reload
    /// re-derive the key from the seed. The banner in ManagedRootView
    /// keeps this visually distinct from production builds. Guarded by
    /// `#if targetEnvironment(simulator)` so the code path is excluded
    /// at compile time on real devices.
    static func generateEphemeralSE() throws -> (publicKey: Data, handle: Data) {
        #if targetEnvironment(simulator)
        let key = try MLDSA65.PrivateKey()
        return (key.publicKey.rawRepresentation, key.seedRepresentation)
        #else
        var sacError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [],
            &sacError
        ) else {
            let err = sacError?.takeRetainedValue()
            throw NSError(
                domain: "MLDSAClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SecAccessControl create failed: \(String(describing: err))"]
            )
        }
        let key = try SecureEnclave.MLDSA65.PrivateKey(
            accessControl: access,
            authenticationContext: nil
        )
        return (key.publicKey.rawRepresentation, key.dataRepresentation)
        #endif
    }

    /// Sign `message` with the Secure-Enclave-resident key identified by
    /// `handle`. The private bits never leave the SE. The signature comes
    /// back as plain Data over a fast roundtrip (a few ms on the chip
    /// plus IPC).
    ///
    /// On the simulator the "handle" is the 32-byte software seed (see
    /// `generateEphemeralSE`); we reconstruct the software key and sign.
    static func signWithEphemeralSE(handle: Data, message: Data) throws -> Data {
        #if targetEnvironment(simulator)
        let key = try MLDSA65.PrivateKey(seedRepresentation: handle, publicKey: nil)
        return try key.signature(for: message)
        #else
        let key = try SecureEnclave.MLDSA65.PrivateKey(
            dataRepresentation: handle,
            authenticationContext: nil
        )
        return try key.signature(for: message)
        #endif
    }

    /// Convenience: derive the cached public key from a stored SE
    /// handle. Useful when we need to assert that the key handle in
    /// Keychain still matches the cached public-key bytes (a
    /// tamper-detection invariant).
    static func ephemeralSEPublicKey(handle: Data) throws -> Data {
        #if targetEnvironment(simulator)
        let key = try MLDSA65.PrivateKey(seedRepresentation: handle, publicKey: nil)
        return key.publicKey.rawRepresentation
        #else
        let key = try SecureEnclave.MLDSA65.PrivateKey(
            dataRepresentation: handle,
            authenticationContext: nil
        )
        return key.publicKey.rawRepresentation
        #endif
    }

    // MARK: -- Verify (used both ways: holder verifies the issuer's
    // header sig today, and unit tests verify the SE ephemeral did the
    // right thing).

    /// Verify a signature against a public key + message.
    static func verify(publicKey: Data, signature: Data, message: Data) -> Bool {
        do {
            let key = try MLDSA65.PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: message)
        } catch {
            return false
        }
    }

    // MARK: -- Legacy in-memory keypair (transitional)
    //
    // The previous build generated a fresh ML-DSA-65 keypair in RAM on
    // each launch. The Identity Sandwich migration replaces these with
    // the master + SE-ephemeral pair above, and HolderStore +
    // PresentView are rewritten in subsequent steps. Until then these
    // legacy wrappers keep the build green.

    static func generateKeyPair() throws -> (publicKey: Data, privateKey: Data) {
        let (pk, seed) = try generateMaster()
        return (publicKey: pk, privateKey: seed)
    }

    static func sign(privateKey seed: Data, message: Data) throws -> Data {
        return try signWithMaster(seed: seed, message: message)
    }
}
