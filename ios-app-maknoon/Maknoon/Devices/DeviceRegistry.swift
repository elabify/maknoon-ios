// Persistence + observable model for the user's registered hardware
// devices. Lives on HolderStore as `store.devices` so any view can
// observe the list.

import Foundation
import Observation

@Observable
final class DeviceRegistry: @unchecked Sendable {
    private(set) var devices: [RegisteredDevice] = []

    private static let storeKey = "devices.registered.v1"

    init() {
        load()
    }

    /// Drop the in-memory cache and re-read from UserDefaults. Used by
    /// the wallet-wide reset path so the wipe surfaces immediately
    /// without waiting for a force-quit.
    func reload() {
        devices = []
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([RegisteredDevice].self, from: data) {
            devices = decoded
        }
    }

    func find(serial: String) -> RegisteredDevice? {
        devices.first(where: { $0.serial == serial })
    }

    func find(id: UUID) -> RegisteredDevice? {
        devices.first(where: { $0.id == id })
    }

    /// Register a new device, OR return the existing record if a
    /// device with the same `(kind, serial)` was previously
    /// registered. Idempotent so re-running the "Register device"
    /// flow on the same physical device does not create duplicates.
    @discardableResult
    func register(
        kind: DeviceKind,
        serial: String,
        label: String,
        peripheralUUID: UUID? = nil
    ) -> RegisteredDevice {
        if let existing = find(serial: serial), existing.kind == kind {
            // Upgrade the existing record's peripheralUUID if it's
            // unset (pre-existing device, this is its first connect
            // since we added the field) or if it changed (rare:
            // user un-paired in System Bluetooth + re-paired). We
            // never overwrite a stable UUID with nil.
            if let pu = peripheralUUID,
               existing.peripheralUUID != pu,
               let idx = devices.firstIndex(where: { $0.id == existing.id }) {
                devices[idx].peripheralUUID = pu
                persist()
                return devices[idx]
            }
            return existing
        }
        let record = RegisteredDevice(
            kind: kind,
            serial: serial,
            label: label,
            peripheralUUID: peripheralUUID
        )
        devices.append(record)
        persist()
        return record
    }

    /// Update a device's persisted peripheral UUID. Called after a
    /// successful connect when we want to upgrade an old record
    /// in-place without going through full `register(...)`.
    func setPeripheralUUID(deviceId: UUID, peripheralUUID: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        if devices[idx].peripheralUUID == peripheralUUID { return }
        devices[idx].peripheralUUID = peripheralUUID
        persist()
    }

    func remove(id: UUID) {
        devices.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to label: String) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[idx].label = label
        persist()
    }

    func setIdentityPromotion(deviceId: UUID, promotion: RegisteredDevice.IdentityPromotion?) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].promotions.identity = promotion
        persist()
    }

    func addBitcoinWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        if !devices[idx].promotions.bitcoinWalletIds.contains(walletId) {
            devices[idx].promotions.bitcoinWalletIds.append(walletId)
            persist()
        }
    }

    func removeBitcoinWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].promotions.bitcoinWalletIds.removeAll { $0 == walletId }
        persist()
    }

    func addEthereumWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        if !devices[idx].promotions.ethereumWalletIds.contains(walletId) {
            devices[idx].promotions.ethereumWalletIds.append(walletId)
            persist()
        }
    }

    func removeEthereumWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].promotions.ethereumWalletIds.removeAll { $0 == walletId }
        persist()
    }

    func addSolanaWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        if !devices[idx].promotions.solanaWalletIds.contains(walletId) {
            devices[idx].promotions.solanaWalletIds.append(walletId)
            persist()
        }
    }

    func removeSolanaWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].promotions.solanaWalletIds.removeAll { $0 == walletId }
        persist()
    }

    func addTronWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        if !devices[idx].promotions.tronWalletIds.contains(walletId) {
            devices[idx].promotions.tronWalletIds.append(walletId)
            persist()
        }
    }

    func removeTronWallet(deviceId: UUID, walletId: UUID) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx].promotions.tronWalletIds.removeAll { $0 == walletId }
        persist()
    }

    /// Drop a wallet id from every device's promotion list. Called as
    /// a cleanup pass when a wallet is removed from its store so the
    /// "Bitcoin" / "Ethereum" badges on Settings > Devices accurately
    /// reflect what's currently linked, instead of carrying stale
    /// uuids that point to deleted wallets.
    func scrubWalletId(_ walletId: UUID) {
        var dirty = false
        for idx in devices.indices {
            let before = (
                devices[idx].promotions.bitcoinWalletIds.count,
                devices[idx].promotions.ethereumWalletIds.count,
                devices[idx].promotions.solanaWalletIds.count,
                devices[idx].promotions.tronWalletIds.count
            )
            devices[idx].promotions.bitcoinWalletIds.removeAll { $0 == walletId }
            devices[idx].promotions.ethereumWalletIds.removeAll { $0 == walletId }
            devices[idx].promotions.solanaWalletIds.removeAll { $0 == walletId }
            devices[idx].promotions.tronWalletIds.removeAll { $0 == walletId }
            let after = (
                devices[idx].promotions.bitcoinWalletIds.count,
                devices[idx].promotions.ethereumWalletIds.count,
                devices[idx].promotions.solanaWalletIds.count,
                devices[idx].promotions.tronWalletIds.count
            )
            if before != after { dirty = true }
        }
        if dirty { persist() }
    }

    /// Backup-restore-only: replace the device list wholesale,
    /// preserving the original UUIDs + promotions so wallets that
    /// reference a deviceId still resolve to the right device after
    /// the restore. The user-facing `register(...)` path always
    /// mints a fresh UUID, which would orphan the wallet→device
    /// linkage on every restore.
    func replaceAll(_ replacement: [RegisteredDevice]) {
        devices = replacement
        persist()
    }

    // MARK: -- queries used by per-network settings views

    func devicesSupporting(_ capability: DeviceKind.Capabilities) -> [RegisteredDevice] {
        devices.filter { $0.kind.capabilities.contains(capability) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
