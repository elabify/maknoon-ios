// User's installed SPL tokens per (network) plus the auto-discover
// pipeline. Mirrors EthereumTokenStore in spirit but with two
// deliberate differences: (a) no first-run seed, (b) catalog is
// remote-backed, not in-tree.
//
// Lifecycle:
//   1. On Solana dashboard refresh, the WalletView passes the list
//      of token-account mints the wallet currently holds.
//   2. Each mint is matched against `SolanaTokenCatalog` (cached
//      Jupiter verified list).
//   3. Verified hits get auto-installed under `tokens(on:)`.
//      Unverified mints surface separately in `unknownMints(on:)`
//      so the dashboard can offer "Add as custom?" without spamming
//      the token list.

import Foundation
import Observation

@Observable
final class SolanaSPLTokenStore {
    /// Persisted: tokens the user (or auto-discover) has installed,
    /// keyed by `network:mint` to match SolanaSPLToken.id.
    private(set) var allTokens: [SolanaSPLToken] = []
    /// Transient (not persisted): mints the wallet held in its last
    /// refresh that didn't match the catalog. Reset every refresh
    /// so stale unknowns don't linger.
    private(set) var unknownMintsByNetwork: [SolanaNetwork: [String]] = [:]
    /// Persisted: mints the user explicitly Ignored. `reconcile`
    /// skips these so a dismissed unknown-token warning never comes
    /// back on the next refresh (or after navigating away and
    /// returning).
    private(set) var ignoredMintsByNetwork: [SolanaNetwork: Set<String>] = [:]

    private static let key = "networks.solana.tokens.installed.v1"
    private static let ignoredKey = "networks.solana.tokens.ignored.v1"

    init() {
        load()
    }

    /// Tokens the dashboard should render for a given cluster.
    func tokens(on network: SolanaNetwork) -> [SolanaSPLToken] {
        allTokens.filter { $0.network == network }
    }

    /// Mints the wallet held in its last refresh that weren't in the
    /// Jupiter catalog. The dashboard surfaces these in a "Unknown
    /// tokens detected" affordance with Add-as-custom + Ignore.
    func unknownMints(on network: SolanaNetwork) -> [String] {
        unknownMintsByNetwork[network] ?? []
    }

    /// Auto-discover pass. Called from `SolanaWalletView.refresh()`
    /// with the full list of mints the wallet currently holds (i.e.
    /// the `mint` field from every getTokenAccountsByOwner result).
    /// Verified mints get auto-installed; unverified ones land in
    /// `unknownMintsByNetwork` for separate UI treatment.
    func reconcile(
        heldMints: [String],
        on network: SolanaNetwork,
        catalog: SolanaTokenCatalog
    ) {
        var unknown: [String] = []
        var changed = false
        for mint in heldMints {
            // Already installed: nothing to do.
            if allTokens.contains(where: { $0.network == network && $0.mint == mint }) {
                continue
            }
            if let entry = catalog.find(mint: mint) {
                let token = SolanaSPLToken(
                    network: network,
                    mint: mint,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    logoURI: entry.logoURI,
                    source: .jupiter
                )
                allTokens.append(token)
                changed = true
            } else if !(ignoredMintsByNetwork[network]?.contains(mint) ?? false) {
                // Surface as unknown only if the user hasn't already
                // chosen to Ignore it.
                unknown.append(mint)
            }
        }
        unknownMintsByNetwork[network] = unknown
        if changed { persist() }
    }

    /// Manually add a token. Used by the Add Token sheet after a
    /// catalog/Metaplex lookup or a fully manual entry. Idempotent
    /// against the (network, mint) id.
    func add(_ token: SolanaSPLToken) {
        if allTokens.contains(where: { $0.id == token.id }) { return }
        allTokens.append(token)
        // If the mint was previously surfaced as unknown, clear it
        // so the dashboard banner stops nagging.
        if var unk = unknownMintsByNetwork[token.network] {
            unk.removeAll { $0 == token.mint }
            unknownMintsByNetwork[token.network] = unk
        }
        persist()
    }

    /// Remove an installed token. Doesn't touch the on-chain SPL
    /// account, just hides the row from the dashboard.
    func remove(_ token: SolanaSPLToken) {
        allTokens.removeAll { $0.id == token.id }
        persist()
    }

    /// Drop an unknown mint from the dashboard banner without
    /// installing it. Maps to the "Ignore" affordance. Remembers the
    /// choice (persisted) so the warning doesn't reappear on the next
    /// refresh or after leaving + returning to the wallet.
    func dismissUnknown(_ mint: String, on network: SolanaNetwork) {
        if var unk = unknownMintsByNetwork[network] {
            unk.removeAll { $0 == mint }
            unknownMintsByNetwork[network] = unk
        }
        var ignored = ignoredMintsByNetwork[network] ?? []
        ignored.insert(mint)
        ignoredMintsByNetwork[network] = ignored
        persistIgnored()
    }

    // MARK: -- persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(allTokens) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func persistIgnored() {
        // Encode as [networkRawValue: [mint]] for a stable JSON shape.
        let encodable = Dictionary(
            uniqueKeysWithValues: ignoredMintsByNetwork.map { ($0.key.rawValue, Array($0.value)) }
        )
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.ignoredKey)
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        allTokens = []
        unknownMintsByNetwork = [:]
        ignoredMintsByNetwork = [:]
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SolanaSPLToken].self, from: data) {
            self.allTokens = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.ignoredKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            var out: [SolanaNetwork: Set<String>] = [:]
            for (raw, mints) in decoded {
                if let net = SolanaNetwork(rawValue: raw) {
                    out[net] = Set(mints)
                }
            }
            self.ignoredMintsByNetwork = out
        }
    }
}
