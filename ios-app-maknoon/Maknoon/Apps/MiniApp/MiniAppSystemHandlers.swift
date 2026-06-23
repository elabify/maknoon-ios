// Low-friction native capabilities for mini apps:
//   * device  (auto)      : read host context + a Face ID gate for the app's
//                           own sensitive screens (returns only a bool).
//   * haptic  (auto)      : success/error/impact feedback.
//   * clipboard (install) : write-only copy (never reads the pasteboard).
//   * share   (install)   : system share sheet (user-mediated) + file export.
//   * wallet  (install)   : read the user's own wallet addresses per chain.
//
// Nothing here exposes raw sensors or keys: authenticate returns ok/!ok,
// device.info is non-secret context, wallet.getAccounts is public addresses.

import Foundation
import UIKit
import LocalAuthentication

@MainActor
final class DeviceBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "device"
    let requiredPermission: String? = nil
    private let store: HolderStore
    /// The user's selected app-language identifier (e.g. "ar", "zh-Hans", "en").
    /// Reported as `locale` so mini-apps localize to the chosen app language, not
    /// the (possibly different) OS locale.
    private let localeIdentifier: String
    init(store: HolderStore, localeIdentifier: String = Locale.current.identifier) {
        self.store = store
        self.localeIdentifier = localeIdentifier
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "device.info":
            let dark = UITraitCollection.current.userInterfaceStyle == .dark
            return [
                "theme": dark ? "dark" : "light",
                "locale": localeIdentifier,
                "fiatCode": store.fiatPreferences.code.uppercased(),
                "appVersion": MaknoonVersion.currentString,
            ]
        case "device.authenticate":
            let reason = (params as? [String: Any])?["reason"] as? String ?? "Authenticate"
            let ctx = LAContext()
            var err: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
                return ["ok": false, "reason": "unavailable"]
            }
            do {
                let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return ["ok": ok]
            } catch {
                return ["ok": false, "reason": "failed"]
            }
        default:
            throw MiniAppBridgeError.unsupported("device.\(method)")
        }
    }
}

@MainActor
final class HapticBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "haptic"
    let requiredPermission: String? = nil
    func handle(method: String, params: Any?) async throws -> Any? {
        guard method == "haptic.fire" else { throw MiniAppBridgeError.unsupported("haptic.\(method)") }
        let kind = (params as? [String: Any])?["kind"] as? String ?? "light"
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":   UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "heavy":   UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "medium":  UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default:        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        return NSNull()
    }
}

@MainActor
final class ClipboardBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "clipboard"
    let requiredPermission: String? = "clipboard"
    func handle(method: String, params: Any?) async throws -> Any? {
        guard method == "clipboard.write" else { throw MiniAppBridgeError.unsupported("clipboard.\(method)") }
        guard let text = (params as? [String: Any])?["text"] as? String else {
            throw MiniAppBridgeError.invalidParams("clipboard.write requires `text`")
        }
        UIPasteboard.general.string = text
        return NSNull()
    }
}

@MainActor
final class ShareBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "share"
    let requiredPermission: String? = "share"
    func handle(method: String, params: Any?) async throws -> Any? {
        let p = params as? [String: Any] ?? [:]
        var items: [Any] = []
        switch method {
        case "share.text":
            guard let text = p["text"] as? String else { throw MiniAppBridgeError.invalidParams("share.text requires `text`") }
            items = [text]
        case "share.file":
            // { fileName, text } -> write to a temp file and share it (e.g. a CSV receipt).
            guard let name = p["fileName"] as? String, let text = p["text"] as? String else {
                throw MiniAppBridgeError.invalidParams("share.file requires { fileName, text }")
            }
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
            do { try text.data(using: .utf8)?.write(to: url) } catch {
                throw MiniAppBridgeError.internalError("could not write file")
            }
            items = [url]
        default:
            throw MiniAppBridgeError.unsupported("share.\(method)")
        }
        guard let top = Self.topViewController() else {
            throw MiniAppBridgeError.internalError("no presenter")
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
        return NSNull()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

@MainActor
final class WalletBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "wallet"
    let requiredPermission: String? = "wallet"
    private let store: HolderStore
    init(store: HolderStore) { self.store = store }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "wallet.getAccounts":
            guard let chain = (params as? [String: Any])?["chain"] as? String,
                  let network = Self.network(for: chain) else {
                throw MiniAppBridgeError.invalidParams("wallet.getAccounts requires a known `chain`")
            }
            // The user's OWN wallets are mirrored into the address book as
            // system entries; surface just those (label + address).
            let own = store.addressBook.entriesGrouped(for: network).system
            return own.map { ["name": $0.name, "address": $0.address, "network": $0.network.rawValue] }
        case "wallet.getAssets":
            // PoS 1.0.1 Milestone 1 (B): the assets a chain/network can pay
            // in. Native first, then the chain's known stablecoins (USDC then
            // USDT), then any tokens the user holds in the token store, deduped
            // by contract/mint. No live RPC here: an optional `balance` string
            // is included only when the token store already has one cached
            // (today the stores carry no balances, so it is omitted).
            guard let chain = (params as? [String: Any])?["chain"] as? String,
                  let network = Self.network(for: chain) else {
                throw MiniAppBridgeError.invalidParams("wallet.getAssets requires a known `chain`")
            }
            let networkParam = (params as? [String: Any])?["network"] as? String
            return assets(for: network, networkParam: networkParam)
        case "wallet.getNetworks":
            // The wallet's supported networks for a chain family, ordered like
            // the Add-wallet "Chain to scan" dropdowns: primary mainnet first,
            // the other mainnets alphabetically, then testnets alphabetically
            // (a consumer can split on isTestnet). -> [{ id, label, isTestnet }]
            guard let chain = (params as? [String: Any])?["chain"] as? String,
                  let network = Self.network(for: chain) else {
                throw MiniAppBridgeError.invalidParams("wallet.getNetworks requires a known `chain`")
            }
            return networks(for: network)
        default:
            // wallet.signMessage (multi-chain) is a planned follow-on; EVM apps
            // can personal_sign today via window.ethereum.
            throw MiniAppBridgeError.unsupported("wallet.\(method)")
        }
    }

    private static func network(for chain: String) -> AddressBookNetwork? {
        switch chain.lowercased() {
        case "bitcoin", "btc":  return .bitcoin
        case "ethereum", "evm": return .ethereum
        case "solana", "sol":   return .solana
        case "tron", "trx":     return .tron
        default: return nil
        }
    }

    // MARK: -- wallet.getNetworks

    /// Order a chain's networks like the Add-wallet dropdowns: the primary
    /// mainnet first, the other mainnets alphabetically by label, then the
    /// testnets alphabetically by label.
    private func orderedNetworks<T>(
        all: [T], primary: T, isTestnet: (T) -> Bool, id: (T) -> String, label: (T) -> String
    ) -> [[String: Any]] where T: Equatable {
        let mainnets = [primary] + all
            .filter { $0 != primary && !isTestnet($0) }
            .sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
        let testnets = all
            .filter { isTestnet($0) }
            .sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
        return (mainnets + testnets).map {
            ["id": id($0), "label": label($0), "isTestnet": isTestnet($0)]
        }
    }

    private func networks(for network: AddressBookNetwork) -> [[String: Any]] {
        switch network {
        case .ethereum:
            return orderedNetworks(
                all: EthereumNetwork.allCases, primary: .mainnet,
                isTestnet: { $0.isTestnet }, id: { $0.rawValue }, label: { $0.displayName })
        case .solana:
            // Solana/Tron/Bitcoin enums have no isTestnet member; mainnet is the
            // only non-testnet for each, so derive it inline.
            return orderedNetworks(
                all: SolanaNetwork.allCases, primary: .mainnet,
                isTestnet: { $0 != .mainnet }, id: { $0.rawValue }, label: { $0.displayName })
        case .tron:
            return orderedNetworks(
                all: TronNetwork.allCases, primary: .mainnet,
                isTestnet: { $0 != .mainnet }, id: { $0.rawValue }, label: { $0.displayName })
        case .bitcoin, .lightning:
            return orderedNetworks(
                all: BitcoinNetwork.allCases, primary: .mainnet,
                isTestnet: { $0 != .mainnet }, id: { $0.rawValue }, label: { $0.displayName })
        }
    }

    // MARK: -- wallet.getAssets

    /// One asset entry. `contract` carries the EVM/Tron contract or the
    /// Solana mint; it is NSNull for native coins. `balance` is omitted
    /// entirely unless a cached value is available (it never is today).
    private func asset(symbol: String, name: String, contract: String?, decimals: Int, kind: String) -> [String: Any] {
        [
            "symbol": symbol,
            "name": name,
            "contract": contract.map { $0 as Any } ?? NSNull(),
            "decimals": decimals,
            "kind": kind,
        ]
    }

    private func assets(for network: AddressBookNetwork, networkParam: String?) -> [[String: Any]] {
        switch network {
        case .ethereum: return ethereumAssets(networkParam: networkParam)
        case .solana:   return solanaAssets(networkParam: networkParam)
        case .tron:     return tronAssets(networkParam: networkParam)
        case .bitcoin, .lightning:
            // The app hides the asset field for Bitcoin/Lightning; return
            // native BTC defensively if asked.
            return [asset(symbol: "BTC", name: "Bitcoin", contract: nil, decimals: 8, kind: "native")]
        }
    }

    /// Sort non-native assets alphabetically by symbol (case-insensitive) so
    /// the native coin stays first and every other asset (stablecoins + held,
    /// deduped) reads in a stable A-Z order.
    private func sortedNonNative(_ assets: [[String: Any]]) -> [[String: Any]] {
        assets.sorted {
            let a = ($0["symbol"] as? String) ?? ""
            let b = ($1["symbol"] as? String) ?? ""
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private func ethereumAssets(networkParam: String?) -> [[String: Any]] {
        // Resolve the EVM network from the param (defaults to mainnet).
        let net = networkParam.flatMap { EthereumNetwork(rawValue: $0) } ?? .mainnet
        var rest: [[String: Any]] = []
        var seen = Set<String>()
        // Curated reputable tokens (USDC/USDT/...) then user-held tokens, deduped.
        for t in EthereumTokenCatalog.reputable(for: net) {
            let key = t.contractAddress.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rest.append(asset(symbol: t.symbol, name: t.name, contract: t.contractAddress, decimals: t.decimals, kind: "erc20"))
        }
        for t in store.ethereumTokenStore.tokens(on: net) {
            let key = t.contractAddress.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rest.append(asset(symbol: t.symbol, name: t.name, contract: t.contractAddress, decimals: t.decimals, kind: "erc20"))
        }
        // Native first, then everything else sorted alphabetically by symbol.
        return [asset(symbol: net.ticker, name: net.displayName, contract: nil, decimals: 18, kind: "native")]
            + sortedNonNative(rest)
    }

    private func solanaAssets(networkParam: String?) -> [[String: Any]] {
        let net = networkParam.flatMap { SolanaNetwork(rawValue: $0) } ?? .mainnet
        var rest: [[String: Any]] = []
        var seen = Set<String>()
        // VERIFIED stablecoin mints (Circle / Tether) then user-held SPL tokens.
        for stable in Self.solanaStablecoins(for: net) {
            guard !seen.contains(stable.mint) else { continue }
            seen.insert(stable.mint)
            rest.append(asset(symbol: stable.symbol, name: stable.name, contract: stable.mint, decimals: stable.decimals, kind: "spl"))
        }
        for t in store.solanaSPLTokenStore.tokens(on: net) {
            guard !seen.contains(t.mint) else { continue }
            seen.insert(t.mint)
            rest.append(asset(symbol: t.symbol, name: t.name, contract: t.mint, decimals: Int(t.decimals), kind: "spl"))
        }
        return [asset(symbol: "SOL", name: "Solana", contract: nil, decimals: 9, kind: "native")]
            + sortedNonNative(rest)
    }

    private func tronAssets(networkParam: String?) -> [[String: Any]] {
        let net = networkParam.flatMap { TronNetwork(rawValue: $0) } ?? .mainnet
        var rest: [[String: Any]] = []
        var seen = Set<String>()
        for stable in Self.tronStablecoins(for: net) {
            guard !seen.contains(stable.contract) else { continue }
            seen.insert(stable.contract)
            rest.append(asset(symbol: stable.symbol, name: stable.name, contract: stable.contract, decimals: stable.decimals, kind: "trc20"))
        }
        for t in store.tronTRC20TokenStore.tokens(on: net) {
            guard !seen.contains(t.contract) else { continue }
            seen.insert(t.contract)
            rest.append(asset(symbol: t.symbol, name: t.name, contract: t.contract, decimals: Int(t.decimals), kind: "trc20"))
        }
        return [asset(symbol: "TRX", name: "Tron", contract: nil, decimals: 6, kind: "native")]
            + sortedNonNative(rest)
    }

    // MARK: -- baked-in stablecoin constants (verified Circle / Tether / Tronscan)

    private struct StableMint { let symbol: String; let name: String; let mint: String; let decimals: Int }
    private struct StableContract { let symbol: String; let name: String; let contract: String; let decimals: Int }

    /// Solana USDC/USDT mints. Mainnet has both; devnet has USDC only;
    /// testnet has no canonical stablecoin.
    private static func solanaStablecoins(for network: SolanaNetwork) -> [StableMint] {
        switch network {
        case .mainnet:
            return [
                StableMint(symbol: "USDC", name: "USD Coin", mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6),
                StableMint(symbol: "USDT", name: "Tether USD", mint: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", decimals: 6),
            ]
        case .devnet:
            return [
                StableMint(symbol: "USDC", name: "USD Coin", mint: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU", decimals: 6),
            ]
        case .testnet:
            return []
        }
    }

    /// Tron USDT (TRC-20). Mainnet only; Circle does not support USDC on
    /// Tron and the Nile/Shasta testnets have no canonical stablecoin.
    private static func tronStablecoins(for network: TronNetwork) -> [StableContract] {
        switch network {
        case .mainnet:
            return [
                StableContract(symbol: "USDT", name: "Tether USD", contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", decimals: 6),
            ]
        case .shasta, .nile:
            return []
        }
    }
}
