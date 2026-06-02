// IdentitySandwich is the loaded state of the holder's identity:
// a master ML-DSA-65 key (derived BIP39-standard from 24-word mnemonic
// entropy plus an optional passphrase), a Secure Enclave ephemeral
// keypair (handle in Keychain), and the current delegation cert
// linking the two.
//
// Master derivation is BIP39-standard per BIP-0039 §6:
//
//   bip39_seed = PBKDF2-HMAC-SHA512(mnemonic, "mnemonic" + passphrase,
//                                   c=2048, dkLen=64)
//   mldsa_seed = bip39_seed[0..32]
//   master_key = MLDSA65.PrivateKey(seedRepresentation: mldsa_seed)
//
// Same 24 words plus different passphrases give different wallets;
// this is the standard "25th word" / plausible-deniability pattern.
// Empty passphrase ("") is the no-passphrase case.
//
// Lifecycle:
//
//   * `generateFresh(passphrase:)` — pick fresh 32 bytes of entropy,
//     derive master, create ephemeral, sign first delegation, persist.
//   * `restoreFromMnemonic(words:passphrase:)` — rebuild master from a
//     paper / iCloud-restored 24-word phrase plus passphrase.
//   * `loadFromKeychain()` — reattach on subsequent launches.
//   * `renewIfExpiring(now:)` — refresh delegation when within an hour
//     of expiry.
//   * `signChallenge(_:)` — sign with the SE ephemeral, fast path.
//
// All cert canonicalization routes through ElabifyCore.canonicalize()
// from the Swift binding, which is KAT-proven byte-identical with the
// TS canonicalize the verifier server uses.

import Foundation
import CryptoKit
import ElabifyCore

// MARK: -- Wire format

/// Delegation cert, stored locally and embedded in every presentation.
/// Matches ADR-0005's shape verbatim.
struct DelegationCert: Codable, Equatable {
    /// Hex of the SE ephemeral public key, with `0x` prefix.
    let ephemeralPk: String
    let validFrom: Int64
    let validUntil: Int64
    let scope: [String]
    /// Hex of the master's ML-DSA-65 signature over the canonicalized
    /// inner cert (everything but `delegationSig`).
    let delegationSig: String
}

/// Recovery material: BIP39 entropy + passphrase + the derived 24
/// words. Returned by `IdentitySandwich.recoveryMaterial()` after a
/// Face-ID-gated Keychain read. Holds the secrets only as long as the
/// view that requested them needs them.
struct MasterRecoveryMaterial {
    let entropy: Data
    let passphrase: String
    var words: [String] { BIP39.mnemonicFromSeed(entropy) }
    var hasPassphrase: Bool { !passphrase.isEmpty }
}

/// Default cert lifetime, 24 hours.
private let defaultValidityWindowSec: Int64 = 24 * 3600

/// Renewal trigger: refresh once the cert is within 1 hour of `validUntil`.
private let renewalLeadTimeSec: Int64 = 3600

/// Permitted scope strings for the demo. Verifier reads `scope`
/// case-sensitively; keep this list in sync with the verifier's
/// `verifyDelegation` accepted-scopes set.
private let presentationScope: [String] = ["verify"]

// MARK: -- IdentitySandwich

@Observable
final class IdentitySandwich {
    /// Master public key, raw bytes (1952 bytes for ML-DSA-65).
    let masterPublicKey: Data

    /// Cached ephemeral public key, raw bytes.
    let ephemeralPublicKey: Data

    /// SE key handle, opaque, ~88 bytes. Persisted to Keychain.
    let ephemeralKeyHandle: Data

    /// Currently-stored delegation cert.
    private(set) var delegation: DelegationCert

    /// In-session cache of master entropy + passphrase. Populated at
    /// fresh-onboarding / mnemonic-restore time and at hardware
    /// unlock time. Used by `recoveryMaterial(localizedReason:)` so
    /// in-session ops (encrypted backup, reveal phrase, delegation
    /// renewal) keep working after the first hardware enrollment,
    /// which deletes the plain biometric Keychain item as a defense-
    /// in-depth measure against jailbreak-with-Face-ID attackers.
    /// Cache lives only for the duration of the loaded sandwich;
    /// cold launches re-route through HardwareUnlockView per the
    /// wrap envelope and repopulate via `loadWrappedWithSecret`.
    private var sessionMaterial: MasterRecoveryMaterial?

    /// did:elabify-style holder DID derived from the master pubkey.
    /// Stable across renewals, across passphrase-aware recovery on a
    /// new device, and across the BIP39 entropy + passphrase pair.
    var holderDID: String {
        let user = ElabifyCore.rpo256Tagged(0x03, masterPublicKey)
        let prefix = user.prefix(20)
        let hex = prefix.map { String(format: "%02x", $0) }.joined()
        return "did:elabify:sepolia:holder:0x" + hex
    }

    private init(
        masterPublicKey: Data,
        ephemeralPublicKey: Data,
        ephemeralKeyHandle: Data,
        delegation: DelegationCert
    ) {
        self.masterPublicKey = masterPublicKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ephemeralKeyHandle = ephemeralKeyHandle
        self.delegation = delegation
    }

    // MARK: -- factories

    /// Generate a brand-new identity with a fresh 32 bytes of BIP39
    /// entropy and the supplied (possibly empty) passphrase. Returns
    /// the entropy so the onboarding view can encode it as 24 words
    /// for paper backup. The passphrase is NOT returned (the view
    /// already has it locally and can stash via showPassphraseAfter
    /// if desired).
    static func generateFresh(passphrase: String) throws -> (sandwich: IdentitySandwich, entropy: Data) {
        var entropyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &entropyBytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "IdentitySandwich",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed: \(status)"]
            )
        }
        let entropy = Data(entropyBytes)
        let sandwich = try buildAndPersist(entropy: entropy, passphrase: passphrase)
        return (sandwich, entropy)
    }

    /// Recover a known identity from its 24-word BIP39 mnemonic plus
    /// passphrase. Decodes the words back to 32 bytes of entropy then
    /// re-derives the master via the standard BIP39 path.
    static func restoreFromMnemonic(words: [String], passphrase: String) throws -> IdentitySandwich {
        let entropy = try BIP39.seedFromMnemonic(words)
        return try buildAndPersist(entropy: entropy, passphrase: passphrase)
    }

    /// Recover from raw 32-byte entropy (used by the iCloud restore
    /// path which already has the decrypted entropy in hand).
    static func restoreFromEntropy(_ entropy: Data, passphrase: String) throws -> IdentitySandwich {
        return try buildAndPersist(entropy: entropy, passphrase: passphrase)
    }

    /// Three-state result of attempting to load a sandwich from
    /// Keychain. `notProvisioned` routes to OnboardingView;
    /// `loaded` proceeds to the wallet; `wrappedAwaitingHardware`
    /// carries every enrolled device's wrap so the unlock UI can
    /// let the user pick whichever device is at hand.
    enum LoadResult {
        case notProvisioned
        case loaded(IdentitySandwich)
        case wrappedAwaitingHardware([WrappedMaterialPersisted])
    }

    /// Read the current wrap envelope from Keychain, if any. Handles
    /// the v1 single-blob legacy shape transparently so devices that
    /// promoted under Phase 2.25 don't break when this code lands.
    static func loadWrapEnvelope() throws -> WrapEnvelope? {
        guard let data = try KeyStore.load(forKey: KeyStoreKeys.wrappedMasterMaterial)
        else { return nil }
        if let env = try? JSONDecoder().decode(WrapEnvelope.self, from: data) {
            return env
        }
        // v1 fallback: the item was a single WrappedMaterialPersisted
        // before the envelope existed. Wrap it into a fresh v2
        // envelope but DON'T persist yet — the next promotion /
        // demotion call will rewrite under the new shape naturally.
        if let single = try? JSONDecoder().decode(WrappedMaterialPersisted.self, from: data) {
            return WrapEnvelope(blobs: [single])
        }
        return nil
    }

    private static func saveWrapEnvelope(_ env: WrapEnvelope) throws {
        let blob = try JSONEncoder().encode(env)
        try KeyStore.save(blob, forKey: KeyStoreKeys.wrappedMasterMaterial, requireBiometric: false)
    }

    /// Reload an existing sandwich from Keychain. Returns
    /// `.wrappedAwaitingHardware` if the material is sealed by one
    /// or more hardware devices; the caller drives the unlock UI
    /// and then calls `loadWrapped(...)` once a device produced its
    /// signature.
    static func loadFromKeychain() throws -> LoadResult {
        guard
            let _masterPk = try KeyStore.load(forKey: KeyStoreKeys.masterPublicKey),
            let _handle   = try KeyStore.load(forKey: KeyStoreKeys.ephemeralKeyHandle),
            let _ephPk    = try KeyStore.load(forKey: KeyStoreKeys.ephemeralPublicKey),
            let _certData = try KeyStore.load(forKey: KeyStoreKeys.delegationCert)
        else {
            return .notProvisioned
        }
        if let env = try loadWrapEnvelope(), !env.blobs.isEmpty {
            // Hardware-locked: launcher must drive the unlock UI.
            // We don't construct a sandwich here because we don't
            // have the plain master material until a device signs.
            return .wrappedAwaitingHardware(env.blobs)
        }
        let cert = try JSONDecoder().decode(DelegationCert.self, from: _certData)
        return .loaded(IdentitySandwich(
            masterPublicKey: _masterPk,
            ephemeralPublicKey: _ephPk,
            ephemeralKeyHandle: _handle,
            delegation: cert
        ))
    }

    /// Open a wrapped sandwich using whichever device the user
    /// connected. Picks the matching wrap blob by deviceId, then
    /// verifies the connected serial matches what was recorded at
    /// enrollment time.
    static func loadWrapped(
        enrollments: [WrappedMaterialPersisted],
        device: RegisteredDevice,
        hardware: HardwareWallet
    ) async throws -> IdentitySandwich {
        guard let wrapped = enrollments.first(where: { $0.deviceId == device.id }) else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: enrollments.map { $0.deviceSerial }.joined(separator: " or "),
                actual: device.serial
            )
        }
        guard device.serial == wrapped.deviceSerial else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: wrapped.deviceSerial,
                actual: device.serial
            )
        }
        let challenge = IdentityWrap.challenge(salt: wrapped.salt, deviceSerial: wrapped.deviceSerial)
        let signature = try await hardware.signMessage(challenge)
        let key = try IdentityWrap.deriveWrapKey(signature: signature, salt: wrapped.salt)
        let plaintext = try IdentityWrap.open(
            sealedBox: wrapped.sealedBox,
            key: key,
            deviceSerial: wrapped.deviceSerial
        )
        // Persist the unwrapped material back to the biometric
        // Keychain slot so in-session ops (delegation renewal,
        // recovery-phrase reveal, iCloud backup, AND enrolling
        // another device) don't need a fresh hardware tap. Cold
        // launches still go through the wrap because loadFromKeychain
        // checks the envelope before yielding the biometric slot.
        try KeyStore.save(plaintext, forKey: KeyStoreKeys.masterMaterial, requireBiometric: true)

        guard
            let masterPk = try KeyStore.load(forKey: KeyStoreKeys.masterPublicKey),
            let handle   = try KeyStore.load(forKey: KeyStoreKeys.ephemeralKeyHandle),
            let ephPk    = try KeyStore.load(forKey: KeyStoreKeys.ephemeralPublicKey),
            let certData = try KeyStore.load(forKey: KeyStoreKeys.delegationCert)
        else {
            throw SandwichError.masterUnavailable
        }
        let cert = try JSONDecoder().decode(DelegationCert.self, from: certData)
        return IdentitySandwich(
            masterPublicKey: masterPk,
            ephemeralPublicKey: ephPk,
            ephemeralKeyHandle: handle,
            delegation: cert
        )
    }

    // MARK: -- hardware wrap promotion

    /// Enroll a hardware device into the Identity Sandwich. Reads
    /// the plain master material from Keychain (Face ID prompt the
    /// first time per session), derives a device-specific AES-256
    /// key via HKDF over the device's deterministic signature, and
    /// appends the sealed copy to the wrap envelope. Any one device
    /// in the envelope can unwrap the same plaintext later.
    ///
    /// Re-enrolling the same device (same deviceId) replaces its
    /// existing blob in place; no orphans.
    ///
    /// First-time promotion: drops the plain biometric item so cold
    /// launches genuinely require the hardware. Subsequent
    /// promotions leave the biometric item intact (it was already
    /// gone from the first promotion, or it was restored at unlock).
    /// Result of a hardware-wrap promotion. `wrapped` is the new
    /// blob added to the wrap envelope; `material` carries the
    /// unwrapped entropy + passphrase so the caller can cache it on
    /// the live IdentitySandwich (the biometric Keychain item gets
    /// deleted on first enrollment, so the cache is the only path
    /// for in-session recoveryMaterial reads afterwards).
    struct PromotionResult {
        let wrapped: WrappedMaterialPersisted
        let material: MasterRecoveryMaterial
    }

    static func promoteToHardware(
        sandwich: IdentitySandwich,
        device: RegisteredDevice,
        hardware: HardwareWallet
    ) async throws -> PromotionResult {
        // Read the master material via the live sandwich. After the
        // first hardware enrollment the biometric Keychain item is
        // gone (defense-in-depth); the session cache is the only
        // remaining path, and it's what enables enrolling a SECOND
        // device (multi-key) without forcing the user to reset.
        let material = try sandwich.recoveryMaterial(
            localizedReason: "Add \(device.label) to your Identity Sandwich"
        )
        let materialData = try JSONEncoder().encode(MasterMaterialPersisted(
            entropyHex: bytesToHex(material.entropy),
            passphrase: material.passphrase
        ))
        var saltBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes)
        guard status == errSecSuccess else {
            throw IdentityWrapError.sealFailed("SecRandomCopyBytes failed: \(status)")
        }
        let salt = Data(saltBytes)
        let challenge = IdentityWrap.challenge(salt: salt, deviceSerial: device.serial)
        let signature = try await hardware.signMessage(challenge)
        let key = try IdentityWrap.deriveWrapKey(signature: signature, salt: salt)
        let sealedBox = try IdentityWrap.seal(
            plaintext: materialData,
            key: key,
            deviceSerial: device.serial
        )
        let wrapped = WrappedMaterialPersisted(
            deviceId: device.id,
            deviceSerial: device.serial,
            salt: salt,
            sealedBox: sealedBox,
            wrappedAt: Date()
        )

        let existing = (try loadWrapEnvelope())?.blobs ?? []
        let wasEmpty = existing.isEmpty
        // Replace any existing blob for this same device (re-enroll
        // semantics) or append.
        var next = existing.filter { $0.deviceId != device.id }
        next.append(wrapped)
        try saveWrapEnvelope(WrapEnvelope(blobs: next))

        if wasEmpty {
            // First device enrolled: drop the plain biometric item
            // so a jailbreak-with-Face-ID attacker can't read it
            // without the hardware. The caller-side session cache
            // (see PromotionResult.material) keeps backup / reveal
            // working in the current session.
            try KeyStore.delete(forKey: KeyStoreKeys.masterMaterial)
        }
        LogStore.shared.info("identity.wrap",
            "promoted \(device.serial) (\(device.label)); enrollments=\(next.count)")
        return PromotionResult(wrapped: wrapped, material: material)
    }

    /// Promote a device using a caller-supplied secret AND salt.
    /// Used by the YubiKey FIDO2 NFC path: the wrap signature is
    /// computed over a salt-derived client data hash, so the same
    /// salt must drive the HKDF. The caller generates the salt
    /// once and passes it both to the device (to compute the
    /// signature) and here (to seal the blob).
    static func promoteWithSecret(
        sandwich: IdentitySandwich,
        device: RegisteredDevice,
        secret: Data,
        salt: Data
    ) async throws -> PromotionResult {
        // Same cache-aware lookup as promoteToHardware so a SECOND
        // YubiKey can be enrolled after the biometric Keychain item
        // is gone from the first enrollment. Without this, multi-key
        // OR-of-N enrollment is structurally impossible on a freshly
        // wrapped sandwich.
        let material = try sandwich.recoveryMaterial(
            localizedReason: "Add \(device.label) to your Identity Sandwich"
        )
        let materialData = try JSONEncoder().encode(MasterMaterialPersisted(
            entropyHex: bytesToHex(material.entropy),
            passphrase: material.passphrase
        ))
        let key = try IdentityWrap.deriveWrapKey(signature: secret, salt: salt)
        let sealedBox = try IdentityWrap.seal(
            plaintext: materialData,
            key: key,
            deviceSerial: device.serial
        )
        let wrapped = WrappedMaterialPersisted(
            deviceId: device.id,
            deviceSerial: device.serial,
            salt: salt,
            sealedBox: sealedBox,
            wrappedAt: Date()
        )
        let existing = (try loadWrapEnvelope())?.blobs ?? []
        let wasEmpty = existing.isEmpty
        var next = existing.filter { $0.deviceId != device.id }
        next.append(wrapped)
        try saveWrapEnvelope(WrapEnvelope(blobs: next))
        if wasEmpty {
            try KeyStore.delete(forKey: KeyStoreKeys.masterMaterial)
        }
        LogStore.shared.info("identity.wrap",
            "promoted (secret) \(device.serial); enrollments=\(next.count)")
        return PromotionResult(wrapped: wrapped, material: material)
    }

    /// Inverse of `promoteWithSecret`: open a wrapped blob given
    /// the same secret the device just recomputed. Caller hands the
    /// opened material to `adopt(_:)`.
    static func openWithSecret(
        wrapped: WrappedMaterialPersisted,
        secret: Data
    ) throws -> Data {
        let key = try IdentityWrap.deriveWrapKey(signature: secret, salt: wrapped.salt)
        return try IdentityWrap.open(
            sealedBox: wrapped.sealedBox,
            key: key,
            deviceSerial: wrapped.deviceSerial
        )
    }

    /// Equivalent of `loadWrapped` for devices that produce a
    /// pre-computed wrap secret (YubiKey FIDO2 over NFC). Caller
    /// is responsible for handing in the secret derived from the
    /// device-side operation against `wrapped.salt`.
    static func loadWrappedWithSecret(
        enrollments: [WrappedMaterialPersisted],
        device: RegisteredDevice,
        secret: Data
    ) async throws -> IdentitySandwich {
        guard let wrapped = enrollments.first(where: { $0.deviceId == device.id }) else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: enrollments.map { $0.deviceSerial }.joined(separator: " or "),
                actual: device.serial
            )
        }
        guard device.serial == wrapped.deviceSerial else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: wrapped.deviceSerial,
                actual: device.serial
            )
        }
        let plaintext = try openWithSecret(wrapped: wrapped, secret: secret)
        try KeyStore.save(plaintext, forKey: KeyStoreKeys.masterMaterial, requireBiometric: true)

        guard
            let masterPk = try KeyStore.load(forKey: KeyStoreKeys.masterPublicKey),
            let handle   = try KeyStore.load(forKey: KeyStoreKeys.ephemeralKeyHandle),
            let ephPk    = try KeyStore.load(forKey: KeyStoreKeys.ephemeralPublicKey),
            let certData = try KeyStore.load(forKey: KeyStoreKeys.delegationCert)
        else {
            throw SandwichError.masterUnavailable
        }
        let cert = try JSONDecoder().decode(DelegationCert.self, from: certData)
        let sandwich = IdentitySandwich(
            masterPublicKey: masterPk,
            ephemeralPublicKey: ephPk,
            ephemeralKeyHandle: handle,
            delegation: cert
        )
        // Cache the unwrapped material from the just-decrypted blob
        // so in-session ops (backup, reveal phrase) don't need to
        // re-read the biometric Keychain item.
        if let persisted = try? JSONDecoder().decode(MasterMaterialPersisted.self, from: plaintext) {
            let entropy = hexToBytes(persisted.entropyHex)
            sandwich.cacheRecoveryMaterial(
                MasterRecoveryMaterial(entropy: entropy, passphrase: persisted.passphrase)
            )
        }
        return sandwich
    }

    /// Outcome of a wrap-envelope demotion.
    struct DemotionResult {
        /// True when the demoted device was the last enrolled one.
        /// The caller's UX may want to surface "Identity Sandwich is
        /// now plain biometric again" or auto-route somewhere.
        let wasLastDevice: Bool
    }

    /// Remove a device's wrap from the envelope, gated on step-up
    /// authentication from ANY currently-enrolled device. Without
    /// this gate, a drive-by attacker on an unlocked phone could
    /// silently strip enrolled devices one by one (the previous
    /// implementation only required auth on the LAST device, so
    /// every prior demote was a free envelope edit).
    ///
    /// `authorizingDevice` can be the same device being removed
    /// (the common case: user has the device they want to remove)
    /// or a different enrolled device (the lost-device recovery
    /// case: user holds a backup device to authorize removal of a
    /// missing one). The authorizing device must be enrolled, and
    /// must successfully open its own wrap blob; that proves
    /// possession in real time without trusting any cached state.
    ///
    /// Use this overload for Ledger / Trezor authorizing devices
    /// (signature-based wrap). For YubiKey FIDO2 hmac-secret
    /// authorizers, see `demoteWithSecret`.
    static func demoteFromHardware(
        deviceToRemove: RegisteredDevice,
        authorizingDevice: RegisteredDevice,
        authorizingHardware: HardwareWallet
    ) async throws -> DemotionResult {
        let env = (try loadWrapEnvelope()) ?? WrapEnvelope(blobs: [])
        guard let authBlob = env.blobs.first(where: { $0.deviceId == authorizingDevice.id }) else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: "an enrolled Identity Sandwich device",
                actual: "\(authorizingDevice.kind.displayName) \(authorizingDevice.serial)"
            )
        }
        let challenge = IdentityWrap.challenge(salt: authBlob.salt, deviceSerial: authBlob.deviceSerial)
        let signature = try await authorizingHardware.signMessage(challenge)
        let key = try IdentityWrap.deriveWrapKey(signature: signature, salt: authBlob.salt)
        // The open() success IS the proof-of-possession: only the
        // authorizing device can produce a signature that opens its
        // own wrap blob.
        let plaintext = try IdentityWrap.open(
            sealedBox: authBlob.sealedBox,
            key: key,
            deviceSerial: authBlob.deviceSerial
        )
        return try applyDemotion(
            env: env,
            deviceToRemove: deviceToRemove,
            authorizingPlaintext: plaintext
        )
    }

    /// YubiKey-FIDO2-hmac-secret equivalent of `demoteFromHardware`.
    /// The caller has already driven `recomputeHMACSecretOverNFC`
    /// on the authorizing YubiKey and passes the resulting 32-byte
    /// secret in. The secret must open the authorizing device's own
    /// wrap blob, which proves possession.
    static func demoteWithSecret(
        deviceToRemove: RegisteredDevice,
        authorizingDevice: RegisteredDevice,
        authorizingSecret: Data
    ) async throws -> DemotionResult {
        let env = (try loadWrapEnvelope()) ?? WrapEnvelope(blobs: [])
        guard let authBlob = env.blobs.first(where: { $0.deviceId == authorizingDevice.id }) else {
            throw IdentityWrapError.deviceSerialMismatch(
                expected: "an enrolled Identity Sandwich device",
                actual: "\(authorizingDevice.kind.displayName) \(authorizingDevice.serial)"
            )
        }
        let key = try IdentityWrap.deriveWrapKey(signature: authorizingSecret, salt: authBlob.salt)
        let plaintext = try IdentityWrap.open(
            sealedBox: authBlob.sealedBox,
            key: key,
            deviceSerial: authBlob.deviceSerial
        )
        return try applyDemotion(
            env: env,
            deviceToRemove: deviceToRemove,
            authorizingPlaintext: plaintext
        )
    }

    /// Shared envelope-edit step. The two demote entry points
    /// produce a `plaintext` by opening the authorizing device's
    /// own wrap blob; that proves possession. From here on it's a
    /// straight envelope edit, plus a biometric-item restore when
    /// removing the last enrolled device.
    private static func applyDemotion(
        env: WrapEnvelope,
        deviceToRemove: RegisteredDevice,
        authorizingPlaintext: Data
    ) throws -> DemotionResult {
        guard env.blobs.contains(where: { $0.deviceId == deviceToRemove.id }) else {
            // Already removed; idempotent.
            return DemotionResult(wasLastDevice: false)
        }
        let next = env.blobs.filter { $0.deviceId != deviceToRemove.id }
        if next.isEmpty {
            // Removing the last enrolled device. The authorizing
            // device IS the one being removed (the only one left).
            // Restore the plain biometric item from the plaintext
            // we just opened, drop the wrap envelope.
            try KeyStore.save(authorizingPlaintext, forKey: KeyStoreKeys.masterMaterial, requireBiometric: true)
            try KeyStore.delete(forKey: KeyStoreKeys.wrappedMasterMaterial)
            LogStore.shared.info("identity.wrap",
                "demoted last device \(deviceToRemove.serial); restored biometric item")
            return DemotionResult(wasLastDevice: true)
        } else {
            try saveWrapEnvelope(WrapEnvelope(blobs: next))
            LogStore.shared.info("identity.wrap",
                "demoted \(deviceToRemove.serial); remaining enrollments=\(next.count)")
            return DemotionResult(wasLastDevice: false)
        }
    }

    // MARK: -- recovery + reveal material

    /// Decrypt the master material out of Keychain (Face ID prompt)
    /// and return the entropy plus passphrase. Used by:
    ///   - Settings "Show recovery phrase"
    ///   - Settings "Show passphrase"
    ///   - Delegation renewal (the master sign path)
    ///   - iCloud backup uploader
    func recoveryMaterial(localizedReason: String) throws -> MasterRecoveryMaterial {
        // In-session cache (populated at unlock / enrollment time)
        // wins over the biometric Keychain item. This is the only
        // recovery path that works after `promoteToHardware` /
        // `promoteWithSecret` have deleted the biometric item on
        // first hardware enrollment.
        if let cached = sessionMaterial { return cached }
        guard let data = try KeyStore.load(
            forKey: KeyStoreKeys.masterMaterial,
            localizedReason: localizedReason
        ) else {
            throw SandwichError.masterUnavailable
        }
        let persisted = try JSONDecoder().decode(MasterMaterialPersisted.self, from: data)
        let entropy = hexToBytes(persisted.entropyHex)
        let material = MasterRecoveryMaterial(entropy: entropy, passphrase: persisted.passphrase)
        // Cache for the rest of the session so subsequent reads are
        // free of biometric prompts and survive a later hardware
        // enrollment that deletes the biometric item.
        self.sessionMaterial = material
        return material
    }

    /// Populate the in-session recovery-material cache. Called by:
    ///   - `buildAndPersist` after a fresh onboarding or mnemonic
    ///     restore (we already have the material in hand).
    ///   - `loadWrappedWithSecret` after a successful hardware
    ///     unlock (we just opened the wrap blob and have plaintext).
    ///   - `promoteWithSecret` / `promoteToHardware` after the first
    ///     enrollment deletes the biometric item but before returning
    ///     to the caller.
    func cacheRecoveryMaterial(_ m: MasterRecoveryMaterial) {
        self.sessionMaterial = m
    }

    // MARK: -- daily operations

    func needsRenewal(now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        return now > delegation.validUntil - renewalLeadTimeSec
    }

    func renewDelegation(localizedReason: String = "Refresh identity delegation") throws {
        let material = try recoveryMaterial(localizedReason: localizedReason)
        let newCert = try Self.signDelegation(
            ephemeralPk: ephemeralPublicKey,
            entropy: material.entropy,
            passphrase: material.passphrase
        )
        try persistCert(newCert)
        delegation = newCert
    }

    /// Sign a challenge with the SE-resident ephemeral. No biometric
    /// prompt (device unlock is the gate). Auto-renews the delegation
    /// first if it is within an hour of expiring.
    func signChallenge(_ message: Data) throws -> Data {
        if needsRenewal() {
            try renewDelegation()
        }
        return try MLDSAClient.signWithEphemeralSE(
            handle: ephemeralKeyHandle,
            message: message
        )
    }

    /// Sign with the master ML-DSA-65 key. Surfaces a Face ID / passcode
    /// prompt (and the hardware second factor, if enrolled) because
    /// the master material lives in a biometric-gated Keychain slot.
    ///
    /// Use this for high-trust operations that require holder consent
    /// per request: passport credential issuance, identity transfer to
    /// a new device, key rotation. Fast-path ephemeral signing is the
    /// right tool for ordinary verifier challenges.
    func signWithMaster(_ message: Data, localizedReason: String) throws -> Data {
        let material = try recoveryMaterial(localizedReason: localizedReason)
        let words = BIP39.mnemonicFromSeed(material.entropy)
        let bip39Seed = try BIP39.derivedSeed(mnemonic: words, passphrase: material.passphrase)
        let mldsaSeed = Data(bip39Seed.prefix(32))
        return try MLDSAClient.signWithMaster(seed: mldsaSeed, message: message)
    }

    static func wipe() throws {
        try KeyStore.wipeAll()
    }

    // MARK: -- private helpers

    private static func buildAndPersist(entropy: Data, passphrase: String) throws -> IdentitySandwich {
        precondition(entropy.count == 32, "entropy must be 32 bytes")

        // Derive the master ML-DSA-65 seed via BIP39 + optional passphrase.
        let words = BIP39.mnemonicFromSeed(entropy)
        let bip39Seed = try BIP39.derivedSeed(mnemonic: words, passphrase: passphrase)
        let mldsaSeed = Data(bip39Seed.prefix(32))
        let masterPk = try MLDSAClient.masterPublicKey(fromSeed: mldsaSeed)

        try KeyStore.wipeAll()

        // Persist master pubkey (non-biometric — it's public) and the
        // combined material (biometric).
        try KeyStore.save(masterPk, forKey: KeyStoreKeys.masterPublicKey, requireBiometric: false)
        let persisted = MasterMaterialPersisted(
            entropyHex: bytesToHex(entropy),
            passphrase: passphrase
        )
        let materialData = try JSONEncoder().encode(persisted)
        try KeyStore.save(materialData, forKey: KeyStoreKeys.masterMaterial, requireBiometric: true)
        // Surface the passphrase-presence as a non-biometric flag so
        // the UI can know without prompting Face ID.
        let flag = (passphrase.isEmpty ? "0" : "1").data(using: .utf8) ?? Data()
        try KeyStore.save(flag, forKey: KeyStoreKeys.hasPassphrase, requireBiometric: false)

        // Generate SE ephemeral.
        let (ephPk, handle) = try MLDSAClient.generateEphemeralSE()
        try KeyStore.save(ephPk, forKey: KeyStoreKeys.ephemeralPublicKey, requireBiometric: false)
        try KeyStore.save(handle, forKey: KeyStoreKeys.ephemeralKeyHandle, requireBiometric: false)

        // Sign + persist the first delegation. We have the entropy +
        // passphrase locally so no biometric prompt is needed here.
        let cert = try signDelegation(
            ephemeralPk: ephPk,
            entropy: entropy,
            passphrase: passphrase
        )
        let certData = try JSONEncoder().encode(cert)
        try KeyStore.save(certData, forKey: KeyStoreKeys.delegationCert, requireBiometric: false)

        let sandwich = IdentitySandwich(
            masterPublicKey: masterPk,
            ephemeralPublicKey: ephPk,
            ephemeralKeyHandle: handle,
            delegation: cert
        )
        // Cache for the rest of the session so subsequent backup /
        // reveal calls survive a later hardware enrollment that
        // deletes the biometric Keychain item.
        sandwich.cacheRecoveryMaterial(
            MasterRecoveryMaterial(entropy: entropy, passphrase: passphrase)
        )
        return sandwich
    }

    /// Canonicalize the inner cert fields, ML-DSA-65 sign with the
    /// master (reconstructed in-memory), assemble the full
    /// `DelegationCert`. The master only exists for the duration of
    /// this call.
    private static func signDelegation(
        ephemeralPk: Data,
        entropy: Data,
        passphrase: String
    ) throws -> DelegationCert {
        let now = Int64(Date().timeIntervalSince1970)
        let ephHex = "0x" + bytesToHex(ephemeralPk)
        let validFrom = now
        let validUntil = now + defaultValidityWindowSec

        let inner: [String: Any] = [
            "ephemeralPk": ephHex,
            "validFrom":   validFrom,
            "validUntil":  validUntil,
            "scope":       presentationScope,
        ]
        let canonical = try ElabifyCore.canonicalize(inner)

        // Re-derive the master seed via the standard BIP39 path.
        let words = BIP39.mnemonicFromSeed(entropy)
        let bip39Seed = try BIP39.derivedSeed(mnemonic: words, passphrase: passphrase)
        let mldsaSeed = Data(bip39Seed.prefix(32))
        let sig = try MLDSAClient.signWithMaster(seed: mldsaSeed, message: canonical)

        return DelegationCert(
            ephemeralPk: ephHex,
            validFrom: validFrom,
            validUntil: validUntil,
            scope: presentationScope,
            delegationSig: "0x" + bytesToHex(sig)
        )
    }

    private func persistCert(_ cert: DelegationCert) throws {
        let data = try JSONEncoder().encode(cert)
        try KeyStore.save(data, forKey: KeyStoreKeys.delegationCert, requireBiometric: false)
    }
}

// MARK: -- Errors

enum SandwichError: Error, CustomStringConvertible {
    case masterUnavailable
    var description: String {
        switch self {
        case .masterUnavailable:
            return "Master seed is not in Keychain (biometric or passcode prompt was denied, or wallet not provisioned)."
        }
    }
}

// MARK: -- File-private hex helpers

private func bytesToHex(_ d: Data) -> String {
    let alphabet: [Character] = Array("0123456789abcdef")
    var s = String()
    s.reserveCapacity(d.count * 2)
    for byte in d {
        s.append(alphabet[Int(byte >> 4)])
        s.append(alphabet[Int(byte & 0x0f)])
    }
    return s
}

private func hexToBytes(_ hex: String) -> Data {
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
    // Soft-fail on malformed input rather than crashing the process.
    // Callers downstream see an empty Data (or a Data shorter than
    // they expected) and surface a recoverable error.
    guard s.count.isMultiple(of: 2) else {
        LogStore.shared.error("hex",
            "hexToBytes: odd-length input (\(s.count)); returning empty")
        return Data()
    }
    var out = Data(count: s.count / 2)
    let chars = Array(s)
    for i in 0..<(s.count / 2) {
        guard let hi = chars[i * 2].hexDigitValue,
              let lo = chars[i * 2 + 1].hexDigitValue else {
            LogStore.shared.error("hex",
                "hexToBytes: non-hex character at index \(i * 2); returning empty")
            return Data()
        }
        out[i] = UInt8((hi << 4) | lo)
    }
    return out
}
