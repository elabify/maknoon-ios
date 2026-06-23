// Codable settings snapshot for export / import and for bundling
// inside the iCloud encrypted backup.
//
// CONTRACT, what's in / what's NOT:
//
//   IN: per-network RPC / Electrum / mempool / explorer / API-key
//       overrides; fiat code; known-issuer allow-list; registered
//       hardware devices (serial + label + kind). Public-only
//       state that's nice to round-trip across reinstalls and
//       demo machines.
//
//   NOT IN: BIP39 entropy, BIP39 mnemonic, sandwich passphrase,
//       AES wrap keys, master keys, raw private keys, wallet
//       descriptors (because they reference seed material that
//       isn't transferable), credentials, hardware wrap blobs.
//
// File format is JSON. JSON is a subset of YAML 1.2, so the
// exported file is also valid YAML, you can rename `.json` to
// `.yaml` if you want to hand-edit it in a YAML editor without
// reformatting.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// The standalone YAML settings backup (file-picker export/import)
// was removed when the encrypted backup became the single backup
// path. The `SettingsBackup` struct below is still used: the
// encrypted-backup flow snapshots it into the encrypted plaintext
// (see iCloudBackup.swift / BackupPlaintext.settings), and the
// restore path applies it via `SettingsBackup.apply(to:)`. The
// standalone FileDocument wrapper + the `UTType.yaml` extension
// that were here are gone, neither has callers anymore.


struct SettingsBackup: Codable {
    /// Schema version. Bumped on incompatible field additions or
    /// renames. Import is ALWAYS best-effort: a newer-version file
    /// gets read for everything this build understands and the
    /// unknown items are reported via `SettingsBackupReport.skipped`.
    /// An older-version file restores fine because the schema
    /// only grows additively (new fields are added as `Optional`,
    /// existing fields are never removed or renamed without a
    /// major-version bump).
    ///
    /// Convention going forward:
    ///   - Adding an optional field: keep v unchanged.
    ///   - Removing/renaming a field, or making a field required:
    ///     bump v, update the apply path to handle both shapes.
    let v: Int
    static let currentVersion: Int = 2

    let exportedAt: Date
    let appVersion: String?
    let knownIssuers: [String]
    let bitcoin: BitcoinSection?
    let ethereum: EthereumSection?
    let devices: [DeviceSection]?
    let addressBook: [AddressBookEntry]?

    struct BitcoinSection: Codable {
        let fiatCode: String
        let coinGeckoBaseURL: String
        let electrumByNetwork: [String: ElectrumConfig]
        let mempoolURLByNetwork: [String: String]
        let explorerURLByNetwork: [String: String]

        struct ElectrumConfig: Codable {
            let url: String
            let pinnedCertSHA256: String
        }
    }

    struct EthereumSection: Codable {
        let fiatCode: String
        let rpcURLByNetwork: [String: String]
        let explorerURLByNetwork: [String: String]
        let explorerAPIURLByNetwork: [String: String]
        let explorerAPIKeyByNetwork: [String: String]
    }

    struct DeviceSection: Codable {
        let id: UUID
        let kind: String       // matches DeviceKind.rawValue
        let serial: String
        let label: String
        let registeredAt: Date
        // Promotions ride along so the device's wallet linkage (the
        // "Bitcoin" / "Ethereum" badges + the identity sandwich
        // enrollment record) survives a restore. Wallet ids do
        // transfer across installs because the wallet store snapshot
        // in `walletState.networks.bitcoin.wallets.v1` /
        // `networks.ethereum.wallets.v2` preserves them verbatim.
        // Optional for backward compatibility with v1/v2 backups.
        let promotions: PromotionsSection?

        struct PromotionsSection: Codable {
            let identity: IdentitySection?
            let bitcoinWalletIds: [UUID]
            let ethereumWalletIds: [UUID]

            struct IdentitySection: Codable {
                let credentialIdHex: String
                let enrolledAt: Date
                let wrapProtocolVersion: Int?
            }
        }
    }
}

extension SettingsBackup {

    // MARK: -- capture

    /// Snapshot the current state of every backupable store into a
    /// `SettingsBackup`. Excludes anything secret per the file-
    /// header contract.
    static func capture(from store: HolderStore) -> SettingsBackup {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let btc = SettingsBackup.BitcoinSection(
            fiatCode: store.bitcoinSettings.fiatCode,
            coinGeckoBaseURL: store.bitcoinSettings.coinGeckoBaseURL,
            electrumByNetwork: Dictionary(uniqueKeysWithValues:
                store.bitcoinSettings.electrumByNetwork.map { (k, v) in
                    (k.rawValue, SettingsBackup.BitcoinSection.ElectrumConfig(
                        url: v.url,
                        pinnedCertSHA256: v.pinnedCertSHA256
                    ))
                }
            ),
            mempoolURLByNetwork: Dictionary(uniqueKeysWithValues:
                store.bitcoinSettings.mempoolURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            explorerURLByNetwork: Dictionary(uniqueKeysWithValues:
                store.bitcoinSettings.explorerURLByNetwork.map { ($0.key.rawValue, $0.value) }
            )
        )

        let eth = SettingsBackup.EthereumSection(
            fiatCode: store.ethereumSettings.fiatCode,
            rpcURLByNetwork: Dictionary(uniqueKeysWithValues:
                store.ethereumSettings.rpcURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            explorerURLByNetwork: Dictionary(uniqueKeysWithValues:
                store.ethereumSettings.explorerURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            explorerAPIURLByNetwork: Dictionary(uniqueKeysWithValues:
                store.ethereumSettings.explorerAPIURLByNetwork.map { ($0.key.rawValue, $0.value) }
            ),
            explorerAPIKeyByNetwork: Dictionary(uniqueKeysWithValues:
                store.ethereumSettings.explorerAPIKeyByNetwork.map { ($0.key.rawValue, $0.value) }
            )
        )

        let devs = store.devices.devices.map { d in
            SettingsBackup.DeviceSection(
                id: d.id,
                kind: d.kind.rawValue,
                serial: d.serial,
                label: d.label,
                registeredAt: d.registeredAt,
                promotions: SettingsBackup.DeviceSection.PromotionsSection(
                    identity: d.promotions.identity.map {
                        .init(
                            credentialIdHex: $0.credentialIdHex,
                            enrolledAt: $0.enrolledAt,
                            wrapProtocolVersion: $0.wrapProtocolVersion
                        )
                    },
                    bitcoinWalletIds: d.promotions.bitcoinWalletIds,
                    ethereumWalletIds: d.promotions.ethereumWalletIds
                )
            )
        }

        return SettingsBackup(
            v: SettingsBackup.currentVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            knownIssuers: store.knownIssuers.hosts,
            bitcoin: btc,
            ethereum: eth,
            devices: devs,
            addressBook: store.addressBook.entries
        )
    }

    // MARK: -- apply

    /// Apply this backup to the live stores best-effort. Items the
    /// current build doesn't understand (unknown networks, unknown
    /// device kinds, future-version sections) are recorded in the
    /// returned `SettingsBackupReport` so the UI can show them to
    /// the user instead of pretending the import was complete.
    ///
    /// This call never throws. Version mismatches become advisories
    /// in the report; the apply path still does everything it
    /// recognises.
    @discardableResult
    func apply(to store: HolderStore) -> SettingsBackupReport {
        var report = SettingsBackupReport()
        if v != SettingsBackup.currentVersion {
            let direction = v > SettingsBackup.currentVersion ? "newer" : "older"
            report.versionNote =
                "Backup is schema v\(v); this build is v\(SettingsBackup.currentVersion) (\(direction)). " +
                "Importing what this build understands; anything from the other version is listed below."
        }

        store.knownIssuers.replaceAll(knownIssuers)
        report.imported["knownIssuers"] = knownIssuers.count

        if let btc = bitcoin { applyBitcoin(btc, to: store, report: &report) }
        if let eth = ethereum { applyEthereum(eth, to: store, report: &report) }
        if let devs = devices { applyDevices(devs, to: store, report: &report) }
        if let book = addressBook {
            store.addressBook.replaceAll(book)
            report.imported["addressBook"] = book.count
        }
        return report
    }

    private func applyBitcoin(
        _ section: BitcoinSection,
        to store: HolderStore,
        report: inout SettingsBackupReport
    ) {
        store.bitcoinSettings.fiatCode = section.fiatCode
        store.bitcoinSettings.coinGeckoBaseURL = section.coinGeckoBaseURL
        var electrum = 0
        for (key, cfg) in section.electrumByNetwork {
            guard let net = BitcoinNetwork(rawValue: key) else {
                report.skipped.append("Bitcoin Electrum override for unknown network '\(key)'")
                continue
            }
            store.bitcoinSettings.setElectrum(
                BitcoinSettings.ElectrumConfig(url: cfg.url, pinnedCertSHA256: cfg.pinnedCertSHA256),
                for: net
            )
            electrum += 1
        }
        report.imported["bitcoin.electrum"] = electrum
        var mempool = 0
        for (key, url) in section.mempoolURLByNetwork {
            guard let net = BitcoinNetwork(rawValue: key) else {
                report.skipped.append("Bitcoin mempool override for unknown network '\(key)'")
                continue
            }
            store.bitcoinSettings.setMempool(url, for: net)
            mempool += 1
        }
        report.imported["bitcoin.mempool"] = mempool
        var explorers = 0
        for (key, url) in section.explorerURLByNetwork {
            guard let net = BitcoinNetwork(rawValue: key) else {
                report.skipped.append("Bitcoin explorer override for unknown network '\(key)'")
                continue
            }
            store.bitcoinSettings.setExplorerURL(url, for: net)
            explorers += 1
        }
        report.imported["bitcoin.explorer"] = explorers
    }

    private func applyEthereum(
        _ section: EthereumSection,
        to store: HolderStore,
        report: inout SettingsBackupReport
    ) {
        store.ethereumSettings.fiatCode = section.fiatCode
        var rpc = 0
        for (key, url) in section.rpcURLByNetwork {
            guard let net = EthereumNetwork(rawValue: key) else {
                report.skipped.append("Ethereum RPC URL for unknown network '\(key)'")
                continue
            }
            store.ethereumSettings.setRPC(url, for: net)
            rpc += 1
        }
        report.imported["ethereum.rpc"] = rpc
        var explorer = 0
        for (key, url) in section.explorerURLByNetwork {
            guard let net = EthereumNetwork(rawValue: key) else {
                report.skipped.append("Ethereum explorer URL for unknown network '\(key)'")
                continue
            }
            store.ethereumSettings.setExplorer(url, for: net)
            explorer += 1
        }
        report.imported["ethereum.explorer"] = explorer
        var api = 0
        for (key, url) in section.explorerAPIURLByNetwork {
            guard let net = EthereumNetwork(rawValue: key) else {
                report.skipped.append("Ethereum explorer API URL for unknown network '\(key)'")
                continue
            }
            let apiKey = section.explorerAPIKeyByNetwork[key] ?? ""
            store.ethereumSettings.setExplorerAPI(url, key: apiKey, for: net)
            api += 1
        }
        report.imported["ethereum.explorerAPI"] = api
    }

    private func applyDevices(
        _ devs: [DeviceSection],
        to store: HolderStore,
        report: inout SettingsBackupReport
    ) {
        // Replace the device list wholesale, preserving each device's
        // original UUID and promotions. The user-facing register()
        // path mints fresh UUIDs which would orphan every wallet's
        // `kind = .hardware(deviceId, ...)` reference. Restoration is
        // a privileged op, so reaching into replaceAll() is the right
        // primitive here.
        var rebuilt: [RegisteredDevice] = []
        rebuilt.reserveCapacity(devs.count)
        for d in devs {
            guard let kind = DeviceKind(rawValue: d.kind) else {
                report.skipped.append("Device '\(d.label)' (\(d.serial)) has unknown kind '\(d.kind)'")
                continue
            }
            let promos: RegisteredDevice.Promotions
            if let p = d.promotions {
                let identity = p.identity.map {
                    RegisteredDevice.IdentityPromotion(
                        credentialIdHex: $0.credentialIdHex,
                        enrolledAt: $0.enrolledAt,
                        wrapProtocolVersion: $0.wrapProtocolVersion
                    )
                }
                promos = RegisteredDevice.Promotions(
                    identity: identity,
                    bitcoinWalletIds: p.bitcoinWalletIds,
                    ethereumWalletIds: p.ethereumWalletIds
                )
            } else {
                promos = .empty
            }
            rebuilt.append(RegisteredDevice(
                id: d.id,
                kind: kind,
                serial: d.serial,
                label: d.label,
                registeredAt: d.registeredAt,
                promotions: promos
            ))
        }
        store.devices.replaceAll(rebuilt)
        report.imported["devices"] = rebuilt.count
    }
}

/// Outcome of a best-effort `SettingsBackup.apply(to:)`. `imported`
/// counts what we applied by section; `skipped` is a list of
/// human-readable items the current build couldn't reconstitute
/// (unknown networks, unknown device kinds, fields from a newer
/// schema version, etc). `versionNote` is set when the file's
/// schema version doesn't match the build's current version.
struct SettingsBackupReport {
    var imported: [String: Int] = [:]
    var skipped: [String] = []
    var versionNote: String?

    var hasGaps: Bool { !skipped.isEmpty || versionNote != nil }
    var totalImported: Int { imported.values.reduce(0, +) }

    /// Multi-line human-readable summary, suitable for a SwiftUI
    /// alert body or a small report sheet.
    var summary: String {
        var lines: [String] = []
        if let versionNote { lines.append(versionNote) }
        let totals = imported.filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        if !totals.isEmpty {
            lines.append("Imported \(totalImported) item\(totalImported == 1 ? "" : "s") (\(totals)).")
        }
        if !skipped.isEmpty {
            lines.append("")
            lines.append("Not imported:")
            for s in skipped { lines.append("  • \(s)") }
        }
        return lines.joined(separator: "\n")
    }
}
