// User's list of Ethereum wallets plus the per-wallet "currently
// viewed network" selection. Persists to UserDefaults under the
// `networks.ethereum.*` namespace so future EVM chain expansion +
// Tron + Solana stay siblings.
//
// Storage schema:
//   v2 — `networks.ethereum.wallets.v2` holds an array of network
//        -agnostic descriptors. The per-wallet selected network
//        lives separately at `networks.ethereum.currentNetwork.v2`.
//   v1 — `networks.ethereum.wallets.v1` was per-(network, account)
//        descriptors. Migration on first launch under v2 dedupes
//        by (kind, account, address) and seeds the current-network
//        map from the original network field.

import Foundation
import Observation
import SwiftUI

/// Optimistic in-memory pending Ethereum tx. Mirrors
/// `PendingTronTx`/`PendingSolanaTx`. The wallet view renders these
/// as orange "Pending" rows at the top of its transactions list
/// after a broadcast; the next refresh evicts them when the canonical
/// list returns the same hash.
struct PendingEthereumTx: Hashable, Identifiable, Sendable {
    enum Direction: Sendable, Hashable { case `in`, out }

    let txHash: String
    let direction: Direction
    let counterparty: String
    /// Native wei amount as a base-10 decimal string. For ERC-20
    /// sends, reused as the raw token-units string so the display
    /// row formats via `tokenDecimals`.
    let weiValue: String
    let tokenContract: String?
    let tokenSymbol: String?
    let tokenDecimals: UInt8?
    let broadcastAt: Date

    var id: String { txHash }
}

@Observable
final class EthereumWalletStore {
    private(set) var wallets: [EthereumWalletDescriptor] = []
    private(set) var activeWalletId: UUID?
    /// Per-wallet "currently viewed" network. Kept around for
    /// migration + legacy callers; the live picker now reads the
    /// chain-wide `currentNetworkID` below so a wallet switch
    /// preserves the user's selection.
    private(set) var currentNetworkByWallet: [UUID: EthereumNetworkID] = [:]
    /// Chain-wide "current network" chip. One source of truth
    /// shared across every Ethereum wallet so switching wallets
    /// doesn't reset the user's selection.
    private(set) var currentNetworkID: EthereumNetworkID = .builtin(.mainnet)

    /// In-memory map of (wallet UUID) → pending txs the user has
    /// broadcast but the explorer API has not yet returned as
    /// confirmed. Wallet view renders these as orange "Pending"
    /// rows; the next refresh that observes the txhash drops them.
    private(set) var pendingTxsByWallet: [UUID: [PendingEthereumTx]] = [:]

    private static let walletsKeyV2     = "networks.ethereum.wallets.v2"
    private static let networkMapKeyV3  = "networks.ethereum.currentNetwork.v3"
    private static let networkMapKeyV2  = "networks.ethereum.currentNetwork.v2"
    private static let currentChainNetworkKey = "networks.ethereum.currentNetwork.chainwide.v1"
    private static let activeKey        = "networks.ethereum.active.v1"
    private static let walletsKeyV1     = "networks.ethereum.wallets.v1"

    init() { load() }

    var activeWallet: EthereumWalletDescriptor? {
        guard let id = activeWalletId else { return wallets.first }
        return wallets.first(where: { $0.id == id }) ?? wallets.first
    }

    /// Currently-selected network ID. Reads from the chain-wide
    /// sticky selection; the walletId argument is kept for source
    /// compatibility with call sites and is ignored.
    func currentNetworkID(for walletId: UUID) -> EthereumNetworkID {
        _ = walletId
        return currentNetworkID
    }

    /// Switch the chain-wide currently-viewed network. Persists.
    func setCurrentNetworkID(_ id: EthereumNetworkID, for walletId: UUID) {
        currentNetworkID = id
        currentNetworkByWallet[walletId] = id
        persistNetworkMap()
        UserDefaults.standard.set(encodeChainNetwork(id), forKey: Self.currentChainNetworkKey)
    }

    /// Convenience overload — pick a built-in case directly.
    func setCurrentNetwork(_ network: EthereumNetwork, for walletId: UUID) {
        setCurrentNetworkID(.builtin(network), for: walletId)
    }

    // MARK: -- pending tx tracking (mirror of Solana/Tron stores)

    func markPendingOutbound(
        senderWalletId: UUID,
        txHash: String,
        senderAddress: String,
        recipientAddress: String,
        weiValue: String,
        tokenContract: String? = nil,
        tokenSymbol: String? = nil,
        tokenDecimals: UInt8? = nil
    ) {
        let outbound = PendingEthereumTx(
            txHash: txHash,
            direction: .out,
            counterparty: recipientAddress,
            weiValue: weiValue,
            tokenContract: tokenContract,
            tokenSymbol: tokenSymbol,
            tokenDecimals: tokenDecimals,
            broadcastAt: Date()
        )
        appendPending(walletId: senderWalletId, tx: outbound)

        if let mirroredId = walletIdForAddress(recipientAddress), mirroredId != senderWalletId {
            let inbound = PendingEthereumTx(
                txHash: txHash,
                direction: .in,
                counterparty: senderAddress,
                weiValue: weiValue,
                tokenContract: tokenContract,
                tokenSymbol: tokenSymbol,
                tokenDecimals: tokenDecimals,
                broadcastAt: Date()
            )
            appendPending(walletId: mirroredId, tx: inbound)
        }
    }

    func dropConfirmedPending(walletId: UUID, confirmedTxHashes: Set<String>) {
        guard var list = pendingTxsByWallet[walletId] else { return }
        let cutoff = Date().addingTimeInterval(-15 * 60)  // Ethereum can take a while; allow 15 min
        let normalized = Set(confirmedTxHashes.map { $0.lowercased() })
        list.removeAll { tx in
            normalized.contains(tx.txHash.lowercased()) || tx.broadcastAt < cutoff
        }
        if list.isEmpty {
            pendingTxsByWallet.removeValue(forKey: walletId)
        } else {
            pendingTxsByWallet[walletId] = list
        }
    }

    private func appendPending(walletId: UUID, tx: PendingEthereumTx) {
        var list = pendingTxsByWallet[walletId] ?? []
        if list.contains(where: { $0.txHash.lowercased() == tx.txHash.lowercased() }) { return }
        list.insert(tx, at: 0)
        pendingTxsByWallet[walletId] = list
    }

    /// Resolve a 0x address to a wallet id we know about. All EVM
    /// wallets carry the address on the descriptor, so this works
    /// for both software and hardware.
    private func walletIdForAddress(_ address: String) -> UUID? {
        let normalized = address.lowercased()
        return wallets.first { w in
            (w.address ?? "").lowercased() == normalized
        }?.id
    }

    /// Encode the chain-wide ID for UserDefaults. Built-ins serialize
    /// as `"builtin:<raw>"`; custom UUIDs as `"custom:<uuid>"`.
    private func encodeChainNetwork(_ id: EthereumNetworkID) -> String {
        switch id {
        case .builtin(let n): return "builtin:\(n.rawValue)"
        case .custom(let u):  return "custom:\(u.uuidString)"
        }
    }

    private func decodeChainNetwork(_ s: String) -> EthereumNetworkID? {
        if s.hasPrefix("builtin:") {
            let raw = String(s.dropFirst("builtin:".count))
            if let n = EthereumNetwork(rawValue: raw) { return .builtin(n) }
        } else if s.hasPrefix("custom:") {
            let raw = String(s.dropFirst("custom:".count))
            if let u = UUID(uuidString: raw) { return .custom(u) }
        }
        return nil
    }

    /// Currently-selected network for the active wallet (built-in
    /// or custom). Resolves via the holder store's custom-network
    /// store + EthereumSettings overrides to produce a flat
    /// `ResolvedNetwork` value.
    func activeNetwork(customs: CustomNetworkStore, settings: EthereumSettings) -> ResolvedNetwork {
        let id = activeWallet.map { currentNetworkID(for: $0.id) } ?? .builtin(.mainnet)
        return resolve(id, customs: customs, settings: settings)
    }

    /// Resolve a `NetworkID` into a flat `ResolvedNetwork`. For
    /// built-in cases, applies any user overrides from
    /// `EthereumSettings`. For custom networks, reads the user-
    /// defined URLs directly.
    func resolve(_ id: EthereumNetworkID, customs: CustomNetworkStore, settings: EthereumSettings) -> ResolvedNetwork {
        switch id {
        case .builtin(let net):
            return ResolvedNetwork(
                networkID: id,
                chainId: net.chainId,
                displayName: net.displayName,
                ticker: net.ticker,
                isTestnet: net.isTestnet,
                rpcURL: settings.rpcURL(for: net),
                explorerURL: settings.explorerURL(for: net),
                explorerAPIURL: settings.explorerAPIURL(for: net),
                explorerAPIKey: settings.explorerAPIKey(for: net)
            )
        case .custom(let uuid):
            // Fall back to mainnet if a custom-network UUID is
            // dangling (the user removed it but a wallet still
            // points at it).
            guard let custom = customs.find(id: uuid) else {
                return resolve(.builtin(.mainnet), customs: customs, settings: settings)
            }
            return ResolvedNetwork(
                networkID: id,
                chainId: custom.chainId,
                displayName: custom.name,
                ticker: custom.ticker,
                isTestnet: custom.isTestnet,
                rpcURL: custom.rpcURL,
                explorerURL: custom.explorerURL,
                explorerAPIURL: custom.explorerAPIURL,
                explorerAPIKey: custom.explorerAPIKey
            )
        }
    }

    /// Weak ref to the user's address book. Wired by HolderStore.init
    /// after both stores are constructed; nil-safe so tests can
    /// construct the store standalone.
    weak var addressBook: AddressBookStore?

    func add(_ descriptor: EthereumWalletDescriptor, initialNetwork: EthereumNetwork = .mainnet, makeActive: Bool = true) {
        wallets.append(descriptor)
        currentNetworkByWallet[descriptor.id] = .builtin(initialNetwork)
        if makeActive { activeWalletId = descriptor.id }
        persist()
        mirrorToAddressBook(descriptor)
    }

    func remove(id: UUID) {
        wallets.removeAll { $0.id == id }
        currentNetworkByWallet.removeValue(forKey: id)
        if activeWalletId == id { activeWalletId = wallets.first?.id }
        persist()
        addressBook?.removeSystemWallet(walletId: id, chainKey: "ethereum")
    }

    /// Mirror a wallet into the user's address book as a read-only
    /// system entry. Uses the descriptor's `cachedAddress` which is
    /// populated at creation time (both software and hardware paths
    /// in `EthereumWalletsView.createSoftware/createHardware` set it).
    /// EVM addresses are chain-agnostic so one mirror entry per
    /// wallet is enough.
    fileprivate func mirrorToAddressBook(_ descriptor: EthereumWalletDescriptor) {
        guard let addressBook else { return }
        guard let addr = descriptor.cachedAddress, !addr.isEmpty else { return }
        addressBook.upsertSystemWallet(
            walletId: descriptor.id,
            chainKey: "ethereum",
            name: descriptor.label,
            address: addr,
            network: .ethereum
        )
    }

    /// Re-mirror every Ethereum wallet to the address book. Called
    /// once at HolderStore wiring time so wallets created before the
    /// address book existed (or before this mirror was wired) still
    /// appear as system entries.
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

    func setCachedAddress(id: UUID, address: String) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].cachedAddress = address
        persist()
    }

    func setActive(_ id: UUID) {
        guard wallets.contains(where: { $0.id == id }) else { return }
        activeWalletId = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
    }

    /// Next unused software-account index across all software
    /// wallets. Ethereum accounts are network-agnostic now, so a
    /// single sequence applies across all chains.
    func nextSoftwareAccount() -> UInt32 {
        let used: Set<UInt32> = Set(
            wallets.compactMap { w in
                guard case let .software(account) = w.kind else { return nil }
                return account
            }
        )
        var i: UInt32 = 0
        while used.contains(i) { i += 1 }
        return i
    }

    /// True if a software wallet already exists at this account
    /// index. Used by the Add sheet to surface "this account is
    /// already in your list."
    func hasSoftwareWallet(account: UInt32) -> Bool {
        return wallets.contains {
            guard case let .software(a) = $0.kind else { return false }
            return a == account
        }
    }

    /// True if a hardware wallet at the given (device, account) is
    /// already registered. Lets the discovery + add sheets dedupe.
    func hasHardwareWallet(deviceId: UUID, account: UInt32) -> Bool {
        return wallets.contains {
            guard case let .hardware(d, a, _) = $0.kind else { return false }
            return d == deviceId && a == account
        }
    }

    // MARK: -- persistence

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        wallets = []
        activeWalletId = nil
        currentNetworkByWallet = [:]
        currentNetworkID = .builtin(.mainnet)
        pendingTxsByWallet = [:]
        load()
    }

    private struct V1Descriptor: Codable {
        let id: UUID
        var label: String
        let kind: EthereumWalletKind
        let network: EthereumNetwork
        let createdAt: Date
        var lastSyncAt: Date?
        var cachedAddress: String?
    }

    private func load() {
        // v2 path: read network-agnostic descriptors + network map.
        if let data = UserDefaults.standard.data(forKey: Self.walletsKeyV2),
           let decoded = try? JSONDecoder().decode([EthereumWalletDescriptor].self, from: data) {
            wallets = decoded
            // v3 map carries EthereumNetworkID (built-in or custom);
            // v2 map carried bare EthereumNetwork raw values. Try v3
            // first, fall back to v2 wrapping in .builtin(...).
            if let mapData = UserDefaults.standard.data(forKey: Self.networkMapKeyV3),
               let rawMap = try? JSONDecoder().decode([String: EthereumNetworkID].self, from: mapData) {
                var out: [UUID: EthereumNetworkID] = [:]
                for (k, v) in rawMap {
                    if let id = UUID(uuidString: k) { out[id] = v }
                }
                currentNetworkByWallet = out
            } else if let mapData = UserDefaults.standard.data(forKey: Self.networkMapKeyV2),
                      let rawMap = try? JSONDecoder().decode([String: String].self, from: mapData) {
                var out: [UUID: EthereumNetworkID] = [:]
                for (k, v) in rawMap {
                    if let id = UUID(uuidString: k), let net = EthereumNetwork(rawValue: v) {
                        out[id] = .builtin(net)
                    }
                }
                currentNetworkByWallet = out
            }
            if let s = UserDefaults.standard.string(forKey: Self.activeKey),
               let id = UUID(uuidString: s) {
                activeWalletId = id
            }
            // Chain-wide current network: prefer the standalone key,
            // fall back to the active wallet's per-wallet entry, then
            // mainnet.
            if let raw = UserDefaults.standard.string(forKey: Self.currentChainNetworkKey),
               let id = decodeChainNetwork(raw) {
                currentNetworkID = id
            } else if let id = activeWalletId, let n = currentNetworkByWallet[id] {
                currentNetworkID = n
            }
            return
        }
        // v1 → v2 migration. Dedupe by (kind, cached address); the
        // network field on duplicates is discarded, the kept entry
        // gets the v1 network as its initial selection so the user
        // doesn't lose state on upgrade.
        if let v1Data = UserDefaults.standard.data(forKey: Self.walletsKeyV1),
           let v1 = try? JSONDecoder().decode([V1Descriptor].self, from: v1Data) {
            var seen = Set<String>()
            var migratedWallets: [EthereumWalletDescriptor] = []
            var networkMap: [UUID: EthereumNetworkID] = [:]
            for entry in v1 {
                let dedupKey = "\(entry.kind):\(entry.cachedAddress ?? "no-addr")"
                if seen.contains(dedupKey) { continue }
                seen.insert(dedupKey)
                let d = EthereumWalletDescriptor(
                    id: entry.id,
                    label: entry.label,
                    kind: entry.kind,
                    createdAt: entry.createdAt,
                    lastSyncAt: entry.lastSyncAt,
                    cachedAddress: entry.cachedAddress
                )
                migratedWallets.append(d)
                networkMap[d.id] = .builtin(entry.network)
            }
            wallets = migratedWallets
            currentNetworkByWallet = networkMap
            if let s = UserDefaults.standard.string(forKey: Self.activeKey),
               let id = UUID(uuidString: s),
               wallets.contains(where: { $0.id == id }) {
                activeWalletId = id
            }
            // Write v2 immediately so the next launch skips this branch.
            persist()
            // v1 key intentionally not removed: leaving it lets a
            // future downgrade still find the data.
            return
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(wallets) {
            UserDefaults.standard.set(data, forKey: Self.walletsKeyV2)
        }
        persistNetworkMap()
        UserDefaults.standard.set(encodeChainNetwork(currentNetworkID), forKey: Self.currentChainNetworkKey)
        UserDefaults.standard.set(activeWalletId?.uuidString, forKey: Self.activeKey)
    }

    private func persistNetworkMap() {
        var raw: [String: EthereumNetworkID] = [:]
        for (id, net) in currentNetworkByWallet {
            raw[id.uuidString] = net
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.networkMapKeyV3)
        }
    }
}
