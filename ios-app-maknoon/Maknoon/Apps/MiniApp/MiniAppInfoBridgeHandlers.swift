// Read-only "addressBook" and "fiat" bridge namespaces.
//
// Both return only non-secret data and never sign or move funds:
//   * addressBook.list({chain}) -> the user's saved addresses for that chain,
//     including their own wallets (mirrored in by the wallet stores), so a POS
//     can offer a receive-address picker instead of a raw text field.
//   * fiat.quote({chain, network?}) -> the configured fiat code + the native
//     coin's spot rate, so a app can show fiat-equivalents and offer
//     fiat-first amount entry.
//
// addressBook requires the "payment" permission (it exposes the user's
// address list); fiat is public market data and needs no grant.

import Foundation

@MainActor
final class AddressBookBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "addressBook"
    let requiredPermission: String? = "payment"

    private let store: HolderStore
    init(store: HolderStore) { self.store = store }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "addressBook.list":
            guard let chain = (params as? [String: Any])?["chain"] as? String,
                  let network = Self.network(for: chain) else {
                throw MiniAppBridgeError.invalidParams("addressBook.list requires a known `chain`")
            }
            let grouped = store.addressBook.entriesGrouped(for: network)
            let ordered = grouped.system + grouped.user  // own wallets first
            return ordered.map { e -> [String: Any] in
                [
                    "name": e.name,
                    "address": e.address,
                    "network": e.network.rawValue,
                    "isOwnWallet": Self.isOwnWallet(e.source),
                ]
            }
        default:
            throw MiniAppBridgeError.unsupported("addressBook.\(method)")
        }
    }

    private static func network(for chain: String) -> AddressBookNetwork? {
        switch chain.lowercased() {
        case "bitcoin", "btc":  return .bitcoin
        case "ethereum", "evm", "eth": return .ethereum
        case "solana", "sol":   return .solana
        case "tron", "trx":     return .tron
        case "lightning", "ln": return .lightning
        default: return nil
        }
    }

    private static func isOwnWallet(_ source: AddressBookEntrySource) -> Bool {
        if case .systemWallet = source { return true }
        return false
    }
}

@MainActor
final class FiatBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "fiat"
    let requiredPermission: String? = nil

    private let store: HolderStore
    init(store: HolderStore) { self.store = store }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "fiat.quote":
            let p = params as? [String: Any] ?? [:]
            guard let chain = p["chain"] as? String else {
                throw MiniAppBridgeError.invalidParams("fiat.quote requires `chain`")
            }
            let network = p["network"] as? String
            let fiatCode = store.fiatPreferences.code
            let (coinId, ticker) = Self.coin(for: chain, network: network)
            var rate: Double? = nil
            if let coinId { rate = store.assetPrices.price(asset: coinId, fiat: fiatCode) }
            var out: [String: Any] = [
                "fiatCode": fiatCode.uppercased(),
                "ticker": ticker,
            ]
            out["coinId"] = coinId.map { $0 as Any } ?? NSNull()
            // rate is null when there's no spot price (e.g. testnets): the
            // app should fall back to crypto-only entry.
            out["rate"] = rate.map { $0 as Any } ?? NSNull()
            return out
        default:
            throw MiniAppBridgeError.unsupported("fiat.\(method)")
        }
    }

    /// Map a chain (+ EVM network rawValue) to its CoinGecko id + ticker.
    nonisolated static func coin(for chain: String, network: String?) -> (String?, String) {
        switch chain.lowercased() {
        case "bitcoin", "btc":
            return ("bitcoin", "BTC")
        case "lightning", "ln":
            // Priced as BTC; the POS converts the BTC rate to sats.
            return ("bitcoin", "sats")
        case "solana", "sol":
            return ("solana", "SOL")
        case "tron", "trx":
            return ("tron", "TRX")
        case "ethereum", "evm", "eth":
            if let raw = network, let net = EthereumNetwork(rawValue: raw) {
                return (net.coinGeckoAssetId, net.ticker)
            }
            return ("ethereum", "ETH")
        default:
            return (nil, "")
        }
    }
}
