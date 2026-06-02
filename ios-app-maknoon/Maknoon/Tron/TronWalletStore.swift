// User's list of Tron wallets plus the per-wallet "currently viewed
// network" selection. Mirrors SolanaWalletStore: the descriptor is
// network-agnostic for keypair derivation (mainnet / Shasta / Nile
// share the same key), and the user's "I'm looking at mainnet right
// now" choice lives in a separate UUID -> TronNetwork map.

import Foundation
import Observation
import SwiftUI

enum TronNetwork: String, Codable, CaseIterable, Sendable, Hashable {
    case mainnet
    case shasta
    case nile

    var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .shasta:  return "Shasta"
        case .nile:    return "Nile"
        }
    }

    /// Default TronGrid endpoint. User-overridable in Tron Settings.
    var defaultRpcURL: String {
        switch self {
        case .mainnet: return "https://api.trongrid.io"
        case .shasta:  return "https://api.shasta.trongrid.io"
        case .nile:    return "https://api.nileex.io"
        }
    }

    var defaultExplorerURL: String {
        switch self {
        case .mainnet: return "https://tronscan.org"
        case .shasta:  return "https://shasta.tronscan.org"
        case .nile:    return "https://nile.tronscan.org"
        }
    }

    /// CoinGecko id for the fiat caption. Mainnet only; testnets
    /// stay silent (no real market). Mirrors EthereumNetwork +
    /// SolanaNetwork accessor of the same name.
    var coinGeckoAssetId: String? {
        switch self {
        case .mainnet: return "tron"
        case .shasta, .nile: return nil
        }
    }
}

enum TronWalletKind: Codable, Hashable, Sendable {
    case software(account: UInt32)
    /// Hardware wallet (Ledger only; Trezor firmware does not
    /// implement Tron). `addressBase58Check` is the T-prefixed
    /// 34-char address cached at pair time.
    case hardware(deviceId: UUID, account: UInt32, addressBase58Check: String)
}

struct TronWalletDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    let kind: TronWalletKind
    let createdAt: Date
    var lastSyncAt: Date?

    init(
        id: UUID = UUID(),
        label: String,
        kind: TronWalletKind,
        createdAt: Date = .init(),
        lastSyncAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
    }

    // Tolerant decoder so v1 records that carried a `network` field
    // load cleanly on first launch after the v2 migration. The
    // network itself is peeled off in `TronWalletStore.load()` and
    // recorded into `currentNetworkByWallet`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.kind = try c.decode(TronWalletKind.self, forKey: .kind)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }
}

/// Optimistic in-memory representation of a transaction we know
/// about but TronGrid has not yet returned as confirmed. Surfaced as
/// a "Pending" row at the top of the wallet's transaction list
/// immediately after broadcast. Dropped on the next refresh that
/// observes the same txID in the canonical confirmed feed.
struct PendingTronTx: Hashable, Identifiable, Sendable {
    enum Direction: Sendable, Hashable { case `in`, out }

    let txID: String
    let direction: Direction
    /// Sender (for inbound) or recipient (for outbound).
    let counterparty: String
    /// Native TRX amount in sun. Used when `tokenContract` is nil.
    let sunAmount: Int64
    /// Non-nil for TRC-20 sends; the raw on-chain contract address.
    let tokenContract: String?
    /// TRC-20 symbol for display.
    let tokenSymbol: String?
    /// TRC-20 decimals.
    let tokenDecimals: UInt8?
    let broadcastAt: Date

    var id: String { txID }
}

@Observable
final class TronWalletStore {
    private(set) var wallets: [TronWalletDescriptor] = []
    private(set) var activeWalletId: UUID?
    /// Per-wallet network map. Read-only at runtime now; the live
    /// picker uses the chain-wide `currentNetwork` below so a
    /// wallet switch keeps the user's selection sticky.
    private(set) var currentNetworkByWallet: [UUID: TronNetwork] = [:]
    /// Chain-wide "current network" chip. One source of truth
    /// shared across every Tron wallet so switching wallets
    /// doesn't reset the user's selection. Persisted under
    /// `currentChainNetworkKey`.
    private(set) var currentNetwork: TronNetwork = .mainnet

    /// In-memory map of (wallet UUID) → pending outbound/inbound txs
    /// the user has broadcast or is expecting, but TronGrid has not
    /// yet returned them as confirmed. Used by the wallet view's
    /// transactions list to render an optimistic "Pending" row right
    /// after broadcast, before the next refresh observes the tx
    /// on-chain. Not persisted: a relaunch reloads from TronGrid,
    /// which is the source of truth once a tx is in a block.
    private(set) var pendingTxsByWallet: [UUID: [PendingTronTx]] = [:]

    private static let walletsKeyV1 = "networks.tron.wallets.v1"
    private static let walletsKeyV2 = "networks.tron.wallets.v2"
    private static let networkMapKey = "networks.tron.currentNetwork.v1"
    private static let currentChainNetworkKey = "networks.tron.currentNetwork.chainwide.v1"
    private static let activeKey    = "networks.tron.active.v1"

    init() {
        load()
    }

    var activeWallet: TronWalletDescriptor? {
        guard let id = activeWalletId else { return wallets.first }
        return wallets.first(where: { $0.id == id }) ?? wallets.first
    }

    func activeNetwork(for walletId: UUID) -> TronNetwork {
        _ = walletId
        return currentNetwork
    }

    // MARK: -- pending tx tracking

    /// Mark a freshly-broadcast tx as pending on the sender's wallet.
    /// The wallet view renders it as a "Pending" row at the top of
    /// the transactions list until the next refresh observes it on
    /// chain. If the recipient address belongs to another Tron wallet
    /// the user owns, ALSO marks a pending incoming on that wallet so
    /// internal sends surface on both sides.
    func markPendingOutbound(
        senderWalletId: UUID,
        txID: String,
        senderAddress: String,
        recipientAddress: String,
        sunAmount: Int64,
        tokenContract: String? = nil,
        tokenSymbol: String? = nil,
        tokenDecimals: UInt8? = nil
    ) {
        let outbound = PendingTronTx(
            txID: txID,
            direction: .out,
            counterparty: recipientAddress,
            sunAmount: sunAmount,
            tokenContract: tokenContract,
            tokenSymbol: tokenSymbol,
            tokenDecimals: tokenDecimals,
            broadcastAt: Date()
        )
        appendPending(walletId: senderWalletId, tx: outbound)

        // If the recipient is another Maknoon wallet on this device,
        // mirror as pending inbound so the other dashboard shows the
        // optimistic incoming row too. Match by stored hardware
        // address or by software wallet descriptor — we can't always
        // resolve a software address without a sandwich prompt, so we
        // only auto-mirror to hardware wallets here.
        if let mirroredId = walletIdForAddress(recipientAddress), mirroredId != senderWalletId {
            let inbound = PendingTronTx(
                txID: txID,
                direction: .in,
                counterparty: senderAddress,
                sunAmount: sunAmount,
                tokenContract: tokenContract,
                tokenSymbol: tokenSymbol,
                tokenDecimals: tokenDecimals,
                broadcastAt: Date()
            )
            appendPending(walletId: mirroredId, tx: inbound)
        }
    }

    /// Drop any pending entries whose txID now appears in the
    /// canonical confirmed list. Called by `TronWalletView.refresh`
    /// after each network round-trip.
    func dropConfirmedPending(walletId: UUID, confirmedTxIDs: Set<String>) {
        guard var list = pendingTxsByWallet[walletId] else { return }
        let cutoff = Date().addingTimeInterval(-3 * 60)  // also drop pending older than 3 min
        list.removeAll { tx in
            confirmedTxIDs.contains(tx.txID) || tx.broadcastAt < cutoff
        }
        if list.isEmpty {
            pendingTxsByWallet.removeValue(forKey: walletId)
        } else {
            pendingTxsByWallet[walletId] = list
        }
    }

    private func appendPending(walletId: UUID, tx: PendingTronTx) {
        var list = pendingTxsByWallet[walletId] ?? []
        // Dedup by txID so a repeat broadcast doesn't show twice.
        if list.contains(where: { $0.txID == tx.txID }) { return }
        list.insert(tx, at: 0)
        pendingTxsByWallet[walletId] = list
    }

    /// Resolve a Tron T-prefixed address to a wallet id we know
    /// about. Hardware-wallet descriptors carry the address directly;
    /// software wallets do not (deriving needs the sandwich), so this
    /// only mirrors to hardware wallets.
    private func walletIdForAddress(_ address: String) -> UUID? {
        for w in wallets {
            if case .hardware(_, _, let addr) = w.kind, addr == address {
                return w.id
            }
        }
        return nil
    }

    func setActiveNetwork(walletId: UUID, network: TronNetwork) {
        currentNetwork = network
        currentNetworkByWallet[walletId] = network
        persist()
    }

    weak var addressBook: AddressBookStore?

    func add(_ descriptor: TronWalletDescriptor, initialNetwork: TronNetwork = .mainnet, makeActive: Bool = true) {
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
        addressBook?.removeSystemWallet(walletId: id, chainKey: "tron")
    }

    /// Mirror a wallet into the user's address book as a read-only
    /// system entry. Hardware wallets carry the address on the
    /// descriptor; software wallets get mirrored once
    /// `TronWalletView.refresh()` resolves their address.
    fileprivate func mirrorToAddressBook(_ descriptor: TronWalletDescriptor) {
        guard let addressBook else { return }
        let address: String
        switch descriptor.kind {
        case .software:
            return
        case .hardware(_, _, let addressBase58Check):
            address = addressBase58Check
        }
        addressBook.upsertSystemWallet(
            walletId: descriptor.id,
            chainKey: "tron",
            name: descriptor.label,
            address: address,
            network: .tron
        )
    }

    /// Externally-triggered mirror update. Called by TronWalletView
    /// after refresh resolves the software-wallet address.
    func updateMirrorAddress(walletId: UUID, address: String) {
        guard let addressBook,
              let descriptor = wallets.first(where: { $0.id == walletId })
        else { return }
        addressBook.upsertSystemWallet(
            walletId: walletId,
            chainKey: "tron",
            name: descriptor.label,
            address: address,
            network: .tron
        )
    }

    func remirrorAllToAddressBook() {
        for descriptor in wallets {
            mirrorToAddressBook(descriptor)
        }
    }

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

    // MARK: -- persistence

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
        var raw: [String: TronNetwork] = [:]
        for (id, net) in currentNetworkByWallet { raw[id.uuidString] = net }
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
        // Preferred path: v2 descriptor list + separate cluster map.
        if let data = UserDefaults.standard.data(forKey: Self.walletsKeyV2),
           let list = try? JSONDecoder().decode([TronWalletDescriptor].self, from: data) {
            self.wallets = list
            if let mapData = UserDefaults.standard.data(forKey: Self.networkMapKey),
               let raw = try? JSONDecoder().decode([String: TronNetwork].self, from: mapData) {
                var out: [UUID: TronNetwork] = [:]
                for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
                self.currentNetworkByWallet = out
            }
            if let s = UserDefaults.standard.string(forKey: Self.activeKey),
               let id = UUID(uuidString: s) {
                self.activeWalletId = id
            }
            if let raw = UserDefaults.standard.string(forKey: Self.currentChainNetworkKey),
               let net = TronNetwork(rawValue: raw) {
                self.currentNetwork = net
            } else if let id = activeWalletId, let net = currentNetworkByWallet[id] {
                self.currentNetwork = net
            }
            return
        }
        // v1 migration: peel `network` off the descriptor into the
        // separate map and rewrite under v2.
        if let data = UserDefaults.standard.data(forKey: Self.walletsKeyV1),
           let v1List = try? JSONDecoder().decode([V1Descriptor].self, from: data) {
            var migrated: [TronWalletDescriptor] = []
            var networkMap: [UUID: TronNetwork] = [:]
            for entry in v1List {
                let d = TronWalletDescriptor(
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
            return
        }
    }

    private struct V1Descriptor: Codable {
        let id: UUID
        var label: String
        let kind: TronWalletKind
        var network: TronNetwork
        let createdAt: Date
        var lastSyncAt: Date?
    }
}
