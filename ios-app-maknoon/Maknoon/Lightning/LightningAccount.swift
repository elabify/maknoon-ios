// One LNDHub-backed Lightning custodial account. The password is
// NOT stored on this struct — it lives in Keychain keyed by
// `lightning.password.<account.id>` so the account list can ship
// as plain UserDefaults JSON without leaking credentials.
//
// Multiple accounts are supported (Zeus-style "multi-wallet").
// Each account gets a unique thumbprint icon derived from the
// (serverURL, username) pair so the user can tell them apart at
// a glance.

import Foundation

struct LightningAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    /// LNDHub server base URL (https://...). The Lightning client
    /// appends `/auth`, `/balance`, `/payinvoice`, etc.
    var serverURL: String
    var username: String
    /// True = accept self-signed certs. The default is false (strict
    /// TLS); users who run their own hub with a self-signed cert
    /// enable this knowingly.
    var allowInsecureTLS: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        serverURL: String,
        username: String,
        allowInsecureTLS: Bool = false,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.label = label
        self.serverURL = serverURL
        self.username = username
        self.allowInsecureTLS = allowInsecureTLS
        self.createdAt = createdAt
    }

    /// Seed for the WalletThumbprint icon. Same (url, username)
    /// pair always renders the same icon so duplicate imports are
    /// visually obvious.
    var thumbprintSeed: String {
        return "\(serverURL.lowercased())|\(username.lowercased())"
    }

    /// `lndhub://login:password@host[:port][/path]` URL used by
    /// Zeus and most LNDHub front-ends for QR-encoded account
    /// import. Caller supplies the password — we don't keep it.
    func exportURL(password: String) -> String? {
        guard let comps = URLComponents(string: serverURL),
              let host = comps.host else { return nil }
        var url = "lndhub://\(username):\(password)@\(host)"
        if let port = comps.port { url += ":\(port)" }
        if !comps.path.isEmpty && comps.path != "/" { url += comps.path }
        return url
    }
}
