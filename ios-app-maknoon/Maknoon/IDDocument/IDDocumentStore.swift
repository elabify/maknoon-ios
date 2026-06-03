// @Observable persistence for the user's saved ID documents.
//
// JSON metadata lives in UserDefaults; photos, signatures, and the
// raw chip blobs (SOD + each requested data group) live as files in
// the app's Documents directory keyed by UUID so the metadata stays
// small. Reset Wallet clears both.

import Foundation
import Observation
import UIKit

@Observable
final class IDDocumentStore {
    private(set) var documents: [IDDocument] = []

    private static let key = "iddocuments.v1"
    private static let photosDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("IDDocumentPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// Holds the signature JPEG plus raw SOD/DG bytes. Lives in a
    /// separate directory from photos so a "remove all signatures"
    /// or "evict chip blobs" sweep is a single recursive delete.
    private static let chipDataDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("IDDocumentChipData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { load() }

    // MARK: -- CRUD

    /// Persist a freshly-read document. Writes the photo and any raw
    /// chip blobs (SOD/DG1/DG2/...) to their own files; the IDDocument
    /// JSON keeps only filename references.
    func add(
        _ doc: IDDocument,
        photo: UIImage?,
        rawChipData: [String: Data] = [:]
    ) -> IDDocument {
        var copy = doc

        // The dir URLs are cached in static `let`s, so their one-time
        // createDirectory only runs on first access. A "Reset Wallet"
        // (HolderStore.resetEverything) deletes both directories
        // wholesale, leaving the cached URLs pointing at paths that no
        // longer exist; without this re-create, every atomic write
        // below fails silently and the photo + raw SOD/DG blobs are
        // lost (no card photo, on-device passive auth reports
        // sod_missing, and the issuer packet ships without dg2/sod).
        Self.ensureStorageDirectories()

        if let photo, let jpeg = photo.jpegData(compressionQuality: 0.85) {
            let filename = "\(doc.id.uuidString).jpg"
            // Only stamp the filename if the write actually landed, so a
            // failed write never leaves a reference to a missing file
            // (which renders as a card with no photo).
            do {
                try jpeg.write(to: Self.photosDir.appendingPathComponent(filename), options: .atomic)
                copy.photoFilename = filename
            } catch {
                // Leave photoFilename nil; the card falls back to the placeholder.
            }
        }

        for (group, bytes) in rawChipData {
            let filename = "\(doc.id.uuidString).\(group).bin"
            do {
                try bytes.write(to: Self.chipDataDir.appendingPathComponent(filename), options: .atomic)
            } catch {
                continue  // Skip unwritable groups; metadata stays nil.
            }
            switch group {
            case "sod":  copy.sodFilename  = filename
            case "dg1":  copy.dg1Filename  = filename
            case "dg2":  copy.dg2Filename  = filename
            case "dg11": copy.dg11Filename = filename
            case "dg12": copy.dg12Filename = filename
            case "dg15": copy.dg15Filename = filename
            default:     continue
            }
        }

        documents.append(copy)
        persist()
        return copy
    }

    func remove(id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        deleteFiles(for: documents[i])
        documents.remove(at: i)
        persist()
    }

    func setNickname(_ name: String?, for id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        documents[i].nickname = (trimmed?.isEmpty == false) ? trimmed : nil
        persist()
    }

    /// Store the result of an OpenSanctions screen for a document.
    /// Drives the shield badge on the card + the detail-view section.
    func setSanctionsResult(_ result: SanctionsScreenResult, for id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].sanctionsResult = result
        persist()
    }

    func setPassiveAuthResult(_ result: PassiveAuthResult, for id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].passiveAuthResult = result
        persist()
    }

    /// Load the photo image for a saved document. Decoded lazily so
    /// the list view can drop image memory when it scrolls offscreen.
    func photo(for doc: IDDocument) -> UIImage? {
        loadImage(filename: doc.photoFilename, directory: Self.photosDir)
    }

    /// Return the raw SOD bytes (CMS SignedData with the DSC inside),
    /// if captured. The issuer needs this to validate.
    func sodBytes(for doc: IDDocument) -> Data? {
        loadBytes(filename: doc.sodFilename)
    }

    /// Return raw bytes for a named data group. `group` is one of
    /// "dg1", "dg2", "dg11", "dg12", "dg15".
    func rawDataGroup(_ group: String, for doc: IDDocument) -> Data? {
        let filename: String? = {
            switch group {
            case "dg1":  return doc.dg1Filename
            case "dg2":  return doc.dg2Filename
            case "dg11": return doc.dg11Filename
            case "dg12": return doc.dg12Filename
            case "dg15": return doc.dg15Filename
            default:     return nil
            }
        }()
        return loadBytes(filename: filename)
    }

    func reset() {
        for doc in documents { deleteFiles(for: doc) }
        documents = []
        persist()
    }

    // MARK: -- file helpers

    /// Re-create the photo + chip-data directories if a wallet reset
    /// removed them after the static URLs were first cached. Cheap and
    /// idempotent (createDirectory is a no-op when the dir exists), so
    /// every write path calls this first rather than trusting the
    /// one-time static-`let` creation.
    private static func ensureStorageDirectories() {
        for dir in [photosDir, chipDataDir] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
    }

    private func deleteFiles(for doc: IDDocument) {
        if let filename = doc.photoFilename {
            try? FileManager.default.removeItem(
                at: Self.photosDir.appendingPathComponent(filename))
        }
        let chipFiles: [String?] = [
            doc.sodFilename,
            doc.dg1Filename,
            doc.dg2Filename,
            doc.dg11Filename,
            doc.dg12Filename,
            doc.dg15Filename,
        ]
        for filename in chipFiles.compactMap({ $0 }) {
            try? FileManager.default.removeItem(
                at: Self.chipDataDir.appendingPathComponent(filename))
        }
    }

    private func loadImage(filename: String?, directory: URL) -> UIImage? {
        guard let filename else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else {
            return nil
        }
        return UIImage(data: data)
    }

    private func loadBytes(filename: String?) -> Data? {
        guard let filename else { return nil }
        return try? Data(contentsOf: Self.chipDataDir.appendingPathComponent(filename))
    }

    // MARK: -- persistence

    /// Drop the in-memory cache and re-read metadata from UserDefaults.
    /// Used by the wallet-wide reset path so the wipe surfaces in the
    /// live UI without a force-quit. File-system content under
    /// `IDDocumentPhotos/` and `IDDocumentChipData/` is the caller's
    /// responsibility (HolderStore.resetEverything calls
    /// `reset()` first to delete the files, then this for orphans).
    func reload() {
        documents = []
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let docs = try? JSONDecoder().decode([IDDocument].self, from: data)
        else { return }
        documents = docs
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: -- backup snapshot / restore (full encrypted backup, v4)

    /// Encrypted-backup snapshot of every ID document this store
    /// holds. Carries both the metadata (UserDefaults JSON) and the
    /// on-disk binary content from IDDocumentChipData/ and
    /// IDDocumentPhotos/ as base64 blobs keyed by filename so a
    /// restore can re-create the exact filesystem layout.
    struct Backup: Codable, Sendable {
        let documents: [IDDocument]
        /// Filename → base64. Mirrors IDDocumentChipData/ exactly.
        let chipData: [String: String]
        /// Filename → base64. Mirrors IDDocumentPhotos/ exactly.
        let photos: [String: String]
    }

    func captureBackup() -> Backup {
        var chipData: [String: String] = [:]
        var photos: [String: String] = [:]
        if let chipFiles = try? FileManager.default.contentsOfDirectory(at: Self.chipDataDir, includingPropertiesForKeys: nil) {
            for url in chipFiles where url.isFileURL {
                if let bytes = try? Data(contentsOf: url) {
                    chipData[url.lastPathComponent] = bytes.base64EncodedString()
                }
            }
        }
        if let photoFiles = try? FileManager.default.contentsOfDirectory(at: Self.photosDir, includingPropertiesForKeys: nil) {
            for url in photoFiles where url.isFileURL {
                if let bytes = try? Data(contentsOf: url) {
                    photos[url.lastPathComponent] = bytes.base64EncodedString()
                }
            }
        }
        return Backup(documents: documents, chipData: chipData, photos: photos)
    }

    /// Clean-slate replace. Empties the chip-data + photo directories,
    /// drops the in-memory documents list, then writes back exactly
    /// what the backup carried. Any current ID-document state on this
    /// device is gone after this call.
    func applyBackup(_ backup: Backup) {
        // A reset may have removed the directories before a restore;
        // re-create them so the writes below land.
        Self.ensureStorageDirectories()
        // Wipe current state on disk first.
        if let chipFiles = try? FileManager.default.contentsOfDirectory(at: Self.chipDataDir, includingPropertiesForKeys: nil) {
            for url in chipFiles { try? FileManager.default.removeItem(at: url) }
        }
        if let photoFiles = try? FileManager.default.contentsOfDirectory(at: Self.photosDir, includingPropertiesForKeys: nil) {
            for url in photoFiles { try? FileManager.default.removeItem(at: url) }
        }
        documents = []
        // Restore binary files first so any UI read that races us
        // sees a consistent state (metadata + files together).
        for (filename, b64) in backup.chipData {
            if let bytes = Data(base64Encoded: b64) {
                try? bytes.write(to: Self.chipDataDir.appendingPathComponent(filename), options: .atomic)
            }
        }
        for (filename, b64) in backup.photos {
            if let bytes = Data(base64Encoded: b64) {
                try? bytes.write(to: Self.photosDir.appendingPathComponent(filename), options: .atomic)
            }
        }
        documents = backup.documents
        persist()
    }
}
