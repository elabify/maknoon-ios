// Tron per-network backend settings: TronGrid endpoint override,
// block-explorer override, and the TRC-20 catalog URL. Mirrors
// SolanaSettings so the Solana + Tron settings pages feel identical
// to the user.

import Foundation
import Observation

@Observable
final class TronSettings {
    var rpcOverridesByNetwork: [String: String] = [:]
    var explorerOverridesByNetwork: [String: String] = [:]
    var selectedNetwork: TronNetwork = .mainnet
    /// TRC-20 verified-token catalog URL. Defaults to TronScan's
    /// public API. User-overridable so a hardened build can point at
    /// a self-hosted mirror or a frozen snapshot.
    var tokenCatalogURL: String = TronTokenCatalog.defaultCatalogURL
    /// Base URL used to render token logos. Full URL is
    /// `{logoBaseURL}/{contract}/logo.png`. Default is Trust Wallet's
    /// assets repo. Overridable so users can mirror the assets or
    /// pin to a frozen revision.
    var logoBaseURL: String = TronSettings.defaultLogoBaseURL

    static let defaultLogoBaseURL = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/assets"

    /// Per-token logo URL. Returns nil when the base or contract is
    /// empty; the row renders the monogram fallback in that case.
    func tokenLogoURL(contract: String) -> URL? {
        let base = logoBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let trimmed = contract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !trimmed.isEmpty else { return nil }
        return URL(string: "\(base)/\(trimmed)/logo.png")
    }

    private static let key = "networks.tron.settings.v1"

    init() {
        load()
    }

    func rpcURL(for network: TronNetwork) -> String {
        rpcOverridesByNetwork[network.rawValue] ?? network.defaultRpcURL
    }

    func explorerURL(for network: TronNetwork) -> String {
        explorerOverridesByNetwork[network.rawValue] ?? network.defaultExplorerURL
    }

    func setRPCOverride(_ url: String?, for network: TronNetwork) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            rpcOverridesByNetwork[network.rawValue] = trimmed
        } else {
            rpcOverridesByNetwork.removeValue(forKey: network.rawValue)
        }
        persist()
    }

    func setExplorerOverride(_ url: String?, for network: TronNetwork) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            explorerOverridesByNetwork[network.rawValue] = trimmed
        } else {
            explorerOverridesByNetwork.removeValue(forKey: network.rawValue)
        }
        persist()
    }

    func setTokenCatalogURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenCatalogURL = trimmed.isEmpty ? TronTokenCatalog.defaultCatalogURL : trimmed
        persist()
    }

    func setLogoBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        logoBaseURL = trimmed.isEmpty ? TronSettings.defaultLogoBaseURL : trimmed
        persist()
    }

    // MARK: -- persistence

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
        tokenCatalogURL = TronTokenCatalog.defaultCatalogURL
        logoBaseURL = TronSettings.defaultLogoBaseURL
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let p = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        self.rpcOverridesByNetwork = p.rpcOverrides
        self.explorerOverridesByNetwork = p.explorerOverrides
        if let n = TronNetwork(rawValue: p.selectedNetwork) {
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
