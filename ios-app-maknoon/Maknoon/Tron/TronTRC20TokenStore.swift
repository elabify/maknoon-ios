// Per-cluster installed TRC-20 tokens + the auto-discover pipeline.
// Mirrors `SolanaSPLTokenStore`: no first-run seed, lookup against
// the remote catalog, unverified contracts surface separately so
// the dashboard can offer "Add as custom?" without spamming the
// list with airdrop tokens.

import Foundation
import Observation

@Observable
final class TronTRC20TokenStore {
    private(set) var allTokens: [TronTRC20Token] = []
    /// Transient (not persisted): contracts the wallet held in its
    /// last refresh that didn't match the catalog. Reset every
    /// refresh so stale unknowns don't linger.
    private(set) var unknownContractsByNetwork: [TronNetwork: [String]] = [:]

    private static let key = "networks.tron.tokens.installed.v1"

    init() {
        load()
    }

    func tokens(on network: TronNetwork) -> [TronTRC20Token] {
        allTokens.filter { $0.network == network }
    }

    func unknownContracts(on network: TronNetwork) -> [String] {
        unknownContractsByNetwork[network] ?? []
    }

    /// Auto-discover pass. The dashboard's refresh hands us the list
    /// of TRC-20 contracts the wallet currently holds; we install
    /// any verified ones from the catalog and surface unverified
    /// ones in the banner.
    func reconcile(
        heldContracts: [String],
        on network: TronNetwork,
        catalog: TronTokenCatalog
    ) {
        var unknown: [String] = []
        var changed = false
        for contract in heldContracts {
            if allTokens.contains(where: { $0.network == network && $0.contract == contract }) {
                continue
            }
            if let entry = catalog.find(contract: contract) {
                let token = TronTRC20Token(
                    network: network,
                    contract: contract,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI,
                    source: .tronscan
                )
                allTokens.append(token)
                changed = true
            } else {
                unknown.append(contract)
            }
        }
        unknownContractsByNetwork[network] = unknown
        if changed { persist() }
    }

    func add(_ token: TronTRC20Token) {
        if allTokens.contains(where: { $0.id == token.id }) { return }
        allTokens.append(token)
        if var unk = unknownContractsByNetwork[token.network] {
            unk.removeAll { $0 == token.contract }
            unknownContractsByNetwork[token.network] = unk
        }
        persist()
    }

    func remove(_ token: TronTRC20Token) {
        allTokens.removeAll { $0.id == token.id }
        persist()
    }

    func dismissUnknown(_ contract: String, on network: TronNetwork) {
        if var unk = unknownContractsByNetwork[network] {
            unk.removeAll { $0 == contract }
            unknownContractsByNetwork[network] = unk
        }
    }

    // MARK: -- persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(allTokens) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        allTokens = []
        unknownContractsByNetwork = [:]
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TronTRC20Token].self, from: data) {
            self.allTokens = decoded
        }
    }
}
