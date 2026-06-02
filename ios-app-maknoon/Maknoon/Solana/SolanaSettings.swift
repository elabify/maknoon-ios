// Solana per-network settings: RPC endpoint, explorer URL, and the
// currently-selected network. Pattern follows BitcoinSettings.swift
// to keep settings UI implementation costs low.

import Foundation
import Observation

@Observable
final class SolanaSettings {
    /// Per-network overrides keyed by network rawValue. nil = use
    /// the network's built-in default URL.
    var rpcOverridesByNetwork: [String: String] = [:]
    var explorerOverridesByNetwork: [String: String] = [:]
    /// Network the dashboard + send/receive default to. User-changeable
    /// from the wallet's network picker (each individual wallet pins
    /// to its own network at create time; this is just the picker
    /// default for new wallets).
    var selectedNetwork: SolanaNetwork = .mainnet
    /// Verified-token catalog URL. Defaults to Jupiter's strict list.
    /// User-overridable so a hardened build can pin to a self-hosted
    /// mirror or a frozen snapshot. The actual fetch lives in
    /// SolanaTokenCatalog; this is just the value it reads.
    var tokenCatalogURL: String = SolanaTokenCatalog.defaultCatalogURL
    /// Base URL used to render token logos. Full URL is
    /// `{logoBaseURL}/{mint}/logo.png`. Default is Trust Wallet's
    /// assets repo. Overridable so users can mirror the assets or
    /// pin to a frozen revision.
    var logoBaseURL: String = SolanaSettings.defaultLogoBaseURL

    static let defaultLogoBaseURL = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/solana/assets"

    /// Per-token logo URL. Returns nil when the base or mint is
    /// empty; the row renders the monogram fallback in that case.
    func tokenLogoURL(mint: String) -> URL? {
        let base = logoBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let trimmed = mint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !trimmed.isEmpty else { return nil }
        return URL(string: "\(base)/\(trimmed)/logo.png")
    }

    private static let key = "networks.solana.settings.v1"

    init() {
        load()
    }

    func rpcURL(for network: SolanaNetwork) -> String {
        rpcOverridesByNetwork[network.rawValue] ?? network.defaultRpcURL
    }

    func explorerURL(for network: SolanaNetwork) -> String {
        explorerOverridesByNetwork[network.rawValue] ?? network.defaultExplorerURL
    }

    func setRPCOverride(_ url: String?, for network: SolanaNetwork) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            rpcOverridesByNetwork[network.rawValue] = trimmed
        } else {
            rpcOverridesByNetwork.removeValue(forKey: network.rawValue)
        }
        persist()
    }

    func setExplorerOverride(_ url: String?, for network: SolanaNetwork) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            explorerOverridesByNetwork[network.rawValue] = trimmed
        } else {
            explorerOverridesByNetwork.removeValue(forKey: network.rawValue)
        }
        persist()
    }

    // MARK: -- persistence

    func setTokenCatalogURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenCatalogURL = trimmed.isEmpty ? SolanaTokenCatalog.defaultCatalogURL : trimmed
        persist()
    }

    func setLogoBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        logoBaseURL = trimmed.isEmpty ? SolanaSettings.defaultLogoBaseURL : trimmed
        persist()
    }

    private struct Persisted: Codable {
        var rpcOverrides: [String: String]
        var explorerOverrides: [String: String]
        var selectedNetwork: String
        var tokenCatalogURL: String?
        var logoBaseURL: String?
    }

    private func persist() {
        let p = Persisted(
            rpcOverrides: rpcOverridesByNetwork,
            explorerOverrides: explorerOverridesByNetwork,
            selectedNetwork: selectedNetwork.rawValue,
            tokenCatalogURL: tokenCatalogURL,
            logoBaseURL: logoBaseURL
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        rpcOverridesByNetwork = [:]
        explorerOverridesByNetwork = [:]
        selectedNetwork = .mainnet
        tokenCatalogURL = SolanaTokenCatalog.defaultCatalogURL
        logoBaseURL = SolanaSettings.defaultLogoBaseURL
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let p = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        self.rpcOverridesByNetwork = p.rpcOverrides
        self.explorerOverridesByNetwork = p.explorerOverrides
        if let n = SolanaNetwork(rawValue: p.selectedNetwork) {
            self.selectedNetwork = n
        }
        if let saved = p.tokenCatalogURL, !saved.isEmpty {
            self.tokenCatalogURL = saved
        }
        if let saved = p.logoBaseURL, !saved.isEmpty {
            self.logoBaseURL = saved
        }
    }
}
