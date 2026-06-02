# Identity Sandwich hardware wrap

How Maknoon binds the BIP39 master entropy to one or more enrolled hardware devices so the device must be present to unlock the wallet on this iPhone. Lives outside the app code because the technical detail isn't useful inside the unlock UI; users only need to know that one device unlocks and the wrap key never leaves the device.

## High-level model

The Identity Sandwich holds three things:

1. A BIP39 master mnemonic (the recovery phrase).
2. A Secure-Enclave-resident ephemeral signing key for everyday operations.
3. A delegation cert linking the two.

Hardware-wrap mode adds a fourth: a per-device AES-256-GCM-sealed copy of the master material, called a "wrap blob". When the user has at least one enrolled device, the plain master material is **deleted** from the biometric Keychain slot on first enrollment. After that, cold launches cannot unlock the sandwich without a successful exchange with one of the enrolled devices.

The wrap envelope is an OR-of-N set: any single enrolled device can unlock independently. There is no quorum, no primary, no backup hierarchy. Each device gets its own salt and its own sealed blob; loss of one device does not affect any other.

## Per-device wrap-key derivation

Each device kind produces a deterministic-per-(device, salt, serial) secret. Maknoon HKDFs that secret with the persisted salt to derive a 32-byte AES key, then seals the master material with AES-256-GCM. The Keychain holds only the sealed bytes plus the salt and the device id; the AES key is reconstructed on demand at unlock time.

### Ledger (and any future Ledger-shaped vendor)

- **Mechanism**: Ledger's Ethereum app `personal_sign` APDU (CLA=0xE0 INS=0x08).
- **Determinism**: Ledger uses RFC 6979 deterministic ECDSA. The same (private key, message) pair always produces the same 64+1-byte signature. No counter, no nonce, no replay surface.
- **Wrap challenge**: a domain-separated SHA-256 hash of (`"Maknoon wrap "` prefix || salt || deviceSerial), displayed to the user on the device as a short hex string.
- **Wrap key**: HKDF-SHA256-Extract(salt, signature) || HKDF-Expand(info=`"maknoon-identity-wrap-v1"`, len=32).

This path is stable across enrollment and unlock and across app reinstalls; the same Ledger always produces the same wrap key for a given (salt, serial).

### YubiKey FIDO2 (current build, **broken** for unlock; tracked as a separate fix)

- **Mechanism today**: FIDO2 `getAssertion` over NFC with a fixed clientDataHash; the resulting raw ECDSA signature is hashed (SHA-256) into a 32-byte secret used as HKDF input keying material.
- **Problem**: FIDO2 `authenticatorData` includes a 4-byte signature counter that **increments on every getAssertion call**. The signature is computed over `authData || clientDataHash`, so consecutive calls produce different signatures even when the message is identical. Enrollment-time signature != unlock-time signature, the HKDF outputs differ, AES-GCM open fails with `authenticationFailure` on the same physical YubiKey.
- **User-visible symptom**: enrollment succeeds; first unlock attempt produces "Could not unseal master material: wrap key did not match (wrong device, or device signature drifted since enrollment)" even with the correct PIN and the same key.

### YubiKey FIDO2 with hmac-secret extension (planned proper fix)

- **Mechanism**: FIDO2's `hmac-secret` extension (CTAP2.1) produces a 32-byte HMAC output keyed by a credential-resident secret, with a host-provided salt. The salt is a fixed value derived from (salt, serial) per enrollment; the output is deterministic across calls because the counter is not part of the HMAC input.
- **Implementation cost**: YubiKit-iOS does not expose hmac-secret as a high-level API. The implementation requires manual CTAP2 ECDH key agreement with the authenticator (`clientPin.getKeyAgreement`), AES-256-CBC encryption of the salt under the shared secret with IV=0, HMAC-SHA256-truncated saltAuth, passing both via the `extensions` parameter on `makeCredential` and `getAssertion`, and AES-CBC decryption of the response. Approximately 2 to 3 days of careful crypto + CTAP2 work.
- **Status**: tracked separately. Until it lands, prefer Ledger enrollment for the Identity Sandwich. YubiKeys can still be enrolled today; they just cannot complete an unlock until hmac-secret ships.

## Persistence shape

Stored in the iOS Keychain under `KeyStoreKeys.wrappedMasterMaterial`:

```
WrapEnvelope {
    v: 2,
    blobs: [
        WrappedMaterialPersisted {
            deviceId: UUID,
            deviceSerial: String,
            salt: 32 bytes,
            sealedBox: nonce (12B) || ciphertext || tag (16B),
            wrappedAt: Date
        },
        ...
    ]
}
```

The plain biometric `masterMaterial` Keychain slot is empty whenever `wrappedMasterMaterial` is non-empty. On successful unlock, the unwrapped plain entropy is written back to the biometric slot for the duration of the session; it is wiped again when the user demotes the last device.

## Backup/restore round-trip

The v5 encrypted backup blob (see `Maknoon/iCloudBackup.swift`) includes:

- the wrap envelope itself (blob bytes base64-encoded inside the AES-GCM-sealed plaintext);
- the per-device `IdentityPromotion` records (credential ids for YubiKey FIDO2 enrollments).

On restore, both are written back to Keychain (the wrap envelope to its slot, the plain biometric slot deleted), and the launch flow re-routes through `HardwareUnlockView` with the freshly-restored enrollments visible. The user then taps the same physical device that wrapped the sandwich originally; that path works for Ledger today and will work for YubiKey once hmac-secret ships.

If the user has lost every enrolled device, the encrypted backup file itself (or the 24-word paper mnemonic) is the recovery path; the wrap envelope is bypassed entirely by the "Restore from mnemonic" flow.

## What the AES-GCM AAD binds

The `authenticatedData` on AES-GCM is the device's reported serial (UTF-8). A wrap blob sealed with one device's serial cannot be opened by claiming a different serial, even with the correct wrap key. This catches the unusual case where someone re-images a device, the wrap key happens to coincide, but the recorded serial differs.

## Why the wrap key never lives in Keychain

The Identity Sandwich threat model treats the iPhone as a trusted-but-targeted endpoint. iOS Keychain protects against passive disk reads but not against an active attacker who can prompt for Face ID. Locking the wrap key into the hardware device (Ledger button press, YubiKey NFC tap with PIN) puts a physical-presence requirement on every unlock that a remote attacker cannot satisfy.

The sealed wrap blob is fine to keep in iOS Keychain because the AES key required to open it is reconstructed from a per-unlock device-side cryptographic operation. The user can lose their phone and an attacker still cannot recover the master material without one of the enrolled hardware devices.
