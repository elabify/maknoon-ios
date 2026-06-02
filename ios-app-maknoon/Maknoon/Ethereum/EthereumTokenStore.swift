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
        var current = tokensByNetwork[token.network] ?? []
        if let idx = current.firstIndex(where: { $0.contractAddress == token.contractAddress }) {
            current[idx] = token
        } else {
            current.append(token)
        }
        tokensByNetwork[token.network] = current
        persist()
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
    }

    /// Networks where we've already run first-run seed. Tracked so a
    /// user who removes every curated token doesn't have them
    /// reappear at next launch. Persisted as part of the snapshot.
    private var seededNetworks: Set<EthereumNetwork> = []

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        tokensByNetwork = [:]
        seededNetworks = []
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
        // Seed networks the user hasn't seen yet (added after the
        // app was first launched). Idempotent because we only seed
        // networks not in seededNetworks.
        for n in EthereumNetwork.allCases where !seededNetworks.contains(n) {
            for t in EthereumTokenCatalog.defaults(for: n) {
                add(t)
            }
            seededNetworks.insert(n)
        }
        persist()
    }

    private func seedFirstRun() {
        for n in EthereumNetwork.allCases {
            tokensByNetwork[n] = EthereumTokenCatalog.defaults(for: n)
            seededNetworks.insert(n)
        }
        persist()
    }

    func persist() {
        let flat = tokensByNetwork.values.flatMap { $0 }
        let snap = Snapshot(
            tokens: flat,
            seededNetworks: seededNetworks.map { $0.rawValue }
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
