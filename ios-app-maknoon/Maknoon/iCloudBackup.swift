// Encrypted backup for the master recovery material.
//
// What gets written: AES-256-GCM(plaintext, key) where:
//   - plaintext is JSON of `{ v: 2, entropyHex, createdAt, settings,
//     lightningAccounts }` — passphrase is NEVER inside the blob,
//     it IS the encryption material
//   - key = PBKDF2-SHA256(passphrase, salt, 600_000 iter, 32 bytes)
// v3 blobs additionally carry an ML-DSA-65 signature over the AES
// ciphertext, produced by the user's master key. Restorers verify
// the signature before attempting decryption.
//
// The blob alone is useless without the passphrase. The passphrase
// alone is useless without the blob (or the offline paper phrase).
// This is the whole point: split the recovery material across two
// places, so losing one does not lose the wallet, but neither one
// alone leaks the wallet.
//
// Transport: a file on disk. The user picks the destination through
// the system file picker (iCloud Drive, On My iPhone, Files app
// providers like Dropbox / Google Drive, etc.). Replaces an earlier
// CloudKit-based path that needed iCloud-container entitlement
// provisioning per team / bundle and fell over with CKError 15 when
// the container wasn't fully configured. File-based is simpler,
// works on every team, and gives the user explicit control over
// where the bytes live.

import CryptoKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum BackupError: LocalizedError, CustomStringConvertible {
    case decryptFailed(String)
    case encryptFailed(String)
    case readFailed(String)

    var description: String {
        switch self {
        case .decryptFailed(let m): return "Decrypt failed: \(m)"
        case .encryptFailed(let m): return "Encrypt failed: \(m)"
        case .readFailed(let m):    return "Could not read backup file: \(m)"
        }
    }

    var errorDescription: String? { description }
}

/// Wire format for the encrypted blob. Versioned so we can evolve the
/// KDF or cipher in a later build without breaking restores.
///
/// v3 added the post-quantum authentication block: the encryptor
/// signs `combined` with their ML-DSA-65 master key. Restorers
/// verify that signature before attempting decryption (and cross-
/// check that the embedded master pubkey matches the master derived
/// from the decrypted entropy + passphrase). v1 and v2 blobs still
/// restore for backward compatibility, they just skip signature
/// verification.
struct EncryptedBackupBlob: Codable {
    let v: Int                // 1, 2, or 3
    let kdf: String           // "pbkdf2-sha256"
    let iter: Int             // 600_000
    let salt: String          // base64, 16 bytes
    let combined: String      // base64, AES.GCM.SealedBox.combined (nonce||ct||tag)
    let sigAlg: String?       // v3: "ML-DSA-65"
    let masterPk: String?     // v3: base64, 1952-byte ML-DSA-65 public key
    let signature: String?    // v3: base64, 3309-byte ML-DSA-65 signature over `combined`
}

/// Plaintext shape. Keep this lean: anything inside leaks if the
/// passphrase ever does.
///
/// Version history:
/// - v1: entropy only
/// - v2: added `settings` (SettingsBackup) and `lightningAccounts`.
/// - v4: added `credentials` (the holder's VC list + nicknames),
///       `idDocuments` (passport metadata + chip binaries + photos),
///       and opaque per-key UserDefaults dumps for the Bitcoin and
///       Ethereum wallet stores under `walletState`. (v3 reserved for
///       a parallel branch; not deployed.)
struct BackupPlaintext: Codable {
    let v: Int
    let entropyHex: String
    let createdAt: Int64
    let settings: SettingsBackup?
    let lightningAccounts: [LightningAccountWithSecret]?
    let credentials: HolderStore.CredentialsBackup?
    let idDocuments: IDDocumentStore.Backup?
    /// Opaque per-key dump of every wallet-related UserDefaults entry.
    /// Keys are the exact UserDefaults keys (`networks.bitcoin.wallets.v1`
    /// etc.); values are the base64-encoded raw bytes. Restoring just
    /// writes the bytes back. Keeps the backup forward-compatible with
    /// future schema changes in the wallet stores — nothing in
    /// iCloudBackup.swift needs to know wallet internals.
    let walletState: [String: String]?
}

/// A Lightning account plus the LNDHub password the Keychain
/// would otherwise hold. Only ever appears INSIDE the encrypted
/// backup blob, never in the YAML export.
struct LightningAccountWithSecret: Codable, Sendable {
    let account: LightningAccount
    let password: String
}

enum EncryptedBackup {

    // MARK: -- encrypt / decrypt

    /// UserDefaults keys captured (type-preserving) in the
    /// `walletState` map. The name is historical: it covers ALL
    /// device-protected state that should ride a restore, not just
    /// the wallet stores. Across every supported chain this is
    /// wallets + active selection + per-chain settings + token
    /// catalogs + custom networks, plus the global fiat and display
    /// preferences, the Apps registry, and the YubiKey FIDO2
    /// hmac-secret enrollment record needed to reproduce the wrapping
    /// key on a restored device.
    ///
    /// Deliberately excluded:
    ///   - `asset.price.cache.v1`: ephemeral, regenerates on the next
    ///     network call.
    ///   - `identity.knownIssuers.v1`, `devices.registered.v1`, and
    ///     other Settings-bundle keys: covered by the embedded
    ///     SettingsBackup snapshot.
    static let walletStateKeys: [String] = [
        "networks.bitcoin.wallets.v1",
        "networks.bitcoin.active.v1",
        "networks.bitcoin.settings.v1",
        "networks.bitcoin.labels.address.v1",
        "networks.bitcoin.labels.output.v1",
        "networks.ethereum.wallets.v2",
        "networks.ethereum.active.v1",
        "networks.ethereum.currentNetwork.v3",
        "networks.ethereum.tokens.v1",
        "networks.ethereum.tokens.catalog.v1",
        "networks.ethereum.tokens.catalogFetch.v1",
        "networks.ethereum.custom.v1",
        "networks.ethereum.settings.v1",
        "networks.solana.wallets.v1",
        "networks.solana.wallets.v2",
        "networks.solana.active.v1",
        "networks.solana.currentNetwork.v1",
        "networks.solana.settings.v1",
        "networks.solana.tokens.installed.v1",
        "networks.solana.tokens.catalog.v1",
        "networks.solana.tokens.catalogFetch.v1",
        "networks.tron.wallets.v1",
        "networks.tron.wallets.v2",
        "networks.tron.active.v1",
        "networks.tron.currentNetwork.v1",
        "networks.tron.settings.v1",
        "networks.tron.tokens.installed.v1",
        "networks.tron.tokens.catalog.v1",
        "networks.tron.tokens.catalogFetch.v1",
        // Chain-wide "current network" selection (String rawValues).
        "networks.ethereum.currentNetwork.chainwide.v1",
        "networks.solana.currentNetwork.chainwide.v1",
        "networks.tron.currentNetwork.chainwide.v1",
        // Hidden / ignored SPL tokens.
        "networks.solana.tokens.ignored.v1",
        // Global preferences (scalar values, round-tripped via the
        // type-preserving capture below).
        "app.fiatCurrencyCode",
        "app.fiatReferenceEnabled",
        "display.theme",
        "display.autoLock",
        "display.language",
        // Apps registry: configured catalogs + installed apps.
        "appstore.userStores.v1",
        "appstore.installed.v1",
        // YubiKey FIDO2 hmac-secret enrollment record.
        "yubikey.enrollments.v1",
    ]

    /// Snapshot the wallet-state UserDefaults keys into the opaque
    /// `walletState` map for inclusion in an encrypted backup.
    /// Returns nil when nothing is set; otherwise a base64-keyed map.
    ///
    /// Each value is captured type-preserving: we read the raw
    /// UserDefaults object (Data, String, Bool, Date, array, or
    /// dictionary) and serialize it as a binary property list wrapping
    /// `[key: value]`. This is what lets scalar keys (the `*.active.v1`
    /// wallet selections, the chain-wide network picks, the fiat and
    /// display preferences) round-trip; the older `data(forKey:)`
    /// capture silently dropped every non-Data value.
    static func captureWalletState() -> [String: String]? {
        var out: [String: String] = [:]
        for key in walletStateKeys {
            guard let value = UserDefaults.standard.object(forKey: key) else { continue }
            // Wrap in a single-entry dict so the plist root is always a
            // container (a bare scalar is not a valid plist root).
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: [key: value],
                format: .binary,
                options: 0
            ) else { continue }
            out[key] = data.base64EncodedString()
        }
        return out.isEmpty ? nil : out
    }

    /// Clean-slate apply of the wallet state from a backup. Wipes all
    /// listed UserDefaults keys, then writes the backup contents back.
    ///
    /// The in-memory @Observable stores do NOT pick this up on their
    /// own. The restore path MUST call `HolderStore.reloadAfterRestore()`
    /// (and `DisplayPreferences.reload()`) right after this so the live
    /// UI reflects the restored state without an app relaunch. See
    /// `RecoveryView.restoreFromFile`.
    ///
    /// Values written by current builds are binary property lists
    /// wrapping `[key: value]` (see `captureWalletState`). Legacy v4
    /// backups stored base64 of the raw JSON Data instead; we detect
    /// those by the absence of the binary-plist magic header and write
    /// the bytes back verbatim.
    static func applyWalletState(_ map: [String: String]?) {
        // Wipe every covered key first so a backup with a smaller
        // surface than the device still produces a clean state.
        for key in walletStateKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        guard let map else { return }
        for (key, b64) in map {
            guard walletStateKeys.contains(key),
                  let data = Data(base64Encoded: b64)
            else { continue }
            // New format: a binary plist begins with "bplist0". JSON
            // blobs (the only thing legacy backups stored under these
            // keys) never do, so the header is an unambiguous
            // discriminator.
            if data.starts(with: Array("bplist0".utf8)),
               let plist = try? PropertyListSerialization.propertyList(
                   from: data, options: [], format: nil) as? [String: Any],
               let value = plist[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                // Legacy raw-Data path.
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func encrypt(
        entropy: Data,
        passphrase: String,
        settings: SettingsBackup? = nil,
        lightningAccounts: [LightningAccountWithSecret]? = nil,
        credentials: HolderStore.CredentialsBackup? = nil,
        idDocuments: IDDocumentStore.Backup? = nil,
        walletState: [String: String]? = nil
    ) throws -> Data {
        var saltBytes = Data(count: 16)
        let status = saltBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BackupError.encryptFailed("SecRandomCopyBytes salt failed: \(status)")
        }

        let iterations: UInt32 = 600_000
        let keyBytes = try PBKDF2.derive(
            password: Data(passphrase.precomposedStringWithCompatibilityMapping.utf8),
            salt: saltBytes,
            iterations: iterations,
            hash: .sha256,
            outputLength: 32
        )
        let key = SymmetricKey(data: keyBytes)

        let plaintext = BackupPlaintext(
            v: 4,
            entropyHex: entropy.map { String(format: "%02x", $0) }.joined(),
            createdAt: Int64(Date().timeIntervalSince1970),
            settings: settings,
            lightningAccounts: lightningAccounts,
            credentials: credentials,
            idDocuments: idDocuments,
            walletState: walletState
        )
        let plainBytes = try JSONEncoder().encode(plaintext)

        let sealed = try AES.GCM.seal(plainBytes, using: key)
        guard let combined = sealed.combined else {
            throw BackupError.encryptFailed("AES.GCM.seal produced no combined output")
        }

        // Post-quantum authentication: ML-DSA-65 sign the AES-GCM
        // ciphertext with the user's master key. Same key the
        // Identity Sandwich uses; the seed is derived from
        // entropy + passphrase exactly as IdentitySandwich does at
        // provisioning time so we don't need to read it from
        // Keychain (no biometric prompt in the encrypt path).
        let mldsaSeed: Data
        let masterPk: Data
        let signature: Data
        do {
            mldsaSeed = try deriveMLDSASeed(entropy: entropy, passphrase: passphrase)
            masterPk = try MLDSAClient.masterPublicKey(fromSeed: mldsaSeed)
            signature = try MLDSAClient.signWithMaster(seed: mldsaSeed, message: combined)
        } catch {
            throw BackupError.encryptFailed("ML-DSA sign failed: \(error.localizedDescription)")
        }

        let blob = EncryptedBackupBlob(
            v: 3,
            kdf: "pbkdf2-sha256",
            iter: Int(iterations),
            salt: saltBytes.base64EncodedString(),
            combined: combined.base64EncodedString(),
            sigAlg: "ML-DSA-65",
            masterPk: masterPk.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        return try JSONEncoder().encode(blob)
    }

    /// Re-derive the 32-byte ML-DSA-65 master seed from BIP39
    /// entropy + passphrase. Mirrors the calculation
    /// `IdentitySandwich.buildAndPersist` does at provisioning
    /// time, so the same (entropy, passphrase) pair always yields
    /// the same master key.
    private static func deriveMLDSASeed(entropy: Data, passphrase: String) throws -> Data {
        let words = BIP39.mnemonicFromSeed(entropy)
        guard !words.isEmpty else {
            throw BackupError.encryptFailed("Could not derive BIP39 words from entropy")
        }
        let bip39Seed = try BIP39.derivedSeed(mnemonic: words, passphrase: passphrase)
        return Data(bip39Seed.prefix(32))
    }

    static func decrypt(_ blobData: Data, passphrase: String) throws -> Data {
        return try decryptFull(blobData, passphrase: passphrase).entropy
    }

    /// Full restore payload. Older backups (plaintext v1/v2) return
    /// nils for the v4 sections; the caller routes accordingly.
    struct DecryptedBackup {
        let entropy: Data
        let settings: SettingsBackup?
        let lightningAccounts: [LightningAccountWithSecret]?
        let credentials: HolderStore.CredentialsBackup?
        let idDocuments: IDDocumentStore.Backup?
        let walletState: [String: String]?
    }

    static func decryptFull(_ blobData: Data, passphrase: String) throws -> DecryptedBackup {
        let blob = try JSONDecoder().decode(EncryptedBackupBlob.self, from: blobData)
        guard (1...3).contains(blob.v), blob.kdf == "pbkdf2-sha256" else {
            throw BackupError.decryptFailed("Unsupported blob version \(blob.v) / kdf \(blob.kdf)")
        }
        guard let salt = Data(base64Encoded: blob.salt),
              let combined = Data(base64Encoded: blob.combined) else {
            throw BackupError.decryptFailed("Salt or ciphertext is not valid base64")
        }

        if blob.v == 3 {
            guard let sigAlg = blob.sigAlg, sigAlg == "ML-DSA-65" else {
                throw BackupError.decryptFailed("Unsupported signature algorithm")
            }
            guard let pkB64 = blob.masterPk, let pk = Data(base64Encoded: pkB64),
                  let sigB64 = blob.signature, let sig = Data(base64Encoded: sigB64) else {
                throw BackupError.decryptFailed("Signature block is malformed")
            }
            guard MLDSAClient.verify(publicKey: pk, signature: sig, message: combined) else {
                throw BackupError.decryptFailed("ML-DSA signature failed verification. The blob has been tampered with, or it was produced by a different master key.")
            }
        }

        let keyBytes = try PBKDF2.derive(
            password: Data(passphrase.precomposedStringWithCompatibilityMapping.utf8),
            salt: salt,
            iterations: UInt32(blob.iter),
            hash: .sha256,
            outputLength: 32
        )
        let key = SymmetricKey(data: keyBytes)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let plainBytes: Data
        do {
            plainBytes = try AES.GCM.open(sealed, using: key)
        } catch {
            throw BackupError.decryptFailed("Wrong passphrase, or tampered blob")
        }
        let plain = try JSONDecoder().decode(BackupPlaintext.self, from: plainBytes)
        // Accept the historical sequence 1, 2 and the current 4. v3 is
        // reserved for a parallel branch that never shipped.
        guard plain.v == 1 || plain.v == 2 || plain.v == 4 else {
            throw BackupError.decryptFailed("Unsupported plaintext version \(plain.v)")
        }
        guard let entropy = Data(hex: plain.entropyHex), entropy.count == 32 else {
            throw BackupError.decryptFailed("Plaintext entropy is not 32 bytes")
        }

        if blob.v == 3, let pkB64 = blob.masterPk, let embeddedPk = Data(base64Encoded: pkB64) {
            do {
                let derivedSeed = try deriveMLDSASeed(entropy: entropy, passphrase: passphrase)
                let derivedPk = try MLDSAClient.masterPublicKey(fromSeed: derivedSeed)
                guard derivedPk == embeddedPk else {
                    throw BackupError.decryptFailed("The master pubkey embedded in the backup doesn't match the one derived from this entropy + passphrase. Either the blob is corrupted, or this passphrase belongs to a different backup.")
                }
            } catch let e as BackupError {
                throw e
            } catch {
                throw BackupError.decryptFailed("Could not cross-check master pubkey: \(error.localizedDescription)")
            }
        }

        return DecryptedBackup(
            entropy: entropy,
            settings: plain.settings,
            lightningAccounts: plain.lightningAccounts,
            credentials: plain.credentials,
            idDocuments: plain.idDocuments,
            walletState: plain.walletState,
        )
    }

    // MARK: -- iCloud Drive

    /// Container identifier used by `iCloudDriveBackupsURLIfAvailable`.
    /// Must match the entitlement value and the App ID's container in
    /// the Apple Developer portal.
    static let iCloudContainerID = "iCloud.com.elabify.app.maknoon"

    /// Return the URL of the user's iCloud Drive Backups folder for
    /// this app, creating the folder if it doesn't yet exist.
    ///
    /// Returns `nil` when iCloud Drive isn't reachable, which covers
    /// all of:
    ///   - the app lacks the `CloudDocuments` entitlement (signing
    ///     time)
    ///   - the user is signed out of iCloud
    ///   - no network for the container's first-time setup
    ///   - the container itself is unreachable for whatever reason
    ///
    /// Used as the `directoryURL` hint when presenting the system
    /// document picker for the encrypted backup, so the picker opens
    /// at iCloud Drive by default. The user can always navigate to a
    /// different destination from there.
    static func iCloudDriveBackupsURLIfAvailable() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: iCloudContainerID
        ) else {
            return nil
        }
        let backupsDir = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: backupsDir,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        return backupsDir
    }

    // MARK: -- file-picker helpers

    /// `maknoon-backup-YYYYMMDD-HHmm.json`. The system picker uses
    /// this as the suggested filename; the user can edit it.
    static func defaultFilename(at date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmm"
        return "maknoon-backup-\(fmt.string(from: date)).json"
    }
}

/// Wraps the encrypted blob so SwiftUI's `fileExporter` and
/// `fileImporter` can hand it to the iOS document picker. The blob
/// is JSON-encoded, so we register as `.json` for both read and
/// write; that surfaces this file alongside other JSON in the
/// Files app and lets users browse / share it without a custom UTI.
struct MaknoonBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var blob: Data

    init(blob: Data) { self.blob = blob }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupError.readFailed("File has no contents")
        }
        self.blob = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: blob)
    }
}

// MARK: -- Picker with iCloud-default location

/// Present the system document picker so the user picks where to save
/// the encrypted backup. The picker defaults to iCloud Drive's
/// Maknoon → Backups folder when the container is reachable; the
/// user can navigate to any other Files-app destination from there.
///
/// We present `UIDocumentPickerViewController` *directly* on the
/// topmost view controller rather than wrapping it inside a SwiftUI
/// `.sheet { UIViewControllerRepresentable(...) }` because the latter
/// has a well-known UIKit/SwiftUI conflict: the picker briefly shows
/// inside the sheet's hosting controller, then auto-dismisses before
/// the user can interact with it. Direct UIKit presentation
/// sidesteps the conflict entirely.
///
/// `onCompletion` fires once: `(url, nil)` on success, `(nil, error)`
/// on a write failure setting up the temp file, `(nil, nil)` on user
/// cancel.
@MainActor
extension EncryptedBackup {
    static func presentBackupPicker(
        blob: Data,
        onCompletion: @escaping @MainActor (URL?, (any Error)?) -> Void
    ) {
        guard let topVC = topPresentingViewController() else {
            onCompletion(nil, BackupError.encryptFailed("Could not locate top view controller"))
            return
        }

        // Stage the blob in a temp file so the picker has something
        // to copy from. The temp directory is auto-cleaned by iOS;
        // we don't manually delete.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(defaultFilename())
        do {
            try blob.write(to: tempURL, options: .atomic)
        } catch {
            onCompletion(nil, error)
            return
        }

        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.allowsMultipleSelection = false
        if let iCloudDir = iCloudDriveBackupsURLIfAvailable() {
            // Hint the picker to open at iCloud Drive's Maknoon →
            // Backups folder. iOS respects this on first open; if
            // the user navigates elsewhere, the system remembers
            // that for future opens (standard Files behavior).
            picker.directoryURL = iCloudDir
        }

        // The picker's delegate isn't retained; we own the
        // coordinator and tie its lifetime to the picker via
        // associated objects so it stays alive until the picker
        // dismisses and the delegate callback fires.
        let coordinator = BackupPickerCoordinator(onCompletion: onCompletion)
        picker.delegate = coordinator
        objc_setAssociatedObject(
            picker,
            &BackupPickerCoordinator.associatedKey,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC,
        )

        topVC.present(picker, animated: true)
    }

    /// Walk the connected scenes to find the foreground key window's
    /// topmost presented view controller — the one we should present
    /// the picker on. Falls back through windows / scenes so we
    /// reliably find a presenter even in unusual app states.
    private static func topPresentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        guard let scene = activeScene else { return nil }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        var topVC: UIViewController? = window?.rootViewController
        while let presented = topVC?.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

/// Holds the `UIDocumentPickerDelegate` callbacks for a single
/// presentation. Retained by the picker via associated objects so it
/// stays alive until the picker dismisses.
private final class BackupPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    let onCompletion: @MainActor (URL?, (any Error)?) -> Void

    init(onCompletion: @escaping @MainActor (URL?, (any Error)?) -> Void) {
        self.onCompletion = onCompletion
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL],
    ) {
        let chosen = urls.first
        Task { @MainActor in onCompletion(chosen, nil) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in onCompletion(nil, nil) }
    }
}

// MARK: -- Data hex helper (decoder only, encoder lives elsewhere)

private extension Data {
    init?(hex: String) {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }
}
