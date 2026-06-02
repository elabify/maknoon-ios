// Persisted metadata for a single Bitcoin wallet. This is the
// `BitcoinWalletStore`'s row type, NOT the BDK Descriptor (which is
// rebuilt on demand from `kind` + the Identity Sandwich seed, or from
// the cached xpub for a hardware-backed wallet).

import Foundation

struct BitcoinWalletDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    let kind: BitcoinWalletKind
    let network: BitcoinNetwork
    let createdAt: Date
    var lastSyncAt: Date?

    /// Cached BIP32 master fingerprint and account-level xpub for
    /// SOFTWARE wallets. Populated once at wallet creation under one
    /// biometric/passcode prompt to read the seed, then reused on
    /// every subsequent open so we can build a watch-only BDK
    /// descriptor WITHOUT touching the seed. The seed is only fetched
    /// again at SEND time, where a transient secret-descriptor wallet
    /// is built in-memory just to sign the PSBT and then discarded.
    ///
    /// Hardware wallets carry their own xpub/fingerprint inside
    /// `kind`. Legacy software wallets created before this cache
    /// existed have nil values here; the open path detects nil and
    /// falls back to seed derivation once, then populates the cache
    /// so future opens take the no-auth path.
    var cachedAccountFingerprint: String?
    var cachedAccountXpub: String?

    init(
        id: UUID = UUID(),
        label: String,
        kind: BitcoinWalletKind,
        network: BitcoinNetwork,
        createdAt: Date = .init(),
        lastSyncAt: Date? = nil,
        cachedAccountFingerprint: String? = nil,
        cachedAccountXpub: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.network = network
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.cachedAccountFingerprint = cachedAccountFingerprint
        self.cachedAccountXpub = cachedAccountXpub
    }

    /// BDK SQLite file URL inside Documents/. One database per wallet
    /// so concurrent syncs do not contend on the lock. The caller is
    /// responsible for actually creating the parent directory; see
    /// `ensureDatabaseDirectoryExists()`.
    ///
    /// Path is `Documents/networks/bitcoin/<wallet-id>/wallet.sqlite`
    /// so future chains (Lightning, Ethereum, Solana) get sibling
    /// `Documents/networks/<chain>/...` roots. Any prior
    /// `Documents/btc/...` files from before the Networks rename are
    /// orphaned; the user reseeds via Manage wallets > Discover.
    var databaseFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("networks", isDirectory: true)
            .appendingPathComponent("bitcoin", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        return dir.appendingPathComponent("wallet.sqlite")
    }

    /// Create the parent directory if missing. Throws if the directory
    /// cannot be created (filesystem out of space, permission denied,
    /// etc.) so the wallet-open failure has a clear cause.
    func ensureDatabaseDirectoryExists() throws {
        let dir = databaseFileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) { return }
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
