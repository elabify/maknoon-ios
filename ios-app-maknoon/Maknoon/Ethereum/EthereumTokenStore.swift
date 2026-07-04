// User's installed ERC-20 tokens, per network. Seeded with the
// curated catalog on first run; persists added / removed entries
// across launches.
//
// Tokens persist regardless of which wallet is active. Each wallet
// inherits the network's token list: open a Sepolia wallet, you see
// the Sepolia tokens; switch to Base, you see Base's. This mirrors
// MetaMask's pattern.

import Foundation
import Observation

@Observable
final class EthereumTokenStore: @unchecked Sendable {
    var tokensByNetwork: [EthereumNetwork: [EthereumToken]] = [:]

    private static let storeKey = "networks.ethereum.tokens.v1"

    init() { load() }

    /// All tokens on a given network. Returns curated defaults
    /// seeded on first run plus any user-added entries; user-removed
    /// curated entries are honoured (stored as an empty list rather
    /// than re-seeded).
    func tokens(on network: EthereumNetwork) -> [EthereumToken] {
        return tokensByNetwork[network] ?? []
    }

    /// Overload that accepts a resolved network. Custom networks
    /// (user-defined chains) don't currently have tokens.
    func tokens(on resolved: ResolvedNetwork) -> [EthereumToken] {
        switch resolved.networkID {
        case .builtin(let net): return tokens(on: net)
        case .custom:           return []
        }
    }

    /// Add or update a token. Used by both the curated seed path
    /// and the "Add custom" sheet.
    func add(_ token: EthereumToken) {
        addInMemory(token)
        persist()
    }

    /// Insert-or-replace without persisting (used during the load reconcile).
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

    func remove(_ token: EthereumToken) {
        var current = tokensByNetwork[token.network] ?? []
        current.removeAll { $0.contractAddress == token.contractAddress }
        tokensByNetwork[token.network] = current
        persist()
    }

    /// Lookup by network + contract address (case-insensitive).
    func find(network: EthereumNetwork, contract: String) -> EthereumToken? {
        let needle = contract.lowercased()
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
        seededNetworks = []
        seededContracts = []
        load()
    }

    private func load() {
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
}
