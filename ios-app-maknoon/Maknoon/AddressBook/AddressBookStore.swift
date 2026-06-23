// Persistent @Observable address book. Entries are kept in
// arrival order; views can group by network as needed.
//
// No address-format validation here; the network's send flow
// validates at send time. We accept whatever the user typed so
// they can save partial / not-yet-funded addresses for later.

import Foundation
import Observation

@Observable
final class AddressBookStore: @unchecked Sendable {
    private(set) var entries: [AddressBookEntry] = []

    private static let storeKey = "addressBook.v1"

    init() { load() }

    // MARK: -- query

    func entries(for network: AddressBookNetwork) -> [AddressBookEntry] {
        entries.filter { $0.network == network }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Entries grouped by source for the picker / settings views.
    /// System (wallet-mirror) entries surface as "Your wallets";
    /// user-entered contacts surface as "Contacts".
    func entriesGrouped(for network: AddressBookNetwork) -> (system: [AddressBookEntry], user: [AddressBookEntry]) {
        let all = entries(for: network)
        return (
            all.filter { if case .systemWallet = $0.source { return true } else { return false } },
            all.filter { if case .user = $0.source { return true } else { return false } }
        )
    }

    // MARK: -- mutate

    func add(_ entry: AddressBookEntry) {
        entries.append(entry)
        persist()
    }

    func update(_ entry: AddressBookEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        // Defensive: never let the UI flip a system entry to user
        // (or vice versa). The store is the single owner of the
        // source field; settings edits only mutate name/address.
        var next = entry
        next.source = entries[idx].source
        entries[idx] = next
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Mirror a wallet into the address book as a read-only system
    /// entry. Called from each chain's WalletStore.add hook. Safe
    /// to call repeatedly; updates the existing mirror in place if
    /// the wallet's label / address changed.
    func upsertSystemWallet(
        walletId: UUID,
        chainKey: String,
        name: String,
        address: String,
        network: AddressBookNetwork
    ) {
        let predicate: (AddressBookEntry) -> Bool = { entry in
            if case let .systemWallet(id, key) = entry.source {
                return id == walletId && key == chainKey
            }
            return false
        }
        if let idx = entries.firstIndex(where: predicate) {
            entries[idx].name = name
            entries[idx].address = address
            entries[idx].network = network
        } else {
            entries.append(AddressBookEntry(
                name: name,
                address: address,
                network: network,
                source: .systemWallet(walletId: walletId, network: chainKey)
            ))
        }
        persist()
    }

    /// Drop the mirror for a deleted wallet. No-op if the wallet
    /// never had one.
    func removeSystemWallet(walletId: UUID, chainKey: String) {
        entries.removeAll { entry in
            if case let .systemWallet(id, key) = entry.source {
                return id == walletId && key == chainKey
            }
            return false
        }
        persist()
    }

    /// Bulk replace, used by settings-backup restore. Hands the
    /// full list over wholesale; existing entries are dropped.
    func replaceAll(_ next: [AddressBookEntry]) {
        entries = next
        persist()
    }

    // MARK: -- persistence

    /// Drop the in-memory cache and re-read from UserDefaults. Used by
    /// the wallet-wide reset path so the wipe surfaces immediately
    /// without waiting for a force-quit.
    func reload() {
        entries = []
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([AddressBookEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
