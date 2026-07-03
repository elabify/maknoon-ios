// Per-network RPC + explorer overrides for Ethereum-family chains.
// Defaults live on `EthereumNetwork` itself; this @Observable store
// only holds user overrides + the global fiat code.
//
// Persistence: `networks.ethereum.settings.v1` JSON.

import Foundation
import Observation
import WalletCore

@Observable
final class EthereumSettings: @unchecked Sendable {
    var rpcURLByNetwork: [EthereumNetwork: String] = [:]
    var explorerURLByNetwork: [EthereumNetwork: String] = [:]
    var explorerAPIURLByNetwork: [EthereumNetwork: String] = [:]
    /// Optional Etherscan-family API key per network. Etherscan-v2
    /// supports unkeyed access at a low rate cap; heavy users add a
    /// key. Stored in UserDefaults (low-sensitivity).
    var explorerAPIKeyByNetwork: [EthereumNetwork: String] = [:]
    var fiatCode: String = "usd"
    /// JSON-RPC URL used for ENS name lookups. ENS lives on
    /// Ethereum mainnet, so even when sending on Sepolia or an L2
    /// we resolve against this endpoint. Empty means "use the
    /// mainnet RPC URL configured above". Users who run a personal
    /// node point this at their own URL.
    var ensRPCURL: String = ""
    /// Verified-token catalog URL. Defaults to Uniswap's multi-
    /// chain default list. User-overridable in Ethereum Settings so
    /// a hardened build can pin to a self-hosted mirror or a frozen
    /// snapshot.
    var tokenCatalogURL: String = EthereumTokenRegistry.defaultCatalogURL
    /// Template URL for token logos. The `{chain}` placeholder is
    /// replaced with the per-network Trust Wallet slug
    /// (`EthereumNetwork.trustWalletSlug`) and `{address}` with the
    /// checksummed contract address. Default points at Trust
    /// Wallet's assets repo.
    var logoTemplate: String = EthereumSettings.defaultLogoTemplate

    /// Self-hosted WalletConnect relay host (e.g. relay.example.com). Empty means
    /// the built-in default relay. This is a GLOBAL WalletConnect setting, not
    /// per-network (WalletConnect is EVM-only today but the relay is one config
    /// for all). Takes effect on next app launch (the relay is configured once at
    /// startup). Host only; any wss:// scheme or trailing slash is stripped on save.
    var walletConnectRelayHost: String = ""

    static let defaultLogoTemplate = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/{chain}/assets/{address}/logo.png"

    /// Per-token logo URL for a given network + contract. Returns
    /// nil when the network has no Trust Wallet slug (testnets,
    /// custom networks) or the template is malformed. The token row
    /// renders the monogram fallback in that case.
    func tokenLogoURL(network: EthereumNetwork, contract: String) -> URL? {
        guard let slug = network.trustWalletSlug else { return nil }
        let checksummed = EthereumSettings.checksumAddress(contract)
        let filled = logoTemplate
            .replacingOccurrences(of: "{chain}", with: slug)
            .replacingOccurrences(of: "{address}", with: checksummed)
        return URL(string: filled)
    }

    /// EIP-55 checksum the address. Trust Wallet's repo stores
    /// assets under the checksummed casing, and GitHub raw URLs are
    /// case-sensitive, so a lowercased path 404s. Implementation
    /// uses TWC's `EthereumAddress(string:)` which performs the
    /// checksum cast; falls back to the input if parsing fails so
    /// users entering already-checksummed addresses still resolve.
    private static func checksumAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let addr = WalletCore.AnyAddress(string: trimmed, coin: .ethereum) {
            return addr.description
        }
        return trimmed
    }

    private static let storeKey = "networks.ethereum.settings.v1"

    init() { load() }

    func rpcURL(for network: EthereumNetwork) -> String {
        // Honor a custom override only if it is a usable http(s) URL.
        // A malformed override (no scheme, whitespace) would otherwise be
        // handed to URLSession and fail every read with -1000 (bad URL),
        // wedging the chain. Fall back to the built-in default instead.
        if let override = rpcURLByNetwork[network], Self.isValidRPC(override) {
            return override
        }
        return network.defaultRPCURL
    }

    /// A custom RPC endpoint is usable only if it parses as an absolute
    /// http(s) URL with a host. URL(string:) is lenient and accepts
    /// scheme-less strings, but URLSession then rejects them with -1000.
    static func isValidRPC(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    func explorerURL(for network: EthereumNetwork) -> String {
        if let override = explorerURLByNetwork[network], !override.isEmpty {
            return override
        }
        return network.defaultExplorerURL
    }

    func explorerAPIURL(for network: EthereumNetwork) -> String? {
        if let override = explorerAPIURLByNetwork[network], !override.isEmpty {
            return override
        }
        return network.defaultExplorerAPIURL
    }

    func explorerAPIKey(for network: EthereumNetwork) -> String? {
        let key = explorerAPIKeyByNetwork[network] ?? ""
        return key.isEmpty ? nil : key
    }

    func explorerAddressURL(_ address: String, on network: EthereumNetwork) -> URL? {
        let base = explorerURL(for: network).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/address/\(address)")
    }

    func explorerTxURL(_ txHash: String, on network: EthereumNetwork) -> URL? {
        let base = explorerURL(for: network).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/tx/\(txHash)")
    }

    func setRPC(_ url: String, for network: EthereumNetwork) {
        // Store only a valid http(s) endpoint; anything else (empty,
        // scheme-less, garbage) clears the override so the network uses
        // its built-in default rather than failing reads with -1000.
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        rpcURLByNetwork[network] = Self.isValidRPC(trimmed) ? trimmed : ""
        persist()
    }

    func setExplorer(_ url: String, for network: EthereumNetwork) {
        explorerURLByNetwork[network] = url
        persist()
    }

    func setExplorerAPI(_ url: String, key: String, for network: EthereumNetwork) {
        explorerAPIURLByNetwork[network] = url
        explorerAPIKeyByNetwork[network] = key
        persist()
    }

    func setTokenCatalogURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenCatalogURL = trimmed.isEmpty ? EthereumTokenRegistry.defaultCatalogURL : trimmed
        persist()
    }

    func setLogoTemplate(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        logoTemplate = trimmed.isEmpty ? EthereumSettings.defaultLogoTemplate : trimmed
        persist()
    }

    func resetToDefaults() {
        rpcURLByNetwork = [:]
        explorerURLByNetwork = [:]
        explorerAPIURLByNetwork = [:]
        explorerAPIKeyByNetwork = [:]
        fiatCode = "usd"
        ensRPCURL = ""
        tokenCatalogURL = EthereumTokenRegistry.defaultCatalogURL
        walletConnectRelayHost = ""
        persist()
    }

    /// Resolved URL the ENS resolver should hit. Falls back to the
    /// mainnet RPC URL when the user hasn't set a dedicated ENS
    /// gateway, since ENS resolution always runs on Ethereum
    /// mainnet regardless of which network the user is sending on.
    func effectiveENSRPCURL() -> String {
        let override = ensRPCURL.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return rpcURL(for: .mainnet)
    }

    // MARK: -- persistence

    private struct Snapshot: Codable {
        var rpcURLByNetwork: [String: String]
        var explorerURLByNetwork: [String: String]
        var explorerAPIURLByNetwork: [String: String]
        var explorerAPIKeyByNetwork: [String: String]
        var fiatCode: String
        var ensRPCURL: String?
        var tokenCatalogURL: String?
        var logoTemplate: String?
        var walletConnectRelayHost: String?
    }

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        rpcURLByNetwork = [:]
        explorerURLByNetwork = [:]
        explorerAPIURLByNetwork = [:]
        explorerAPIKeyByNetwork = [:]
        fiatCode = "usd"
        ensRPCURL = ""
        tokenCatalogURL = EthereumTokenRegistry.defaultCatalogURL
        logoTemplate = EthereumSettings.defaultLogoTemplate
        walletConnectRelayHost = ""
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        rpcURLByNetwork = Self.dictFrom(snap.rpcURLByNetwork)
        explorerURLByNetwork = Self.dictFrom(snap.explorerURLByNetwork)
        explorerAPIURLByNetwork = Self.dictFrom(snap.explorerAPIURLByNetwork)
        explorerAPIKeyByNetwork = Self.dictFrom(snap.explorerAPIKeyByNetwork)
        fiatCode = snap.fiatCode
        ensRPCURL = snap.ensRPCURL ?? ""
        if let saved = snap.tokenCatalogURL, !saved.isEmpty {
            tokenCatalogURL = saved
        }
        if let saved = snap.logoTemplate, !saved.isEmpty {
            logoTemplate = saved
        }
        walletConnectRelayHost = snap.walletConnectRelayHost ?? ""
        // Etherscan retired most of the per-chain v1 hostnames in
        // 2024 (api-sepolia.etherscan.io, api.arbiscan.io, ...) and
        // returns either NSURLError -1003 or a deprecation banner.
        // If a user previously configured one of those, clear it so
        // the v2 default kicks in.
        // Reset overrides that we know have become stale across
        // the app's lifetime so the new Blockscout defaults take
        // over without user intervention. Two cases:
        //   * Etherscan v1 per-chain hosts (DNS-retired in 2024).
        //   * Etherscan v2 unified host that we shipped for one
        //     brief build but moved off in favour of Blockscout
        //     since it requires an API key.
        let staleHosts: Set<String> = [
            "api.etherscan.io", "api-sepolia.etherscan.io",
            "api.arbiscan.io", "api-sepolia.arbiscan.io",
            "api-optimistic.etherscan.io", "api-sepolia-optimism.etherscan.io",
            "api.basescan.org", "api-sepolia.basescan.org",
            "api.polygonscan.com", "api-zkevm.polygonscan.com",
            "api.bscscan.com",
            "api.scrollscan.com", "api.lineascan.build",
            "api.mantlescan.xyz",
        ]
        var changed = false
        for (net, url) in explorerAPIURLByNetwork {
            if let host = URL(string: url)?.host, staleHosts.contains(host) {
                explorerAPIURLByNetwork.removeValue(forKey: net)
                changed = true
            }
        }
        if changed { persist() }
    }

    func persist() {
        let snap = Snapshot(
            rpcURLByNetwork: Self.dictTo(rpcURLByNetwork),
            explorerURLByNetwork: Self.dictTo(explorerURLByNetwork),
            explorerAPIURLByNetwork: Self.dictTo(explorerAPIURLByNetwork),
            explorerAPIKeyByNetwork: Self.dictTo(explorerAPIKeyByNetwork),
            fiatCode: fiatCode,
            ensRPCURL: ensRPCURL,
            tokenCatalogURL: tokenCatalogURL,
            logoTemplate: logoTemplate,
            walletConnectRelayHost: walletConnectRelayHost
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private static func dictFrom(_ raw: [String: String]) -> [EthereumNetwork: String] {
        Dictionary(uniqueKeysWithValues: raw.compactMap {
            guard let n = EthereumNetwork(rawValue: $0.key) else { return nil }
            return (n, $0.value)
        })
    }

    private static func dictTo(_ d: [EthereumNetwork: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: d.map { ($0.key.rawValue, $0.value) })
    }
}
