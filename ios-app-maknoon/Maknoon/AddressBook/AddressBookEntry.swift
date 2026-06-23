// User's address book: per-network-type contacts. One entry
// covers every sub-network inside its major type (e.g. an
// Ethereum entry's address is valid on mainnet, Sepolia, Base,
// Arbitrum, … because EVM addresses are chain-agnostic).
//
// Lightning entries hold LUD-16 lightning addresses
// (`name@domain.com`), which the Send view resolves via LNURL-
// pay at send time. BOLT11 invoices aren't stored, they're
// single-use and expire.

import Foundation

enum AddressBookNetwork: String, Codable, CaseIterable, Hashable, Sendable {
    case bitcoin
    case ethereum
    case lightning
    case solana
    case tron

    var displayName: String {
        switch self {
        case .bitcoin:   return "Bitcoin"
        case .ethereum:  return "Ethereum"
        case .lightning: return "Lightning"
        case .solana:    return "Solana"
        case .tron:      return "Tron"
        }
    }

    var systemImage: String {
        switch self {
        case .bitcoin:   return "bitcoinsign.circle.fill"
        case .ethereum:  return "diamond.fill"
        case .lightning: return "bolt.fill"
        case .solana:    return "sun.max.fill"
        case .tron:      return "triangle.fill"
        }
    }

    var tint: String {
        // We pass these as strings since SwiftUI Color isn't
        // Codable; the picker view maps to a real Color.
        switch self {
        case .bitcoin:   return "orange"
        case .ethereum:  return "indigo"
        case .lightning: return "yellow"
        case .solana:    return "purple"
        case .tron:      return "red"
        }
    }
}

/// How an entry got into the address book. User entries are fully
/// editable / deletable; system entries are mirrors of the user's
/// own wallets, kept in sync with the wallet stores via
/// `AddressBookStore.replaceSystemEntries(forNetwork:entries:)`.
enum AddressBookEntrySource: Codable, Hashable, Sendable {
    case user
    case systemWallet(walletId: UUID, network: String)

    /// True iff edit/delete should be disabled in the UI. The system
    /// mirror manages its own lifecycle.
    var isReadOnly: Bool {
        switch self {
        case .user:         return false
        case .systemWallet: return true
        }
    }
}

struct AddressBookEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var address: String
    var network: AddressBookNetwork
    let createdAt: Date
    /// Defaults to `.user` so old-format records on disk decode
    /// cleanly. System entries are minted by `AddressBookStore`
    /// when a wallet is added; user entries are minted by the
    /// settings UI.
    var source: AddressBookEntrySource

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        network: AddressBookNetwork,
        createdAt: Date = .init(),
        source: AddressBookEntrySource = .user
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.network = network
        self.createdAt = createdAt
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.address = try c.decode(String.self, forKey: .address)
        self.network = try c.decode(AddressBookNetwork.self, forKey: .network)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.source = (try? c.decode(AddressBookEntrySource.self, forKey: .source)) ?? .user
    }
}
