// Flat (single-level) user-created folders for the Identity tab's
// credential stack. Each folder has a UUID and a configurable name;
// membership is stored separately as a map of cardId -> folder UUID
// so a credential or scanned passport can move between folders
// without rewriting the folder records.
//
// Persistence: two UserDefaults keys, both JSON:
//   • credentialFolders.v1         [CredentialFolder]
//   • credentialFolderMembership.v1 [String: UUID]  // cardId -> folderId
//
// Folder IDs are stable across renames + restores; the membership
// map keys off WalletCardData.id (the namespaced "cred:<cid>" or
// "passport:<uuid>" string already used by the Identity ForEach) so
// both kinds of cards can live in the same folder.

import Foundation
import Observation

struct CredentialFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

@Observable
final class CredentialFolderStore {
    private(set) var folders: [CredentialFolder] = []
    private(set) var membership: [String: UUID] = [:]

    static let foldersKey = "credentialFolders.v1"
    static let membershipKey = "credentialFolderMembership.v1"

    init() { load() }

    // MARK: -- queries

    /// All `WalletCardData.id` strings assigned to the given folder.
    func cardIds(in folderId: UUID) -> Set<String> {
        var out: Set<String> = []
        for (cardId, fid) in membership where fid == folderId {
            out.insert(cardId)
        }
        return out
    }

    /// Folder a given card lives in, if any. `nil` = card is at the
    /// "All credentials" root.
    func folderId(forCard cardId: String) -> UUID? {
        membership[cardId]
    }

    /// Count of cards currently assigned to the folder. The Identity
    /// pill strip reads this for the trailing badge. Membership can
    /// drift if a credential is deleted without the caller cleaning
    /// up; that's harmless (orphaned mappings are filtered against
    /// the live walletCards list at render time).
    func count(in folderId: UUID) -> Int {
        membership.values.reduce(into: 0) { acc, fid in
            if fid == folderId { acc += 1 }
        }
    }

    // MARK: -- mutations

    @discardableResult
    func add(name: String) -> CredentialFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = CredentialFolder(
            name: trimmed.isEmpty ? "New folder" : trimmed
        )
        folders.append(folder)
        persistFolders()
        return folder
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[idx].name = trimmed.isEmpty ? folders[idx].name : trimmed
        persistFolders()
    }

    /// Reorder folders by moving the item at `from` so it sits where
    /// the item at `to` currently sits. Out-of-range indices and
    /// no-op moves are silently ignored. Order is persisted with the
    /// folders list itself, so the new sequence rides the encrypted
    /// backup unchanged.
    func move(from: Int, to: Int) {
        guard from != to,
              folders.indices.contains(from),
              folders.indices.contains(to)
        else { return }
        let item = folders.remove(at: from)
        folders.insert(item, at: to)
        persistFolders()
    }

    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        // Membership entries pointing at the removed folder are
        // dropped so the cards re-appear at the All-credentials root.
        for (cardId, fid) in membership where fid == id {
            membership.removeValue(forKey: cardId)
        }
        persistFolders()
        persistMembership()
    }

    /// Assign a card to a folder, or pass `to: nil` to move it back
    /// to the All-credentials root. Unknown folder ids are ignored
    /// (defensive: a stale picker selection from before a delete
    /// shouldn't reattach the card to nothing).
    func assign(cardId: String, to folderId: UUID?) {
        if let folderId {
            guard folders.contains(where: { $0.id == folderId }) else { return }
            membership[cardId] = folderId
        } else {
            membership.removeValue(forKey: cardId)
        }
        persistMembership()
    }

    /// Encrypted-backup restore path: bulk replace folders + the
    /// membership map atomically. Caller is responsible for calling
    /// reload() after; this writes UserDefaults but does not
    /// reassign the in-memory observable arrays.
    func applyBackup(folders: [CredentialFolder], membership: [String: UUID]) {
        self.folders = folders
        self.membership = membership
        persistFolders()
        persistMembership()
    }

    // MARK: -- persistence

    /// Drop the in-memory cache and re-read from UserDefaults. Used
    /// by the wallet-wide reset path (now-empty defaults yields empty
    /// state) and the backup-restore path (defaults were just
    /// written; this re-reads them into @Observable storage).
    func reload() {
        folders = []
        membership = [:]
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.foldersKey),
           let decoded = try? JSONDecoder().decode([CredentialFolder].self, from: data) {
            folders = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.membershipKey),
           let decoded = try? JSONDecoder().decode([String: UUID].self, from: data) {
            membership = decoded
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: Self.foldersKey)
        }
    }

    private func persistMembership() {
        if let data = try? JSONEncoder().encode(membership) {
            UserDefaults.standard.set(data, forKey: Self.membershipKey)
        }
    }
}
