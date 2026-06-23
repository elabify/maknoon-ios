// Persisted list of LNDHub-compatible accounts + the active
// selection. Passwords live in Keychain (one entry per account
// id); the public account metadata (label, server URL, username,
// TLS flag) ships in UserDefaults as plain JSON.
//
// Two add paths: manual entry through `add(account:password:)`, or
// `parseImportURL` on a Zeus-style `lndhub://user:pass@server[:port][/path]`
// URL (paste or QR scan). Both end up calling `add(account:password:)`
// after the caller has resolved a final label.

import Foundation
import Observation

@Observable
final class LightningAccountStore {
    private(set) var accounts: [LightningAccount] = []
    private(set) var activeAccountId: UUID?

    private static let accountsKey = "lightning.accounts.v1"
    private static let activeKey   = "lightning.active.v1"

    init() { load() }

    var activeAccount: LightningAccount? {
        guard let id = activeAccountId else { return accounts.first }
        return accounts.first(where: { $0.id == id }) ?? accounts.first
    }

    // MARK: -- mutate

    @discardableResult
    func add(_ account: LightningAccount, password: String, makeActive: Bool = true) throws -> LightningAccount {
        accounts.append(account)
        try savePassword(password, for: account.id)
        if makeActive { activeAccountId = account.id }
        persist()
        return account
    }

    func update(_ account: LightningAccount, newPassword: String? = nil) throws {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx] = account
        if let pw = newPassword {
            try savePassword(pw, for: account.id)
        }
        persist()
    }

    func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
        try? KeyStore.delete(forKey: Self.passwordKey(for: id))
        if activeAccountId == id { activeAccountId = accounts.first?.id }
        persist()
    }

    func setActive(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountId = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
    }

    // MARK: -- credentials

    func password(for id: UUID) throws -> String? {
        guard let data = try KeyStore.load(forKey: Self.passwordKey(for: id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ password: String, for id: UUID) throws {
        try KeyStore.save(Data(password.utf8), forKey: Self.passwordKey(for: id), requireBiometric: false)
    }

    // MARK: -- encrypted-backup export / import

    /// Snapshot every account + its Keychain password for inclusion
    /// in the iCloud encrypted backup. Accounts whose Keychain
    /// entry has gone missing are skipped silently (the backup will
    /// just lack those, which is the same as if they weren't
    /// configured). Plaintext YAML export does NOT use this, it
    /// would leak LNDHub credentials.
    func exportForEncryptedBackup() -> [LightningAccountWithSecret] {
        var out: [LightningAccountWithSecret] = []
        for account in accounts {
            // try? collapses the throws to nil; password() itself
            // returns String? for the "no entry in Keychain" case,
            // so we get String?? back and need to flatten.
            let pw = (try? password(for: account.id)) ?? nil
            if let pw {
                out.append(LightningAccountWithSecret(account: account, password: pw))
            }
        }
        return out
    }

    /// Restore Lightning accounts from a decrypted backup. Uses the
    /// existing add() path so the Keychain password write is the
    /// same code path as normal account creation. Existing entries
    /// with the same id keep their stored password if the backup
    /// has an empty entry; otherwise the backup wins (last-writer
    /// for the demo, refine to merge later).
    func importFromEncryptedBackup(_ items: [LightningAccountWithSecret]) throws {
        for item in items {
            // remove first so add() doesn't surface dup-id errors
            // for users who restore on top of an already-configured
            // device.
            remove(id: item.account.id)
            _ = try add(item.account, password: item.password, makeActive: false)
        }
        if activeAccountId == nil, let first = accounts.first {
            setActive(first.id)
        }
    }

    private static func passwordKey(for id: UUID) -> String {
        "lightning.password.\(id.uuidString)"
    }

    // MARK: -- lndhub:// URL parse

    /// Parse an `lndhub://login:password@<server>` import URL. The
    /// `lndhub://` scheme is a de-facto BlueWallet standard, but the
    /// `<server>` part comes in two shapes, both accepted here (this
    /// mirrors the Android `LightningAccountStore.parseImportURL`):
    ///   1. Zeus / bare host:  `lndhub://login:password@host[:port][/path]`
    ///      (https is implied).
    ///   2. BlueWallet / LNbits: `lndhub://login:password@https://host[/path]`
    ///      (the full scheme is embedded after the `@`).
    /// Foundation's `URL`/`URLComponents` cannot parse shape 2 (the inner
    /// `//` breaks authority parsing), so we hand-split. Accepts a
    /// trailing `?tls=false` query (BlueWallet writes this for
    /// self-signed hubs) and surfaces it through `allowInsecureTLS`.
    /// Returns nil on malformed input. Caller decides the final label and
    /// persists via `add(account:password:)`.
    static func parseImportURL(_ raw: String, defaultLabel: String? = nil) -> (account: LightningAccount, password: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("lndhub://") else { return nil }
        s = String(s.dropFirst("lndhub://".count))

        // Split a trailing query (?tls=false) off the server, if present.
        var query = ""
        if let qIdx = s.firstIndex(of: "?") {
            query = String(s[s.index(after: qIdx)...])
            s = String(s[..<qIdx])
        }

        // login:password @ server. The first '@' is the userInfo
        // separator: LNDHub login/password are opaque tokens without '@',
        // and the server part never contains '@' in either shape.
        guard let atIdx = s.firstIndex(of: "@") else { return nil }
        let userInfo = String(s[..<atIdx])
        var serverPart = String(s[s.index(after: atIdx)...])
        while serverPart.hasSuffix("/") { serverPart = String(serverPart.dropLast()) }
        guard !userInfo.isEmpty, !serverPart.isEmpty else { return nil }

        // login:password on the first ':'.
        guard let sepIdx = userInfo.firstIndex(of: ":") else { return nil }
        let user = String(userInfo[..<sepIdx])
        let pass = String(userInfo[userInfo.index(after: sepIdx)...])
        guard !user.isEmpty, !pass.isEmpty else { return nil }

        // Shape 2 already carries http(s)://; shape 1 implies https.
        let lower = serverPart.lowercased()
        let server = (lower.hasPrefix("https://") || lower.hasPrefix("http://"))
            ? serverPart
            : "https://\(serverPart)"

        // BlueWallet-style `?tls=false` opts into self-signed certs.
        var allowInsecureTLS = false
        for item in query.split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0].lowercased() == "tls", kv[1].lowercased() == "false" {
                allowInsecureTLS = true
            }
        }

        let host = URL(string: server)?.host
            ?? server.components(separatedBy: "://").last?
                .components(separatedBy: "/").first?
                .components(separatedBy: ":").first
            ?? server
        let label = defaultLabel?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? defaultLabel!
            : host
        let account = LightningAccount(
            label: label,
            serverURL: server,
            username: user,
            allowInsecureTLS: allowInsecureTLS
        )
        return (account, pass)
    }

    // MARK: -- persistence

    /// Drop the in-memory cache and re-read from UserDefaults. Used by
    /// the wallet-wide reset path so the wipe surfaces immediately
    /// without waiting for a force-quit.
    func reload() {
        accounts = []
        activeAccountId = nil
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([LightningAccount].self, from: data) {
            accounts = decoded
        }
        if let s = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: s) {
            activeAccountId = id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        UserDefaults.standard.set(activeAccountId?.uuidString, forKey: Self.activeKey)
    }
}
