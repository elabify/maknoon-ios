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
//   * `generateFresh(passphrase:)`: pick fresh 32 bytes of entropy,
//     derive master, create ephemeral, sign first delegation, persist.
//   * `restoreFromMnemonic(words:passphrase:)`: rebuild master from a
//     paper / iCloud-restored 24-word phrase plus passphrase.
//   * `loadFromKeychain()`: reattach on subsequent launches.
//   * `renewIfExpiring(now:)`: refresh delegation when within an hour
//     of expiry.
//   * `signChallenge(_:)`: sign with the SE ephemeral, fast path.
//
// All cert canonicalization routes through ElabifyCore.canonicalize()
// from the Swift binding, which is KAT-proven byte-identical with the
// TS canonicalize the verifier server uses.

import Foundation
import CryptoKit
import ElabifyCore
import LocalAuthentication

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
    /// cold launches re-route through HardwareUnlockView when the
    /// second factor is on and repopulate via `loadWithSecondFactor`.
    private var sessionMaterial: MasterRecoveryMaterial?

    /// In-session cache of the second-factor CEK, populated at first
    /// enrollment and at every hardware unlock. Adding ANOTHER second
    /// factor needs the shared CEK to wrap it for the new device; with
    /// this cache the add taps only the NEW device (no need to dig out
    /// an already-enrolled key just to recover the CEK). The CEK is no
    /// more sensitive than `sessionMaterial` (which already holds the
    /// entropy), and lives only for the loaded sandwich; a cold launch
    /// repopulates it via `loadWithSecondFactor`.
    private var sessionCek: Data?

    /// Read the in-session CEK if one is cached (see `sessionCek`).
    var cachedSecondFactorCek: Data? { sessionCek }

    /// True when the master seed material is cached in-session, so a
    /// derivation-only read (`recoveryMaterial` / `addressFromSandwich`) returns
    /// WITHOUT a biometric prompt. Lets passive UI (e.g. the ADR-0063 orphaned-
    /// wallet check) derive an address only when it is free, never prompting.
    var isUnlockedForDerivation: Bool { sessionMaterial != nil }

    /// Populate the in-session CEK cache.
    func cacheSecondFactorCek(_ cek: Data) { self.sessionCek = cek }

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
    /// signals the second factor (CEK scheme) is ON: the plain
    /// entropy seal is gone and the caller must drive the unlock UI
    /// with the enrolled devices that carry a CEK wrap.
    enum LoadResult {
        case notProvisioned
        case loaded(IdentitySandwich)
        case wrappedAwaitingHardware
    }

    /// True iff the second factor (ADR-0032 CEK scheme) is currently ON:
    /// the entropy is sealed under the CEK (sealedEntropyUnderCEK present)
    /// and the plain biometric `masterMaterial` item is therefore absent.
    /// In this state a cold launch must route through the hardware-unlock
    /// flow; routine reads of the plain item will not find the entropy.
    static func isSecondFactorOn() throws -> Bool {
        try KeyStore.load(forKey: KeyStoreKeys.sealedEntropyUnderCEK) != nil
    }

    /// Reload an existing sandwich from Keychain. Returns
    /// `.wrappedAwaitingHardware` when the second factor (CEK scheme)
    /// is ON; the caller drives the unlock UI with the enrolled
    /// devices and then calls `loadWithSecondFactor(...)` once a
    /// device produced its secret.
    static func loadFromKeychain() throws -> LoadResult {
        guard
            let _masterPk = try KeyStore.load(forKey: KeyStoreKeys.masterPublicKey),
            let _handle   = try KeyStore.load(forKey: KeyStoreKeys.ephemeralKeyHandle),
            let _ephPk    = try KeyStore.load(forKey: KeyStoreKeys.ephemeralPublicKey),
            let _certData = try KeyStore.load(forKey: KeyStoreKeys.delegationCert)
        else {
            return .notProvisioned
        }
        if try isSecondFactorOn() {
            // Second factor ON: the plain entropy seal is gone. We
            // can't build a usable sandwich until a device unwraps the
            // CEK, so the launcher drives the hardware-unlock UI.
            return .wrappedAwaitingHardware
        }
        // Clean-cut migration: a legacy (pre-CEK) second-factor
        // enrollment left the old `wrappedMasterMaterial` item and
        // deleted the plain biometric `masterMaterial`. The new code
        // cannot open the old envelope, so signal awaiting-hardware
        // with no v2-wrapped devices; loadIdentity then surfaces the
        // restore-from-backup migration banner. Checked via the
        // non-biometric legacy item so no Face ID prompt fires here.
        if try KeyStore.load(forKey: KeyStoreKeys.wrappedMasterMaterial) != nil {
            return .wrappedAwaitingHardware
        }
        let cert = try JSONDecoder().decode(DelegationCert.self, from: _certData)
        return .loaded(IdentitySandwich(
            masterPublicKey: _masterPk,
            ephemeralPublicKey: _ephPk,
            ephemeralKeyHandle: _handle,
            delegation: cert
        ))
    }

    // MARK: -- second-factor wrap (ADR-0032 CEK scheme)

    /// Result of sealing the wrap for one enrolled device. The caller
    /// persists `wrappedCekHex` (with the deviceSalt it passed in) on
    /// that device's IdentityPromotion. `cek` is returned transiently so
    /// a multi-device add can reuse it for the next device without
    /// another tap; it is never persisted in the clear and the caller
    /// should drop it after use. `material` carries the entropy +
    /// passphrase so the caller can cache it on the live sandwich (the
    /// plain biometric item is deleted on first enrollment).
    struct SecondFactorEnrollSeal {
        let wrappedCekHex: String
        let cek: Data
        let material: MasterRecoveryMaterial
    }

    /// Enroll a device into the second factor (ADR-0032 CEK scheme).
    /// First device (`existingCek == nil`): mint a fresh CEK, seal the
    /// 32-byte entropy ONCE under it into `sealedEntropyUnderCEK`, write
    /// the passphrase to its own slot, and DELETE the plain biometric
    /// `masterMaterial`. Subsequent device: reuse the passed-in CEK
    /// (recovered from an already-enrolled device) so the single sealed
    /// entropy is unchanged. Always wraps the CEK under this device's
    /// secret + salt and returns the wrappedCEK hex. The CALLER writes
    /// `deviceSaltHex` + `wrappedCekHex` + `wrapProtocolVersion = 2`
    /// onto the device's IdentityPromotion.
    static func sealForSecondFactorEnroll(
        sandwich: IdentitySandwich,
        device: RegisteredDevice,
        secret: Data,
        deviceSalt: Data,
        existingCek: Data?
    ) throws -> SecondFactorEnrollSeal {
        // Read the master material via the live sandwich. After the
        // first enrollment the plain biometric item is gone
        // (defense-in-depth); the session cache is the only remaining
        // path, and it's what enables enrolling a SECOND device.
        let material = try sandwich.recoveryMaterial(
            localizedReason: "Add \(device.label) as a second factor"
        )
        let cek = existingCek ?? SecondFactorWrap.newCek()
        // Seal the entropy under the CEK (once) and flip 2FA on. When
        // adding a second device with the same CEK this rewrites the
        // identical sealedEntropy, which is harmless.
        let sealedEntropyHex = try SecondFactorWrap.sealEntropy(material.entropy, cek: cek)
        try KeyStore.saveString(sealedEntropyHex, forKey: KeyStoreKeys.sealedEntropyUnderCEK)
        try KeyStore.saveString(material.passphrase, forKey: KeyStoreKeys.passphraseUnder2FA)
        // First enrollment: drop the plain biometric item so a
        // jailbreak-with-Face-ID attacker can't read the entropy
        // without the hardware. The caller caches `material` on the
        // live sandwich so in-session reveal / backup keep working.
        try KeyStore.delete(forKey: KeyStoreKeys.masterMaterial)

        let wrappedCekHex = try SecondFactorWrap.wrapCek(cek, secret: secret, deviceSalt: deviceSalt)
        // Cache the CEK so adding a FURTHER device this session taps only
        // the new device (no need to re-tap an already-enrolled key).
        sandwich.cacheSecondFactorCek(cek)
        LogStore.shared.info("identity.wrap",
            "sealed second-factor enroll for \(device.serial) (\(device.label)); reusedCek=\(existingCek != nil)")
        return SecondFactorEnrollSeal(wrappedCekHex: wrappedCekHex, cek: cek, material: material)
    }

    /// Recover the shared CEK from an already-enrolled device's wrap.
    /// Used both by the unlock path (then open the entropy) and by the
    /// multi-device add path (reuse the CEK for the next device). The
    /// open() failing IS the fail-closed OR signal: a wrong / foreign
    /// device's derived wrap key fails the GCM tag.
    static func recoverCek(device: RegisteredDevice, secret: Data) throws -> Data {
        guard let promo = device.promotions.identity, promo.hasSecondFactorWrap,
              let saltHex = promo.deviceSaltHex, let wrappedHex = promo.wrappedCekHex
        else {
            throw SandwichError.masterUnavailable
        }
        let deviceSalt = hexToBytes(saltHex)
        return try SecondFactorWrap.unwrapCek(wrappedHex, secret: secret, deviceSalt: deviceSalt)
    }

    /// Second-factor unlock (ADR-0032). Given a device that carries a
    /// CEK wrap and the just-recomputed per-device secret, recover the
    /// CEK, open the sealed entropy, read the passphrase slot, rebuild
    /// the master material, and reconstruct the sandwich from the
    /// persisted public items. A wrong / foreign device throws at the
    /// GCM tag so the caller can try the next enrolled device.
    static func loadWithSecondFactor(
        device: RegisteredDevice,
        secret: Data
    ) throws -> IdentitySandwich {
        let cek = try recoverCek(device: device, secret: secret)
        guard let sealedEntropyHex = try KeyStore.loadString(forKey: KeyStoreKeys.sealedEntropyUnderCEK) else {
            throw SandwichError.masterUnavailable
        }
        let entropy = try SecondFactorWrap.openEntropy(sealedEntropyHex, cek: cek)
        let passphrase = (try KeyStore.loadString(forKey: KeyStoreKeys.passphraseUnder2FA)) ?? ""

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
        // Cache the recovered material so in-session ops (backup,
        // reveal phrase, delegation renewal, enrolling another device)
        // work without another hardware tap.
        sandwich.cacheRecoveryMaterial(
            MasterRecoveryMaterial(entropy: entropy, passphrase: passphrase)
        )
        // Cache the CEK too so adding another second factor this session
        // taps only the new device.
        sandwich.cacheSecondFactorCek(cek)
        return sandwich
    }

    /// Outcome of a second-factor removal.
    struct DemotionResult {
        /// True when the removed device was the last enrolled one and
        /// the second factor was turned off (plain biometric restored).
        let wasLastDevice: Bool
    }

    /// Remove a device from the second factor (ADR-0032), gated on
    /// proof-of-possession from an authorizing enrolled device. The
    /// authorizer recomputes its secret and unwraps its own CEK; that
    /// unwrap succeeding IS the proof. The removed device's wrap fields
    /// are cleared by the CALLER (setIdentityPromotion). If the removed
    /// device was the LAST enrolled one, the recovered CEK opens the
    /// sealed entropy, re-seals the plain biometric `masterMaterial`,
    /// and deletes sealedEntropyUnderCEK + the passphrase slot (second
    /// factor off).
    ///
    /// `remainingWrappedDevicesAfterRemoval` is the count of devices
    /// that still carry a CEK wrap once `deviceToRemove` is dropped;
    /// the caller computes it from the registry. Zero means this was
    /// the last device.
    static func removeSecondFactor(
        authorizingDevice: RegisteredDevice,
        authorizingSecret: Data,
        remainingWrappedDevicesAfterRemoval: Int
    ) throws -> DemotionResult {
        // Proof-of-possession: only the authorizing device can produce
        // a secret that unwraps its own CEK.
        let cek = try recoverCek(device: authorizingDevice, secret: authorizingSecret)
        if remainingWrappedDevicesAfterRemoval <= 0 {
            // Last device: turn the second factor off. Recover the
            // entropy via the CEK, re-seal the plain biometric item,
            // drop the CEK envelope + passphrase slot.
            guard let sealedEntropyHex = try KeyStore.loadString(forKey: KeyStoreKeys.sealedEntropyUnderCEK) else {
                throw SandwichError.masterUnavailable
            }
            let entropy = try SecondFactorWrap.openEntropy(sealedEntropyHex, cek: cek)
            let passphrase = (try KeyStore.loadString(forKey: KeyStoreKeys.passphraseUnder2FA)) ?? ""
            let materialData = try JSONEncoder().encode(MasterMaterialPersisted(
                entropyHex: bytesToHex(entropy),
                passphrase: passphrase
            ))
            try KeyStore.save(materialData, forKey: KeyStoreKeys.masterMaterial, requireBiometric: true)
            try KeyStore.delete(forKey: KeyStoreKeys.sealedEntropyUnderCEK)
            try KeyStore.delete(forKey: KeyStoreKeys.passphraseUnder2FA)
            LogStore.shared.info("identity.wrap",
                "removed last second-factor device; restored plain biometric material")
            return DemotionResult(wasLastDevice: true)
        }
        LogStore.shared.info("identity.wrap",
            "removed a second-factor device; remaining wrapped=\(remainingWrappedDevicesAfterRemoval)")
        return DemotionResult(wasLastDevice: false)
    }

    // MARK: -- recovery + reveal material

    /// READ-ONLY / derivation use only (addresses, balances, backup upload).
    /// This is cache-first: once `sessionMaterial` is populated it returns with
    /// NO biometric prompt. Any action that PRODUCES A SIGNATURE or BROADCASTS a
    /// transaction MUST instead use `recoveryMaterialFresh`, which forces a fresh
    /// biometric / 2FA prompt every time (see ADR-0045, Authorization invariant).
    ///
    /// In-session cache (populated at unlock / enrollment time) wins over the
    /// biometric Keychain item. This is the only recovery path that works after
    /// `sealForSecondFactorEnroll` has deleted the biometric item.
    func recoveryMaterial(localizedReason: String) throws -> MasterRecoveryMaterial {
        if let cached = sessionMaterial { return cached }
        let material = try readMasterMaterialFromKeychain(localizedReason: localizedReason)
        // Cache for the rest of the session so subsequent reads are free of
        // biometric prompts and survive a later hardware enrollment.
        self.sessionMaterial = material
        return material
    }

    /// Read the `.userPresence`-protected master material straight from the
    /// Keychain (bypassing the cache). Reading the item forces iOS to present a
    /// fresh Face ID / passcode prompt. Shared by `recoveryMaterial` (cache miss)
    /// and `recoveryMaterialFresh` (always).
    private func readMasterMaterialFromKeychain(localizedReason: String) throws -> MasterRecoveryMaterial {
        guard let data = try KeyStore.load(
            forKey: KeyStoreKeys.masterMaterial,
            localizedReason: localizedReason
        ) else {
            throw SandwichError.masterUnavailable
        }
        let persisted = try JSONDecoder().decode(MasterMaterialPersisted.self, from: data)
        return MasterRecoveryMaterial(
            entropy: hexToBytes(persisted.entropyHex),
            passphrase: persisted.passphrase
        )
    }

    /// Authorize a SENSITIVE action (signing a message, signing/broadcasting a
    /// transaction) by forcing a fresh biometric / device-passcode prompt right
    /// now, then return the master material. Unlike `recoveryMaterial`, this is
    /// NEVER satisfied silently from the in-session cache.
    ///
    /// Two modes (branch on `isSecondFactorOn()`, no prompt to check):
    ///   - Biometric mode: bypass the cache and read the `.userPresence` Keychain
    ///     item, which prompts. Refreshing the cache means a later
    ///     `recoveryMaterial()` in the same action does not prompt again.
    ///   - Hardware second-factor mode: the Keychain item is sealed/absent and the
    ///     cache is the only source, so gate with an explicit device-owner-auth
    ///     evaluation, then return the cached material.
    /// Exactly one prompt per call in both modes.
    func recoveryMaterialFresh(localizedReason: String) async throws -> MasterRecoveryMaterial {
        if try Self.isSecondFactorOn() == false {
            let material = try readMasterMaterialFromKeychain(localizedReason: localizedReason)
            self.sessionMaterial = material
            return material
        }
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            let ok = (try? await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: localizedReason
            )) ?? false
            guard ok else { throw SandwichError.userCancelled }
        }
        guard let cached = sessionMaterial else { throw SandwichError.masterUnavailable }
        return cached
    }

    /// Populate the in-session recovery-material cache. Called by:
    ///   - `buildAndPersist` after a fresh onboarding or mnemonic
    ///     restore (we already have the material in hand).
    ///   - `loadWithSecondFactor` after a successful hardware unlock
    ///     (we just opened the sealed entropy and have it in hand).
    ///   - `sealForSecondFactorEnroll` (via the caller) after the first
    ///     enrollment deletes the biometric item but before returning.
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

        // Persist master pubkey (non-biometric, it's public) and the
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
    case userCancelled
    var description: String {
        switch self {
        case .masterUnavailable:
            return "Master seed is not in Keychain (biometric or passcode prompt was denied, or wallet not provisioned)."
        case .userCancelled:
            return "Authentication was cancelled."
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
