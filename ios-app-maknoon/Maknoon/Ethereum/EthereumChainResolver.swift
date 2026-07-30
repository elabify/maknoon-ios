// Map an EIP-155 chain id onto a network the user has actually configured,
// across built-in chains and user-defined custom ones. Anything that arrives
// carrying a chain id from outside the app (a WalletConnect request, an
// EIP-1193 mini-app call, an EIP-681 payment QR) has to go through here so we
// never talk to an endpoint the user never configured, and never silently treat
// "chain X" as "whatever chain the wallet happens to be on".

import Foundation

enum EthereumChainResolver {

    /// The configured network id for `chainId`, or nil when the user has not
    /// configured that chain.
    static func networkID(for chainId: UInt64, store: HolderStore) -> EthereumNetworkID? {
        if let builtin = EthereumNetwork.allCases.first(where: { $0.chainId == chainId }) {
            return .builtin(builtin)
        }
        if let custom = store.ethereumCustomNetworks.networks.first(where: { $0.chainId == chainId }) {
            return .custom(custom.id)
        }
        return nil
    }

    /// The flat network config (RPC URL, explorer, display name) for `chainId`,
    /// or nil when that chain is not configured.
    static func resolved(for chainId: UInt64, store: HolderStore) -> ResolvedNetwork? {
        guard let id = networkID(for: chainId, store: store) else { return nil }
        return store.ethereumWalletStore.resolve(
            id,
            customs: store.ethereumCustomNetworks,
            settings: store.ethereumSettings
        )
    }
}
