// Thin Keychain wrapper for the Identity Sandwich state.
//
// Two access classes:
//
//   1. Biometric-gated (Face ID per use) — used for the master seed.
//      Items are written with .userPresence so iOS prompts the user
//      before returning bytes. The LAContext attached at load time
//      lets us localise the prompt and reuse a successful auth across
//      multiple back-to-back loads (Apple caches for ~10 seconds).
//
//   2. Non-biometric — used for the ephemeral SE key handle, the
//      delegation certificate, the master public key, and any
//      hardware attestation. These need device-unlock but no Face
//      ID prompt; they unlock implicitly when the user has unlocked
//      the phone.
//
// Every item uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly. This
// is the strictest accessibility class that still lets the app read
// the item in the background after the first unlock, and the
// `ThisDeviceOnly` suffix prevents iCloud Keychain or other device
// sync from carrying the item across devices (matching the
// Secure-Enclave-key isolation: the SE handle is meaningless off
// the original device, so the master seed shouldn't sync either).

import Foundation
import LocalAuthentication
import Security

enum KeyStoreError: Error, CustomStringConvertible {
    case osStatus(OSStatus, op: String)
    case unexpected(String)

    var description: String {
        switch self {
        case .osStatus(let s, let op):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "code \(s)"
            return "KeyStore \(op) failed: \(msg) (\(s))"
        case .unexpected(let m):
            return "KeyStore: \(m)"
        }
    }
}

enum KeyStore {
    /// Account namespace used for every item. Single user per device for
    /// the demo; M4b proper would expose this for multi-persona support.
    private static let service = "com.elabify.holder.phase-c-demo"

    /// Persist `value` under `key`. If `requireBiometric == true`, the
    /// item gets a `.userPresence` access-control flag and any later
    /// `load` will prompt Face ID. Overwrites any existing value.
    static func save(_ value: Data, forKey key: String, requireBiometric: Bool) throws {
        try delete(forKey: key)   // overwrite semantics, ignore "not found"

        var attributes: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   value,
        ]

        if requireBiometric {
            // SAC ties the item to "user presence" (Face ID / Touch ID /
            // passcode fallback). The item still requires the device to
            // be unlocked first via AccessibleWhenUnlockedThisDeviceOnly.
            var sacError: Unmanaged<CFError>?
            guard let sac = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &sacError
            ) else {
                let err = sacError?.takeRetainedValue()
                throw KeyStoreError.unexpected("SecAccessControl create failed: \(String(describing: err))")
            }
            attributes[kSecAttrAccessControl as String] = sac
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.osStatus(status, op: "SecItemAdd[\(key)]")
        }
    }

    /// Load the value for `key`. Returns nil if no item exists. For
    /// biometric-gated items, iOS shows a Face ID prompt; pass
    /// `localizedReason` to control the prompt message.
    static func load(forKey key: String, localizedReason: String? = nil) throws -> Data? {
        let context = LAContext()
        if let reason = localizedReason {
            context.localizedReason = reason
        }

        // Reading a non-biometric item with this query still works; the
        // LAContext is just unused. No special branching needed.
        let query: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              service,
            kSecAttrAccount as String:              key,
            kSecMatchLimit as String:               kSecMatchLimitOne,
            kSecReturnData as String:               true,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeyStoreError.unexpected("SecItemCopyMatching[\(key)] returned non-Data")
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            return nil       // user dismissed Face ID; treat as "no item"
        default:
            throw KeyStoreError.osStatus(status, op: "SecItemCopyMatching[\(key)]")
        }
    }

    /// Delete the item for `key`. Returns silently if no item exists.
    static func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeyStoreError.osStatus(status, op: "SecItemDelete[\(key)]")
        }
    }

    /// Wipe every item this app has written. Used by the
    /// "Reset wallet" flow in Settings and by the recovery path before
    /// restoring a fresh master from a seed.
    static func wipeAll() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeyStoreError.osStatus(status, op: "SecItemDelete(wipeAll)")
        }
    }
}

// MARK: -- canonical keys used by the rest of the app

enum KeyStoreKeys {
    /// JSON-encoded `MasterMaterialPersisted`: 32-byte BIP39 entropy
    /// plus the user's BIP39 passphrase (empty string = no passphrase).
    /// Biometric-gated. The combined master ML-DSA-65 seed is derived
    /// from these two on demand via BIP39 PBKDF2.
    static let masterMaterial = "master.material"
    /// Hardware-wrapped form of the master material. When this key
    /// is present, `masterMaterial` is absent: the unlock path
    /// requires a registered hardware device to derive the wrap key
    /// before the entropy can be decrypted. Non-biometric: the
    /// device is the stronger gate than Face ID.
    static let wrappedMasterMaterial = "master.wrappedMaterial"
    /// 1952-byte ML-DSA-65 master public key. Non-biometric (it's public).
    static let masterPublicKey = "master.publicKey"
    /// SecureEnclave key handle (opaque, ~88 bytes) for the ephemeral. Non-biometric.
    static let ephemeralKeyHandle = "ephemeral.seKeyHandle"
    /// Cached ephemeral public key bytes, so we can read them without
    /// reconstructing the SE handle on every UI tick. Non-biometric.
    static let ephemeralPublicKey = "ephemeral.publicKey"
    /// Most recent signed delegation cert (JSON). Non-biometric.
    static let delegationCert = "delegation.cert"
    /// Optional hardware-wallet attestation (JSON). Non-biometric.
    static let hardwareAttestation = "hardwareAttestation"

    // MARK: -- backup / lockdown state

    /// Unix-seconds timestamp of last successful seed-phrase verification.
    /// Empty / absent means "never verified" and triggers the
    /// weekly-reminder banner. Non-biometric.
    static let verifiedAt = "backup.verifiedAt"
    /// Unix-seconds timestamp of the last weekly nudge we showed to an
    /// unverified user. Used to space reminders out at ~7-day intervals.
    /// Non-biometric.
    static let lastReminderAt = "backup.lastReminderAt"
    /// "1" iff the user has enabled irreversible Lockdown mode. Once
    /// set, the Show-recovery-phrase / Show-passphrase entries in
    /// Settings are permanently removed; the recovery phrase can only
    /// be re-obtained from a different recovery path (paper, iCloud).
    /// Non-biometric.
    static let lockdownEnabled = "backup.lockdownEnabled"

    /// "1" iff the user set a passphrase during onboarding (or during
    /// recovery). Non-biometric: lets the UI know whether to surface
    /// the "Show passphrase" entry without triggering Face ID on
    /// every render.
    static let hasPassphrase = "backup.hasPassphrase"

    // MARK: -- iCloud backup

    /// Unix-seconds timestamp of the last successful iCloud encrypted
    /// backup upload. Surfaced in Settings so the user can tell when
    /// the blob is up to date. Non-biometric.
    static let iCloudLastUploadAt = "icloud.lastUploadAt"
    /// CloudKit record ID of the encrypted backup, if any. Lets us
    /// update the existing record on subsequent uploads instead of
    /// creating duplicates. Non-biometric.
    static let iCloudRecordID = "icloud.recordID"
}

/// JSON-codable persistent form of the master recovery material.
/// Storing both fields together lets a single Face-ID-gated Keychain
/// read recover everything we need to re-derive the master.
struct MasterMaterialPersisted: Codable {
    let entropyHex: String
    let passphrase: String
}
