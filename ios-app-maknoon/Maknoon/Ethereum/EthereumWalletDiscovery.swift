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
        var id: String { "\(network.rawValue):\(account)" }
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
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> [DiscoveredAccount] {

        // Derive every candidate address up front. For software
        // this is fast and runs under a single biometric prompt;
        // for hardware it's a sequence of BLE round trips.
        var addresses: [(UInt32, String)] = []
        addresses.reserveCapacity(Int(maxAccount))
        switch source {
        case .software(let sandwich):
            // The first call into addressFromSandwich loads the
            // seed under biometric; subsequent calls would prompt
            // again on every call. Instead, we read the seed once
            // and derive all accounts in a tight loop.
            let material = try sandwich.recoveryMaterial(
                localizedReason: "Discover Ethereum wallets on this seed"
            )
            let words = material.words.joined(separator: " ")
            let pass = material.hasPassphrase ? material.passphrase : ""
            guard let hd = WalletCore.HDWallet(mnemonic: words, passphrase: pass) else {
                throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
            }
            for account in 0..<maxAccount {
                let key = hd.getDerivedKey(coin: .ethereum, account: account, change: 0, address: 0)
                let addr = WalletCore.CoinType.ethereum.deriveAddress(privateKey: key)
                addresses.append((account, addr))
            }
        case .hardware(let client):
            // Pin the BLE session across the whole derivation loop.
            // Without this, every getEthereumAddress() call hits the
            // trailing `defer { resetSession() }` inside LedgerBLE,
            // tearing the GATT link down and forcing a fresh scan +
            // reconnect on every account. After a few rounds the
            // Nano X stops advertising and the scan silently returns
            // zero accounts. Bitcoin's discover (DiscoverHardwareWalletsView)
            // wraps the loop the same way.
            client.beginSession()
            defer { client.endSession() }
            for account in 0..<maxAccount {
                let addr = try await client.getEthereumAddress(account: account)
                addresses.append((account, addr))
            }
        }

        // Per-account activity probe. Run sequentially (Etherscan
        // free tier rate-limits parallel calls aggressively).
        var hits: [DiscoveredAccount] = []
        for (account, address) in addresses {
            onProgress(Progress(network: network, account: account, phase: .scanning))
            do {
                let (hasBalance, txCount) = try await EthereumWallet.probeActivity(
                    address: address,
                    rpcURL: rpcURL,
                    explorerAPIURL: explorerAPIURL,
                    apiKey: apiKey,
                    chainId: network.chainId
                )
                let entry = DiscoveredAccount(
                    network: network,
                    account: account,
                    address: address,
                    hasBalance: hasBalance,
                    txCount: txCount
                )
                if entry.hasActivity { hits.append(entry) }
                onProgress(Progress(network: network, account: account, phase: .completed(active: entry.hasActivity)))
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                onProgress(Progress(network: network, account: account, phase: .failed(msg)))
            }
        }
        return hits
    }
}
