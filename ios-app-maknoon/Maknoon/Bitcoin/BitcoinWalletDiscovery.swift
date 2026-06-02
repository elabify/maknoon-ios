// Scan the user's seed for existing Bitcoin activity. Walks account
// indices 0..maxAccount, builds an in-memory BDK wallet for each
// (network, account), runs a full Electrum scan, and reports back
// every account that had at least one transaction.
//
// On-demand only. Driven by a button in BitcoinWalletsView. Each
// account-scan is a full Electrum scan and can take 5-30 seconds,
// so we surface per-account progress to the UI.

import Foundation
import BitcoinDevKit

enum BitcoinWalletDiscovery {

    struct DiscoveredAccount: Sendable {
        let network: BitcoinNetwork
        let account: UInt32
        let txCount: Int
        let balanceSat: UInt64
    }

    /// Per-account progress callback. The caller (UI) renders the
    /// current step so a 5+ minute scan does not feel frozen.
    struct Progress: Sendable {
        let network: BitcoinNetwork
        let account: UInt32
        let phase: Phase
        enum Phase: Sendable { case scanning, completed(txCount: Int) }
    }

    /// Walk accounts 0...maxAccount on each requested network. Returns
    /// the discovered accounts in scan order; the caller decides which
    /// to add to BitcoinWalletStore. The scan stops at maxAccount; if
    /// you need deeper discovery, raise the upper bound and call again.
    ///
    /// The caller passes the BIP39 mnemonic words + optional
    /// passphrase as plain Sendable strings so the scan can run off
    /// the main actor without dragging the non-Sendable
    /// `IdentitySandwich` reference across actor boundaries. The
    /// caller is expected to unlock the sandwich on the main actor,
    /// pull `recoveryMaterial()`, and hand the strings here.
    static func scan(
        mnemonicWords: String,
        passphrase: String?,
        networks: [BitcoinNetwork],
        maxAccount: UInt32 = 4,
        electrumURL: @Sendable (BitcoinNetwork) -> String,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [DiscoveredAccount] {
        var discovered: [DiscoveredAccount] = []

        let mnemonic = try Mnemonic.fromString(mnemonic: mnemonicWords)
        let password: String? = passphrase.flatMap { $0.isEmpty ? nil : $0 }

        for network in networks {
            let root = DescriptorSecretKey(
                network: network.bdk,
                mnemonic: mnemonic,
                password: password
            )
            for account in 0...maxAccount {
                onProgress?(Progress(network: network, account: account, phase: .scanning))

                let secret: DescriptorSecretKey
                if account == 0 {
                    secret = root
                } else {
                    let path = try DerivationPath(path: "m/84'/\(network.coinType)'/\(account)'")
                    secret = try root.derive(path: path)
                }
                let external = Descriptor.newBip84(
                    secretKey: secret,
                    keychainKind: .external,
                    network: network.bdk
                )
                let `internal` = Descriptor.newBip84(
                    secretKey: secret,
                    keychainKind: .internal,
                    network: network.bdk
                )
                let persister = try Persister.newInMemory()
                let wallet = try Wallet(
                    descriptor: external,
                    changeDescriptor: `internal`,
                    network: network.bdk,
                    persister: persister
                )

                do {
                    let client = try ElectrumClient(url: electrumURL(network), socks5: nil)
                    let req = try wallet.startFullScan().build()
                    let update = try client.fullScan(
                        request: req,
                        stopGap: 20,
                        batchSize: 10,
                        fetchPrevTxouts: false
                    )
                    try wallet.applyUpdate(update: update)
                } catch {
                    // Treat a per-account network failure as "no
                    // activity" so a single bad endpoint cannot poison
                    // the whole discovery run.
                    onProgress?(Progress(network: network, account: account, phase: .completed(txCount: 0)))
                    continue
                }

                let txCount = wallet.transactions().count
                let balanceSat = wallet.balance().total.toSat()
                onProgress?(Progress(network: network, account: account, phase: .completed(txCount: txCount)))

                if txCount > 0 {
                    discovered.append(DiscoveredAccount(
                        network: network,
                        account: account,
                        txCount: txCount,
                        balanceSat: balanceSat
                    ))
                }
            }
        }

        return discovered
    }
}
