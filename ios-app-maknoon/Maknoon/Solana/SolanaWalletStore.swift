// User's list of Solana wallets plus the per-wallet "currently
// viewed cluster" selection. Mirrors EthereumWalletStore: the
// descriptor itself is cluster-agnostic (the same Ed25519 keypair
// works on mainnet, devnet, and testnet), and the user's "I'm
// looking at mainnet right now" choice lives in a separate UUID
// -> SolanaNetwork map. Persists to UserDefaults under the
// `networks.solana.*` namespace so future chain expansion stays
// sibling-compatible with the Ethereum design.

import Foundation
import Observation
import SwiftUI

/// Solana cluster. The wallet's keypair derivation is identical on
/// every cluster; the only thing that changes per chip switch is
/// which RPC + explorer + balance pool the dashboard talks to.
enum SolanaNetwork: String, Codable, CaseIterable, Sendable, Hashable {
    case mainnet
    case devnet
    case testnet

    var displayName: String {
        switch self {
        // Solana's network ID is "mainnet-beta" on the wire, but
        // users expect "Mainnet" in UI strings; keep the Beta tag
        // out of every dashboard, picker, and tx-row.
        case .mainnet: return "Mainnet"
        case .devnet:  return "Devnet"
        case .testnet: return "Testnet"
        }
    }

    /// Default JSON-RPC endpoint per cluster. User-overridable via
    /// SolanaSettings.
    var defaultRpcURL: String {
        switch self {
        case .mainnet: return "https://api.mainnet-beta.solana.com"
        case .devnet:  return "https://api.devnet.solana.com"
        case .testnet: return "https://api.testnet.solana.com"
        }
    }

    /// Default block explorer per cluster.
    var defaultExplorerURL: String {
        switch self {
        case .mainnet: return "https://explorer.solana.com"
        case .devnet:  return "https://explorer.solana.com?cluster=devnet"
        case .testnet: return "https://explorer.solana.com?cluster=testnet"
        }
    }

    /// CoinGecko id for spot pricing. Nil on devnet/testnet (no real
    /// market, no fiat caption). Mirrors EthereumNetwork.coinGeckoAssetId.
    var coinGeckoAssetId: String? {
        switch self {
        case .mainnet: return "solana"
        case .devnet, .testnet: return nil
        }
    }
}

/// Discriminator for how a Solana wallet was created. Software
/// wallets derive from the master seed at BIP44 m/44'/501'/account'/0'
/// (Solana / Ed25519 / SLIP-0010). Hardware wallets cache the public
/// key captured at pair time so balance reads don't need the device.
enum SolanaWalletKind: Codable, Hashable, Sendable {
    case software(account: UInt32)
    case hardware(deviceId: UUID, account: UInt32, publicKeyBase58: String)
}

/// Persisted metadata for one Solana wallet. The on-chain account
/// state is fetched at runtime; this struct only carries what's
/// needed to derive (or look up) the address and to label the row.
///
/// The cluster the user is currently viewing the wallet on is NOT
/// stored here; it lives in `SolanaWalletStore.currentNetworkByWallet`
/// so a single wallet can flip between mainnet/devnet/testnet without
/// rewriting the descriptor. The legacy `network` field on disk is
/// migrated forward via the v1 decoder below.
struct SolanaWalletDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    let kind: SolanaWalletKind
    let createdAt: Date
    var lastSyncAt: Date?

    init(
        id: UUID = UUID(),
        label: String,
        kind: SolanaWalletKind,
        createdAt: Date = .init(),
        lastSyncAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
    }

    // Tolerant decoder: silently drops the obsolete `network`
    // field if it's present so v1 records load without throwing.
    // The network value itself is peeled off during the v1 -> v2
    // migration in `SolanaWalletStore.load()` and recorded into
    // `currentNetworkByWallet`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.kind = try c.decode(SolanaWalletKind.self, forKey: .kind)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }
}

/// Optimistic in-memory representation of a Solana tx we know about
/// but RPC has not yet returned as confirmed. Mirror of
/// `PendingTronTx`. Surfaced as a "Pending" row at the top of the
/// wallet's transaction list immediately after broadcast.
struct PendingSolanaTx: Hashable, Identifiable, Sendable {
    enum Direction: Sendable, Hashable { case `in`, out }

    let signature: String
    let direction: Direction
    /// Sender (for inbound) or recipient (for outbound).
    let counterparty: String
    /// Native lamports delta (signed). Used when `tokenMint` is nil.
    /// For SPL transfers, reused as the raw on-chain token amount
    /// so the display row formats correctly via `tokenDecimals`.
    let lamports: Int64
    /// Non-nil for SPL token sends; the mint pubkey.
    let tokenMint: String?
    /// SPL token symbol for display.
    let tokenSymbol: String?
    /// SPL decimals.
    let tokenDecimals: UInt8?
    let broadcastAt: Date

    var id: String { signature }
}

@Observable
final class SolanaWalletStore {
    private(set) var wallets: [SolanaWalletDescriptor] = []
    private(set) var activeWalletId: UUID?
    /// Per-wallet "I'm currently looking at this cluster" selection.
    /// Kept around for backwards-compat with the v2 storage, but
    /// the live UI now reads from the chain-wide `currentNetwork`
    /// below — switching wallets keeps the chip pointed wherever
    /// the user last set it, per UX request.
    private(set) var currentNetworkByWallet: [UUID: SolanaNetwork] = [:]
    /// Chain-wide "current cluster" chip. One source of truth for
    /// the network picker, shared across every Solana wallet so
    /// switching wallets doesn't reset the user's selection.
    /// Persisted under `currentChainNetworkKey`; defaults to
    /// mainnet on first launch.
    private(set) var currentNetwork: SolanaNetwork = .mainnet

    /// In-memory map of (wallet UUID) → pending txs the user has
    /// broadcast but the RPC has not yet returned as confirmed.
    /// Surfaced by the wallet view as an optimistic "Pending" row.
    /// Not persisted: a relaunch reloads from RPC.
    private(set) var pendingTxsByWallet: [UUID: [PendingSolanaTx]] = [:]

    /// v1: per-wallet descriptor carried its own `network` field.
    /// v2: descriptor is cluster-agnostic; cluster lived in the
    /// per-wallet `currentNetworkByWallet` map (still readable for
    /// migration). v3 adds a chain-wide `currentNetwork` that the
    /// picker reads from.
    private static let walletsKeyV1 = "networks.solana.wallets.v1"
    private static let walletsKeyV2 = "networks.solana.wallets.v2"
    private static let networkMapKey = "networks.solana.currentNetwork.v1"
    private static let currentChainNetworkKey = "networks.solana.currentNetwork.chainwide.v1"
    private static let activeKey    = "networks.solana.active.v1"

    init() {
        load()
    }

    var activeWallet: SolanaWalletDescriptor? {
        guard let id = activeWalletId else { return wallets.first }
        return wallets.first(where: { $0.id == id }) ?? wallets.first
    }

    /// Cluster the user is currently viewing. Reads from the
    /// chain-wide `currentNetwork`; the `walletId` parameter is
    /// kept for source compatibility with call sites that haven't
    /// migrated yet but is now ignored.
    func activeNetwork(for walletId: UUID) -> SolanaNetwork {
        _ = walletId
        return currentNetwork
    }

    /// Update the chain-wide cluster selection. Persists immediately.
    /// The walletId is recorded against `currentNetworkByWallet` too
    /// so legacy code paths that still inspect that map see a
    /// consistent value.
    func setActiveNetwork(walletId: UUID, network: SolanaNetwork) {
        currentNetwork = network
        currentNetworkByWallet[walletId] = network
        persist()
    }

    // MARK: -- pending tx tracking (mirrors TronWalletStore)

    /// Mark a freshly-broadcast tx as pending on the sender's
    /// wallet. The wallet view renders it at the top of the
    /// transactions list until the next refresh observes it on
    /// chain. If the recipient address belongs to another hardware
    /// Solana wallet on this device, ALSO mirrors as a pending
    /// inbound on that wallet.
    func markPendingOutbound(
        senderWalletId: UUID,
        signature: String,
        senderAddress: String,
        recipientAddress: String,
        lamports: Int64,
        tokenMint: String? = nil,
        tokenSymbol: String? = nil,
        tokenDecimals: UInt8? = nil
    ) {
        let outbound = PendingSolanaTx(
            signature: signature,
            direction: .out,
            counterparty: recipientAddress,
            lamports: lamports,
            tokenMint: tokenMint,
            tokenSymbol: tokenSymbol,
            tokenDecimals: tokenDecimals,
            broadcastAt: Date()
        )
        appendPending(walletId: senderWalletId, tx: outbound)

        if let mirroredId = walletIdForAddress(recipientAddress), mirroredId != senderWalletId {
            let inbound = PendingSolanaTx(
                signature: signature,
                direction: .in,
                counterparty: senderAddress,
                lamports: lamports,
                tokenMint: tokenMint,
                tokenSymbol: tokenSymbol,
                tokenDecimals: tokenDecimals,
                broadcastAt: Date()
            )
            appendPending(walletId: mirroredId, tx: inbound)
        }
    }

    /// Drop any pending entries whose signature now appears in the
    /// confirmed list, plus pendings older than 3 minutes (presumed
    /// orphaned). Called by `SolanaWalletView.refresh` after each
    /// network round-trip.
    func dropConfirmedPending(walletId: UUID, confirmedSignatures: Set<String>) {
        guard var list = pendingTxsByWallet[walletId] else { return }
        let cutoff = Date().addingTimeInterval(-3 * 60)
        list.removeAll { tx in
            confirmedSignatures.contains(tx.signature) || tx.broadcastAt < cutoff
        }
        if list.isEmpty {
            pendingTxsByWallet.removeValue(forKey: walletId)
        } else {
            pendingTxsByWallet[walletId] = list
        }
    }

    private func appendPending(walletId: UUID, tx: PendingSolanaTx) {
        var list = pendingTxsByWallet[walletId] ?? []
        if list.contains(where: { $0.signature == tx.signature }) { return }
        list.insert(tx, at: 0)
        pendingTxsByWallet[walletId] = list
    }

    /// Resolve a base58 pubkey to a wallet id we know about.
    /// Hardware descriptors carry the address directly; software
    /// wallets do not (deriving needs the sandwich), so this only
    /// auto-mirrors to hardware wallets.
    private func walletIdForAddress(_ address: String) -> UUID? {
        for w in wallets {
            if case .hardware(_, _, let addr) = w.kind, addr == address {
                return w.id
            }
        }
        return nil
    }

    /// Weak ref to the user's address book. Wired by HolderStore.init
    /// after both stores are constructed.
    weak var addressBook: AddressBookStore?

    func add(_ descriptor: SolanaWalletDescriptor, initialNetwork: SolanaNetwork = .mainnet, makeActive: Bool = true) {
        wallets.append(descriptor)
        currentNetworkByWallet[descriptor.id] = initialNetwork
        if makeActive { activeWalletId = descriptor.id }
        persist()
        mirrorToAddressBook(descriptor)
    }

    func setActive(_ id: UUID) {
        guard wallets.contains(where: { $0.id == id }) else { return }
        activeWalletId = id
        persist()
    }

    func remove(id: UUID) {
        wallets.removeAll { $0.id == id }
        currentNetworkByWallet.removeValue(forKey: id)
        if activeWalletId == id { activeWalletId = wallets.first?.id }
        persist()
        addressBook?.removeSystemWallet(walletId: id, chainKey: "solana")
    }

    /// Mirror a wallet into the user's address book as a read-only
    /// system entry. Hardware wallets carry their pubkey on the
    /// descriptor; software wallets don't, so their mirror entry
    /// is populated by `SolanaWalletView.refresh()` once the
    /// address has been derived.
    fileprivate func mirrorToAddressBook(_ descriptor: SolanaWalletDescriptor) {
        guard let addressBook else { return }
        let address: String
        switch descriptor.kind {
        case .software:
            return
        case .hardware(_, _, let pubkeyBase58):
            address = pubkeyBase58
        }
        addressBook.upsertSystemWallet(
            walletId: descriptor.id,
            chainKey: "solana",
            name: descriptor.label,
            address: address,
            network: .solana
        )
    }

    /// Externally-triggered mirror update. Called by SolanaWalletView
    /// after refresh resolves the software-wallet address so the
    /// address-book mirror can populate without an extra biometric
    /// prompt.
    func updateMirrorAddress(walletId: UUID, address: String) {
        guard let addressBook,
              let descriptor = wallets.first(where: { $0.id == walletId })
        else { return }
        addressBook.upsertSystemWallet(
            walletId: walletId,
            chainKey: "solana",
            name: descriptor.label,
            address: address,
            network: .solana
        )
    }

    func remirrorAllToAddressBook() {
        for descriptor in wallets {
            mirrorToAddressBook(descriptor)
        }
    }

    /// User-driven reorder from the wallet-list edit mode.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        wallets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func rename(id: UUID, to label: String) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].label = label
        persist()
    }

    func markSynced(id: UUID, at date: Date = .init()) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].lastSyncAt = date
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(wallets) {
            UserDefaults.standard.set(data, forKey: Self.walletsKeyV2)
        }
        persistNetworkMap()
        UserDefaults.standard.set(currentNetwork.rawValue, forKey: Self.currentChainNetworkKey)
        if let id = activeWalletId {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    private func persistNetworkMap() {
        var raw: [String: SolanaNetwork] = [:]
        for (id, net) in currentNetworkByWallet {
            raw[id.uuidString] = net
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.networkMapKey)
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        wallets = []
        activeWalletId = nil
        currentNetworkByWallet = [:]
        currentNetwork = .mainnet
        pendingTxsByWallet = [:]
        load()
    }

    private func load() {
        // Preferred path: v2 descriptor list + a separate cluster map.
        if let data = UserDefaults.standard.data(forKey: Self.walletsKeyV2),
           let list = try? JSONDecoder().decode([SolanaWalletDescriptor].self, from: data) {
            self.wallets = list
            if let mapData = UserDefaults.standard.data(forKey: Self.networkMapKey),
               let raw = try? JSONDecoder().decode([String: SolanaNetwork].self, from: mapData) {
                var out: [UUID: SolanaNetwork] = [:]
                for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
                self.currentNetworkByWallet = out
            }
            if let s = UserDefaults.standard.string(forKey: Self.activeKey),
               let id = UUID(uuidString: s) {
                self.activeWalletId = id
            }
            // Chain-wide current network: prefer the v3 standalone
            // value; fall back to the active wallet's per-wallet
            // entry; otherwise mainnet.
            if let raw = UserDefaults.standard.string(forKey: Self.currentChainNetworkKey),
               let net = SolanaNetwork(rawValue: raw) {
                self.currentNetwork = net
            } else if let id = activeWalletId, let net = currentNetworkByWallet[id] {
                self.currentNetwork = net
            }
            return
        }

        // v1 migration: descriptor carried `network`; peel it off
        // into the new map and re-persist under v2.
        if let data = UserDefaults.standard.data(forKey: Self.walletsKeyV1),
           let v1List = try? JSONDecoder().decode([V1Descriptor].self, from: data) {
            var migrated: [SolanaWalletDescriptor] = []
            var networkMap: [UUID: SolanaNetwork] = [:]
            for entry in v1List {
                let d = SolanaWalletDescriptor(
                    id: entry.id,
                    label: entry.label,
                    kind: entry.kind,
                    createdAt: entry.createdAt,
                    lastSyncAt: entry.lastSyncAt
                )
                migrated.append(d)
                networkMap[d.id] = entry.network
            }
            self.wallets = migrated
            self.currentNetworkByWallet = networkMap
            if let s = UserDefaults.standard.string(forKey: Self.activeKey),
               let id = UUID(uuidString: s),
               wallets.contains(where: { $0.id == id }) {
                self.activeWalletId = id
            }
            persist()
            // v1 key intentionally not deleted: a downgrade still
            // finds the original data.
            return
        }
    }

    /// v1 descriptor with the now-removed `network` field. Decoded
    /// once at migration time and never written again.
    private struct V1Descriptor: Codable {
        let id: UUID
        var label: String
        let kind: SolanaWalletKind
        var network: SolanaNetwork
        let createdAt: Date
        var lastSyncAt: Date?
    }
}
