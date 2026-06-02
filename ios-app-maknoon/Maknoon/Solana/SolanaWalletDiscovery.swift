// Walk BIP44 Solana account indices on the holder's seed, probe each
// derived address for on-chain activity, return the hits so the UI
// can let the user pre-add the ones it cares about.
//
// Mirrors `BitcoinWalletDiscovery` + `EthereumWalletDiscovery` in
// spirit. Solana-specific differences:
//
//   * The derivation path is `m/44'/501'/<account>'/0'` and each
//     account's primary key IS the address; we don't walk a chain of
//     receive/change addresses inside an account the way Bitcoin
//     does.
//   * Solana addresses are cluster-agnostic at the keypair level,
//     but on-chain activity is per-cluster, so the scan is parameter-
//     ised by cluster.
//   * Activity heuristic: either a non-zero lamport balance, or at
//     least one signature. Either signal counts as "this account
//     has been used."

import Foundation
import WalletCore

enum SolanaWalletDiscovery {

    struct DiscoveredAccount: Sendable, Hashable, Identifiable {
        let network: SolanaNetwork
        let account: UInt32
        let address: String
        let lamports: UInt64
        let signatureCount: Int
        var id: String { "\(network.rawValue):\(account)" }
        /// Any signal of activity counts as "used."
        var hasActivity: Bool { lamports > 0 || signatureCount > 0 }
    }

    struct Progress: Sendable {
        let account: UInt32
        let phase: Phase
        enum Phase: Sendable {
            case scanning
            case completed(active: Bool, lamports: UInt64)
            case failed(String)
        }
    }

    /// BIP44-style gap-limit at the ACCOUNT level. Same value as the
    /// Bitcoin hardware-discover sweep so users see consistent
    /// behaviour across chains.
    static let emptyAccountGapLimit = 4

    /// Software vs hardware derivation. Software reads the sandwich
    /// seed once and walks it host-side; hardware asks the device
    /// once per account index.
    enum Source {
        case software(sandwich: IdentitySandwich)
        case hardware(client: HardwareWallet)
    }

    /// Walk accounts 0, 1, 2, ... until `emptyAccountGapLimit`
    /// consecutive empty accounts are encountered, then stop.
    /// Returns the hits with `hasActivity == true`.
    @MainActor
    static func scan(
        source: Source,
        network: SolanaNetwork,
        rpcURL: String,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> [DiscoveredAccount] {

        guard let url = URL(string: rpcURL) else {
            throw SolanaRPCError.badURL(rpcURL)
        }
        let rpc = SolanaRPCClient(endpoint: url)

        // Software derivation reads the seed once under a single
        // biometric prompt; hardware derivation pins the BLE
        // session across the whole sweep.
        var hdWallet: WalletCore.HDWallet?
        if case .software(let sandwich) = source {
            let material = try sandwich.recoveryMaterial(
                localizedReason: "Discover Solana wallets on this seed"
            )
            let words = material.words.joined(separator: " ")
            let pass = material.hasPassphrase ? material.passphrase : ""
            guard let hd = WalletCore.HDWallet(mnemonic: words, passphrase: pass) else {
                throw SolanaDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
            }
            hdWallet = hd
        }
        if case .hardware(let client) = source {
            client.beginSession()
        }
        defer {
            if case .hardware(let client) = source {
                client.endSession()
            }
        }

        var hits: [DiscoveredAccount] = []
        var account: UInt32 = 0
        var consecutiveEmpty = 0
        while consecutiveEmpty < emptyAccountGapLimit {
            onProgress(Progress(account: account, phase: .scanning))
            let address: String
            switch source {
            case .software:
                let path = SolanaDescriptors.derivationPath(account: account)
                let priv = hdWallet!.getKeyByCurve(curve: .ed25519, derivationPath: path)
                address = WalletCore.CoinType.solana.deriveAddress(privateKey: priv)
            case .hardware(let client):
                address = try await client.getSolanaAddress(account: account)
            }

            do {
                let lamports = (try? await rpc.getBalance(address: address)) ?? 0
                // limit:1 is enough to detect "any activity ever";
                // we don't need the full signature list at this
                // stage.
                let sigs = (try? await rpc.getSignaturesForAddress(address, limit: 1)) ?? []
                let entry = DiscoveredAccount(
                    network: network,
                    account: account,
                    address: address,
                    lamports: lamports,
                    signatureCount: sigs.count
                )
                if entry.hasActivity {
                    hits.append(entry)
                    consecutiveEmpty = 0
                } else {
                    consecutiveEmpty += 1
                }
                onProgress(Progress(
                    account: account,
                    phase: .completed(active: entry.hasActivity, lamports: lamports)
                ))
            } catch {
                // A transient RPC error shouldn't kill the sweep;
                // count it as "empty" for gap purposes but surface
                // the message so the user can retry against a
                // different endpoint if they suspect rate-limiting.
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                consecutiveEmpty += 1
                onProgress(Progress(account: account, phase: .failed(msg)))
            }
            account += 1
        }
        return hits
    }
}
