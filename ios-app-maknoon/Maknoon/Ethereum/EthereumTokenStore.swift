// User's ERC-20 tokens (ADR-0060). A wallet starts with NO tokens: there is
// NO curated first-run seed. Every token a wallet shows was either
// auto-discovered from that wallet's own transfer history or added manually,
// and BOTH are scoped to a single (wallet, chain) in `userTokens`, keyed
// (wallet UUID, network). A discovered/added token never appears in the user's
// other wallets or on other chains.
//
// `tokensByNetwork` (keyed by network only) is a legacy chain-wide tier kept
// solely so pre-ADR-0060 entries a user actually added are not lost. Earlier
// builds also auto-seeded curated catalog defaults (USDC/... on every chain)
// here; those are purged on load now (curated == true), so no token is ever
// "built in". `EthereumTokenCatalog.reputable` is only a discovery trust
// anchor (to name a discovered contract), never auto-installed.

import Foundation
import Observation

@Observable
final class EthereumTokenStore: @unchecked Sendable {
    /// Curated catalog defaults, chain-wide (shared across wallets).
    var tokensByNetwork: [EthereumNetwork: [EthereumToken]] = [:]

    /// Runtime-added tokens (custom + auto-discovered), scoped per
    /// (wallet, chain). Keyed "<walletUUID>:<network.rawValue>".
    private var userTokens: [String: [EthereumToken]] = [:]

    private static let storeKey = "networks.ethereum.tokens.v1"
    private static let userStoreKey = "networks.ethereum.userTokens.v2"

    private func walletKey(_ walletId: UUID, _ network: EthereumNetwork) -> String {
        "\(walletId.uuidString):\(network.rawValue)"
    }

    init() { load() }

    /// Chain-wide curated/seeded defaults for a network (no wallet scope).
    /// Used for generic asset catalogs (e.g. the mini-app asset lister), which
    /// list well-known tokens rather than one wallet's holdings.
    func tokens(on network: EthereumNetwork) -> [EthereumToken] {
        return tokensByNetwork[network] ?? []
    }

    /// Chain-wide overload accepting a resolved network. Custom networks
    /// (user-defined chains) don't currently have tokens.
    func tokens(on resolved: ResolvedNetwork) -> [EthereumToken] {
        switch resolved.networkID {
        case .builtin(let net): return tokens(on: net)
        case .custom:           return []
        }
    }

    /// Tokens visible to ONE wallet on a chain: the curated chain-wide defaults
    /// plus that wallet's own added/discovered tokens, deduped by contract.
    func tokens(on network: EthereumNetwork, walletId: UUID) -> [EthereumToken] {
        let curated = tokensByNetwork[network] ?? []
        let extra = userTokens[walletKey(walletId, network)] ?? []
        var seen = Set(curated.map { $0.contractAddress })
        var out = curated
        for t in extra where seen.insert(t.contractAddress).inserted { out.append(t) }
        return out
    }

    /// Wallet-scoped overload accepting a resolved network.
    func tokens(on resolved: ResolvedNetwork, walletId: UUID) -> [EthereumToken] {
        switch resolved.networkID {
        case .builtin(let net): return tokens(on: net, walletId: walletId)
        case .custom:           return []
        }
    }

    /// Add or update a token for a specific wallet on its chain. Used by the
    /// "Add custom token" sheet and auto-discovery; the token is scoped to this
    /// wallet and does not appear in the user's other wallets (ADR-0060).
    func add(_ token: EthereumToken, walletId: UUID) {
        let key = walletKey(walletId, token.network)
        var current = userTokens[key] ?? []
        if let idx = current.firstIndex(where: { $0.contractAddress == token.contractAddress }) {
            current[idx] = token
        } else {
            current.append(token)
        }
        userTokens[key] = current
        persistUserTokens()
    }

    /// Insert-or-replace a curated default without persisting (load/seed only;
    /// chain-wide).
    private func addInMemory(_ token: EthereumToken) {
        var current = tokensByNetwork[token.network] ?? []
        if let idx = current.firstIndex(where: { $0.contractAddress == token.contractAddress }) {
            current[idx] = token
        } else {
            current.append(token)
        }
        tokensByNetwork[token.network] = current
    }

    private func seedKey(_ network: EthereumNetwork, _ contract: String) -> String {
        "\(network.rawValue):\(contract.lowercased())"
    }

    /// Remove a token from a wallet. A wallet-scoped (custom/discovered) token
    /// is removed from just that wallet; a curated/legacy chain-wide token is
    /// removed chain-wide (its prior behavior), so old leaked entries can still
    /// be cleared in one action.
    func remove(_ token: EthereumToken, walletId: UUID) {
        let key = walletKey(walletId, token.network)
        if let current = userTokens[key], current.contains(where: { $0.contractAddress == token.contractAddress }) {
            userTokens[key] = current.filter { $0.contractAddress != token.contractAddress }
            persistUserTokens()
            return
        }
        var chainWide = tokensByNetwork[token.network] ?? []
        chainWide.removeAll { $0.contractAddress == token.contractAddress }
        tokensByNetwork[token.network] = chainWide
        persist()
    }

    /// Lookup by network + contract for one wallet (case-insensitive): the
    /// wallet's own tokens first, then the chain-wide curated defaults. Lets
    /// auto-discovery skip a contract this wallet already has.
    func find(network: EthereumNetwork, contract: String, walletId: UUID) -> EthereumToken? {
        let needle = contract.lowercased()
        if let t = userTokens[walletKey(walletId, network)]?.first(where: { $0.contractAddress == needle }) {
            return t
        }
        return tokensByNetwork[network]?.first { $0.contractAddress == needle }
    }

    // MARK: -- persistence

    private struct Snapshot: Codable {
        let tokens: [EthereumToken]
        let seededNetworks: [String]
        // Optional so legacy snapshots (which predate per-contract tracking)
        // still decode; nil is treated as "none seeded yet" so the reconcile
        // unions in the current catalog defaults once.
        let seededContracts: [String]?
    }

    /// Networks where we've already run first-run seed. Tracked so a
    /// user who removes every curated token doesn't have them
    /// reappear at next launch. Persisted as part of the snapshot.
    private var seededNetworks: Set<EthereumNetwork> = []

    /// Every curated catalog default ever seeded, keyed "network:contract".
    /// Lets us union in tokens ADDED to the catalog after a network was first
    /// seeded (e.g. Arbitrum USDC) exactly once, without resurrecting a token
    /// the user later removed on every launch.
    private var seededContracts: Set<String> = []

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        tokensByNetwork = [:]
        userTokens = [:]
        seededNetworks = []
        seededContracts = []
        load()
    }

    private func load() {
        loadUserTokens()
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            // First run on this device: seed curated catalog for
            // every network and mark each as seeded.
            seedFirstRun()
            return
        }
        var grouped: [EthereumNetwork: [EthereumToken]] = [:]
        for t in snap.tokens {
            grouped[t.network, default: []].append(t)
        }
        self.tokensByNetwork = grouped
        self.seededNetworks = Set(snap.seededNetworks.compactMap { EthereumNetwork(rawValue: $0) })
        self.seededContracts = Set(snap.seededContracts ?? [])
        // Seed networks the user hasn't seen yet (added after the
        // app was first launched). Idempotent because we only seed
        // networks not in seededNetworks.
        for n in EthereumNetwork.allCases where !seededNetworks.contains(n) {
            for t in EthereumTokenCatalog.defaults(for: n) {
                addInMemory(t)
            }
            seededNetworks.insert(n)
        }
        // Reconcile: ensure every curated catalog default has been seeded at
        // least once. Adds tokens introduced to the catalog AFTER a network was
        // first seeded (e.g. Arbitrum USDC on an install that predates it),
        // which the seededNetworks gate alone would miss. Tracked per-contract
        // so a token the user removes later is not resurrected next launch.
        for n in EthereumNetwork.allCases {
            for t in EthereumTokenCatalog.defaults(for: n) {
                if seededContracts.insert(seedKey(n, t.contractAddress)).inserted {
                    addInMemory(t)
                }
            }
        }
        // ADR-0060: a wallet starts with NO ERC-20 tokens. Drop any curated
        // defaults auto-seeded by an earlier build (e.g. USDC on every chain);
        // tokens now come only from auto-discovery or manual add, both scoped
        // per (wallet, chain). Legacy user-added chain-wide tokens
        // (curated == false) are preserved.
        tokensByNetwork = tokensByNetwork.mapValues { $0.filter { !$0.curated } }
        persist()
    }

    private func seedFirstRun() {
        for n in EthereumNetwork.allCases {
            tokensByNetwork[n] = EthereumTokenCatalog.defaults(for: n)
            seededNetworks.insert(n)
            for t in EthereumTokenCatalog.defaults(for: n) {
                seededContracts.insert(seedKey(n, t.contractAddress))
            }
        }
        persist()
    }

    func persist() {
        let flat = tokensByNetwork.values.flatMap { $0 }
        let snap = Snapshot(
            tokens: flat,
            seededNetworks: seededNetworks.map { $0.rawValue },
            seededContracts: Array(seededContracts)
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func loadUserTokens() {
        guard let data = UserDefaults.standard.data(forKey: Self.userStoreKey),
              let decoded = try? JSONDecoder().decode([String: [EthereumToken]].self, from: data)
        else { return }
        userTokens = decoded
    }

    private func persistUserTokens() {
        if let data = try? JSONEncoder().encode(userTokens) {
            UserDefaults.standard.set(data, forKey: Self.userStoreKey)
        }
    }
}
