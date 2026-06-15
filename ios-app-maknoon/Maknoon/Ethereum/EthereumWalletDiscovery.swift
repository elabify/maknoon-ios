// Walks BIP44 account indices on either the holder's seed
// (software) or a hardware device, hits Etherscan + RPC for each
// derived address to see if it has on-chain activity, returns the
// hits so the UI can let the user pre-add the ones it cares about.
//
// Mirrors `BitcoinWalletDiscovery` in spirit. The two key
// differences from Bitcoin:
//
//   * Ethereum addresses are chain-agnostic: the same private key
//     produces the same EIP-55 address on every EVM chain. We
//     therefore probe one chain at a time (the user picks); a
//     future enhancement could fan out across every configured
//     network in parallel.
//   * Hardware derivation is fast (~1 RTT per account, no on-
//     device confirmation needed for GET_PUBLIC_KEY with display
//     flag = 0), so the sweep doesn't need to be staged.

import Foundation
import WalletCore

enum EthereumWalletDiscovery {

    struct DiscoveredAccount: Sendable, Hashable, Identifiable {
        let network: EthereumNetwork
        let account: UInt32
        let address: String
        let hasBalance: Bool
        let txCount: Int
        /// The non-standard path this was derived at, when the sweep was
        /// trying alternatives; nil for the chain's standard path.
        var derivationPath: String?
        var id: String { "\(network.rawValue):\(account):\(derivationPath ?? "std")" }
        /// Heuristic: any signal of activity = "yes, ever used."
        var hasActivity: Bool { hasBalance || txCount > 0 }
    }

    struct Progress: Sendable {
        let network: EthereumNetwork
        let account: UInt32
        let phase: Phase
        enum Phase: Sendable {
            case scanning
            case completed(active: Bool)
            case failed(String)
        }
    }

    enum Source {
        /// Software: derive each candidate via the sandwich seed.
        /// Reads the seed exactly once across the whole sweep.
        case software(sandwich: IdentitySandwich)
        /// Hardware: ask the device for each address. The caller
        /// guarantees the device is connected + on the Ethereum
        /// app.
        case hardware(client: HardwareWallet)
    }

    /// Sweep account indices `0..<maxAccount` on `network`. Returns
    /// only the accounts where `hasActivity` is true. `onProgress`
    /// is fired on the calling actor (typically @MainActor) once
    /// per account.
    @MainActor
    static func scan(
        source: Source,
        network: EthereumNetwork,
        rpcURL: String,
        explorerAPIURL: String?,
        apiKey: String?,
        maxAccount: UInt32 = 5,
        includeFirstAccountAlways: Bool = false,
        pathTemplates: [String]? = nil,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> [DiscoveredAccount] {

        // Derive every candidate up front: one per account on the
        // standard path, or one per (account, template) when sweeping
        // alternative paths. For software this runs under a single
        // biometric prompt; for hardware it's a sequence of BLE trips.
        var candidates: [(account: UInt32, address: String, path: String?)] = []
        // Dedup resolved paths: some templates fill to the SAME path at a
        // given account (e.g. ETH's Ledger-Live and MEW variants both
        // give m/44'/60'/0'/0/0 at account 0), so we never derive or show
        // the same path twice.
        var seenPaths = Set<String>()
        switch source {
        case .software(let sandwich):
            let material = try sandwich.recoveryMaterial(
                localizedReason: "Discover Ethereum wallets on this seed"
            )
            let words = material.words.joined(separator: " ")
            let pass = material.hasPassphrase ? material.passphrase : ""
            guard let hd = WalletCore.HDWallet(mnemonic: words, passphrase: pass) else {
                throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
            }
            for account in 0..<maxAccount {
                if let templates = pathTemplates {
                    for tmpl in templates {
                        let path = BIP32Path.fill(tmpl, account: account)
                        guard seenPaths.insert(path).inserted else { continue }
                        let key = hd.getKeyByCurve(curve: .secp256k1, derivationPath: path)
                        let addr = WalletCore.CoinType.ethereum.deriveAddress(privateKey: key)
                        candidates.append((account, addr, path))
                    }
                } else {
                    let key = hd.getDerivedKey(coin: .ethereum, account: account, change: 0, address: 0)
                    let addr = WalletCore.CoinType.ethereum.deriveAddress(privateKey: key)
                    candidates.append((account, addr, nil))
                }
            }
        case .hardware(let client):
            // Pin the BLE session across the whole derivation loop so
            // the back-to-back derivations share one connection.
            client.beginSession()
            defer {
                client.setDerivationPathOverride(nil)
                client.endSession()
            }
            for account in 0..<maxAccount {
                if let templates = pathTemplates {
                    for tmpl in templates {
                        let path = BIP32Path.fill(tmpl, account: account)
                        guard seenPaths.insert(path).inserted else { continue }
                        client.setDerivationPathOverride(path)
                        // A device may forbid a foreign path (Trezor
                        // rejects non-standard ETH paths). Skip that
                        // template rather than aborting the whole sweep.
                        do {
                            let addr = try await client.getEthereumAddress(account: account)
                            candidates.append((account, addr, path))
                        } catch {
                            continue
                        }
                    }
                } else {
                    client.setDerivationPathOverride(nil)
                    let addr = try await client.getEthereumAddress(account: account)
                    candidates.append((account, addr, nil))
                }
            }
        }

        // Per-candidate activity probe. Run sequentially (Etherscan
        // free tier rate-limits parallel calls aggressively).
        var hits: [DiscoveredAccount] = []
        // A discovered wallet IS its address: alternative templates can
        // collide on a path (or a device may ignore the override), so
        // dedup by address (case-insensitive) for one row per wallet.
        var seenAddresses = Set<String>()
        // For hidden (passphrase) wallets the whole point is a fresh,
        // empty wallet, so activity probing would surface nothing.
        // When `includeFirstAccountAlways` is set we keep account 0's
        // first candidate even with zero activity so it can still be added.
        var firstAccountEntry: DiscoveredAccount?
        for cand in candidates {
            onProgress(Progress(network: network, account: cand.account, phase: .scanning))
            do {
                let (hasBalance, txCount) = try await EthereumWallet.probeActivity(
                    address: cand.address,
                    rpcURL: rpcURL,
                    explorerAPIURL: explorerAPIURL,
                    apiKey: apiKey,
                    chainId: network.chainId
                )
                let entry = DiscoveredAccount(
                    network: network,
                    account: cand.account,
                    address: cand.address,
                    hasBalance: hasBalance,
                    txCount: txCount,
                    derivationPath: cand.path
                )
                if cand.account == 0, firstAccountEntry == nil { firstAccountEntry = entry }
                if entry.hasActivity, seenAddresses.insert(cand.address.lowercased()).inserted {
                    hits.append(entry)
                }
                onProgress(Progress(network: network, account: cand.account, phase: .completed(active: entry.hasActivity)))
            } catch {
                if cand.account == 0, firstAccountEntry == nil {
                    firstAccountEntry = DiscoveredAccount(
                        network: network, account: cand.account, address: cand.address,
                        hasBalance: false, txCount: 0, derivationPath: cand.path
                    )
                }
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                onProgress(Progress(network: network, account: cand.account, phase: .failed(msg)))
            }
        }
        if includeFirstAccountAlways,
           let first = firstAccountEntry,
           !hits.contains(where: { $0.account == 0 }) {
            hits.insert(first, at: 0)
        }
        return hits
    }
}
