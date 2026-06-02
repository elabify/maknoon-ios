// Persisted metadata for a single Ethereum wallet.
//
// Ethereum EOAs are chain-agnostic: the same private key produces
// the same EIP-55 address on every EVM chain. Maknoon therefore
// stores ONE descriptor per (kind, account) pair, and lets the user
// switch which EVM network the wallet talks to at runtime via a
// dropdown above the balance card. The selected network is
// persisted separately on `EthereumWalletStore.currentNetworkByWallet`
// so it survives app restarts.
//
// This was a deliberate refactor away from the v1 model that had a
// `network` field on the descriptor itself: that forced users to
// create N copies of the same wallet for N chains, even though the
// underlying address and signing key were identical.

import Foundation

struct EthereumWalletDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    let kind: EthereumWalletKind
    let createdAt: Date
    var lastSyncAt: Date?

    /// EIP-55 checksummed account address. For software wallets,
    /// populated once at creation under a single biometric prompt;
    /// reused on every subsequent open with zero seed access. For
    /// hardware wallets, this duplicates `kind.hardware.address` so
    /// the view layer can read it uniformly.
    var cachedAddress: String?

    init(
        id: UUID = UUID(),
        label: String,
        kind: EthereumWalletKind,
        createdAt: Date = .init(),
        lastSyncAt: Date? = nil,
        cachedAddress: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.cachedAddress = cachedAddress
    }

    /// Resolved address regardless of kind. Falls back to the
    /// hardware kind's embedded address if the cache is empty.
    var address: String? {
        if let cached = cachedAddress, !cached.isEmpty { return cached }
        if case .hardware(_, _, let addr) = kind { return addr }
        return nil
    }
}
