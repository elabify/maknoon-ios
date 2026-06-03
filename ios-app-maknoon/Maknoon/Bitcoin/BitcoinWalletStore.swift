// User's list of Bitcoin wallets. Backed by UserDefaults JSON so the
// list survives app restarts. The actual BDK Wallet handle for each
// row is rebuilt on demand from the descriptor + sandwich seed (or
// cached xpub for hardware-backed wallets).
//
// The store also tracks the "active" wallet id used by the Wallet tab.

import Foundation
import Observation
import SwiftUI

@Observable
final class BitcoinWalletStore {
    private(set) var wallets: [BitcoinWalletDescriptor] = []
    private(set) var activeWalletId: UUID?

    /// Shared address book so each wallet can mirror its next-unused
    /// receive address as a read-only "Your wallets" contact. Set by
    /// HolderStore at launch. Weak to avoid the store keeping the
    /// address book alive on its own.
    weak var addressBook: AddressBookStore?

    /// Cached mirror address per wallet so we can re-publish on
    /// launch without rebuilding a BDK wallet. Populated by
    /// `BitcoinWalletView.refresh()` once it has a fresh
    /// `nextUnusedAddress`.
    private var mirrorAddressByWallet: [UUID: String] = [:]
    private static let mirrorKey = "networks.bitcoin.addressBook.mirror.v1"

    // Persistence root under "networks.bitcoin.*". One-time break:
    // any prior "btc.walletStore.*" entries are orphaned and the user
    // re-creates wallets via Manage wallets > Discover.
    private static let walletsKey = "networks.bitcoin.wallets.v1"
    private static let activeKey  = "networks.bitcoin.active.v1"

    init() {
        load()
    }

    var activeWallet: BitcoinWalletDescriptor? {
        guard let id = activeWalletId else { return wallets.first }
        return wallets.first(where: { $0.id == id }) ?? wallets.first
    }

    /// First-run seeding. If the store is empty when the user first
    /// opens the Bitcoin tab, we drop in a single default Mainnet
    /// software wallet at account 0 labelled "Bitcoin". The user can
    /// rename or add more from the wallet-management screen.
    func seedDefaultIfNeeded() {
        guard wallets.isEmpty else { return }
        let initial = BitcoinWalletDescriptor(
            label: "Bitcoin",
            kind: .software(account: 0),
            network: .mainnet
        )
        wallets = [initial]
        activeWalletId = initial.id
        persist()
    }

    func add(_ descriptor: BitcoinWalletDescriptor, makeActive: Bool = true) {
        wallets.append(descriptor)
        if makeActive { activeWalletId = descriptor.id }
        persist()
    }

    func remove(id: UUID) {
        wallets.removeAll { $0.id == id }
        if activeWalletId == id { activeWalletId = wallets.first?.id }
        mirrorAddressByWallet.removeValue(forKey: id)
        persistMirrorCache()
        persist()
        addressBook?.removeSystemWallet(walletId: id, chainKey: "bitcoin")
    }

    /// User-driven reorder from the wallet-list edit mode. Persists
    /// the new order so the picker + balance dashboards see the
    /// same arrangement on next launch.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        wallets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func rename(id: UUID, to label: String) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].label = label
        persist()
        // Re-publish the mirror so the contact name reflects the
        // new wallet label without waiting for the next refresh.
        if let address = mirrorAddressByWallet[id] {
            publishMirror(walletId: id, address: address)
        }
    }

    /// Called by `BitcoinWalletView.refresh()` after BDK has resolved
    /// the next-unused receive address. Caches it locally so we can
    /// re-publish at launch without rebuilding the wallet, then
    /// pushes it into the address book as a system contact.
    func updateMirrorAddress(walletId: UUID, address: String) {
        guard !address.isEmpty else { return }
        if mirrorAddressByWallet[walletId] != address {
            mirrorAddressByWallet[walletId] = address
            persistMirrorCache()
        }
        publishMirror(walletId: walletId, address: address)
    }

    /// Re-publish every cached mirror. Called once at launch by
    /// HolderStore so the address book is populated even before
    /// the user opens any wallet view.
    func remirrorAllToAddressBook() {
        for descriptor in wallets {
            guard let address = mirrorAddressByWallet[descriptor.id] else { continue }
            publishMirror(walletId: descriptor.id, address: address)
        }
    }

    private func publishMirror(walletId: UUID, address: String) {
        guard let addressBook,
              let descriptor = wallets.first(where: { $0.id == walletId })
        else { return }
        addressBook.upsertSystemWallet(
            walletId: walletId,
            chainKey: "bitcoin",
            name: descriptor.label,
            address: address,
            network: .bitcoin
        )
    }

    func markSynced(id: UUID, at date: Date = .init()) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].lastSyncAt = date
        persist()
    }

    /// Force the next refresh to run a full scan instead of an
    /// incremental sync. Called after BDK had to rebuild the local
    /// SQLite cache (otherwise the incremental sync would see zero
    /// revealed addresses and return empty, leaving the user
    /// staring at a phantom-zero wallet and assuming we drained it).
    func clearLastSync(id: UUID) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].lastSyncAt = nil
        persist()
    }

    /// Populate the cached account-level public key data on a wallet
    /// after the first derive-from-seed. Subsequent opens use this
    /// cache so they don't need to unlock the seed at all.
    func setCachedAccountKey(id: UUID, fingerprint: String, xpub: String) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx].cachedAccountFingerprint = fingerprint
        wallets[idx].cachedAccountXpub = xpub
        persist()
    }

    func setActive(_ id: UUID) {
        guard wallets.contains(where: { $0.id == id }) else { return }
        activeWalletId = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
    }

    /// Next unused account index for software wallets on a given
    /// network. Used by "Add software wallet" so we never collide.
    func nextSoftwareAccount(on network: BitcoinNetwork) -> UInt32 {
        let used: Set<UInt32> = Set(
            wallets.compactMap { w -> UInt32? in
                guard w.network == network,
                      case let .software(account) = w.kind
                else { return nil }
                return account
            }
        )
        var i: UInt32 = 0
        while used.contains(i) { i += 1 }
        return i
    }

    /// True if a software wallet already exists at this account index
    /// on the given network. The Add sheet uses it to block duplicates,
    /// which would otherwise derive the identical address.
    func hasSoftwareWallet(account: UInt32, on network: BitcoinNetwork) -> Bool {
        wallets.contains { w in
            guard w.network == network, case let .software(a) = w.kind else { return false }
            return a == account
        }
    }

    // MARK: -- persistence

    /// Reset to defaults then re-read UserDefaults (post-restore refresh).
    func reload() {
        wallets = []
        activeWalletId = nil
        mirrorAddressByWallet = [:]
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.walletsKey),
           let decoded = try? JSONDecoder().decode([BitcoinWalletDescriptor].self, from: data) {
            wallets = decoded
        }
        if let s = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: s) {
            activeWalletId = id
        }
        if let data = UserDefaults.standard.data(forKey: Self.mirrorKey),
           let decoded = try? JSONDecoder().decode([UUID: String].self, from: data) {
            mirrorAddressByWallet = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(wallets) {
            UserDefaults.standard.set(data, forKey: Self.walletsKey)
        }
        UserDefaults.standard.set(activeWalletId?.uuidString, forKey: Self.activeKey)
    }

    private func persistMirrorCache() {
        if let data = try? JSONEncoder().encode(mirrorAddressByWallet) {
            UserDefaults.standard.set(data, forKey: Self.mirrorKey)
        }
    }
}
