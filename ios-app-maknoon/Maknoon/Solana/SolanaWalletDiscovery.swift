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
        /// Non-standard path this was derived at, when sweeping
        /// alternatives; nil for the standard path.
        var derivationPath: String?
        var id: String { "\(network.rawValue):\(account):\(derivationPath ?? "std")" }
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
        includeFirstAccountAlways: Bool = false,
        pathTemplates: [String]? = nil,
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

        // Either the standard path only (nil marker) or each alternative
        // template per account. The account-level gap limit treats an
        // account as empty only when NO template had activity.
        let templateList: [String?] = pathTemplates?.map { Optional($0) } ?? [nil]

        var hits: [DiscoveredAccount] = []
        // A discovered wallet IS its address: different alternative
        // templates can resolve to the same path (e.g. Ledger-Live's and
        // the 4th-level variant collide at account 0) or, on devices that
        // ignore the path, the same address. Dedup so each address yields
        // exactly one selectable row.
        var seenAddresses = Set<String>()
        // Dedup resolved paths so two templates that fill to the same
        // path at an account aren't derived or shown twice.
        var seenPaths = Set<String>()
        // For a fresh hidden wallet there is no activity to find, so we
        // keep account 0's first candidate even when empty (see runScan).
        var firstAccountEntry: DiscoveredAccount?
        var account: UInt32 = 0
        var consecutiveEmpty = 0
        while consecutiveEmpty < emptyAccountGapLimit {
            onProgress(Progress(account: account, phase: .scanning))
            var accountHadActivity = false
            for tmpl in templateList {
                let path = tmpl.map { BIP32Path.fill($0, account: account) }
                guard seenPaths.insert(path ?? "std").inserted else { continue }
                let address: String
                do {
                    switch source {
                    case .software:
                        let derivePath = path ?? SolanaDescriptors.derivationPath(account: account)
                        let priv = hdWallet!.getKeyByCurve(curve: .ed25519, derivationPath: derivePath)
                        address = WalletCore.CoinType.solana.deriveAddress(privateKey: priv)
                    case .hardware(let client):
                        client.setDerivationPathOverride(path)
                        address = try await client.getSolanaAddress(account: account)
                    }
                } catch {
                    // A device may forbid a foreign path; skip it.
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    onProgress(Progress(account: account, phase: .failed(msg)))
                    continue
                }

                do {
                    let lamports = (try? await rpc.getBalance(address: address)) ?? 0
                    let sigs = (try? await rpc.getSignaturesForAddress(address, limit: 1)) ?? []
                    let entry = DiscoveredAccount(
                        network: network,
                        account: account,
                        address: address,
                        lamports: lamports,
                        signatureCount: sigs.count,
                        derivationPath: path
                    )
                    if account == 0, firstAccountEntry == nil { firstAccountEntry = entry }
                    if entry.hasActivity {
                        accountHadActivity = true
                        if seenAddresses.insert(address).inserted {
                            hits.append(entry)
                        }
                    }
                    onProgress(Progress(
                        account: account,
                        phase: .completed(active: entry.hasActivity, lamports: lamports)
                    ))
                } catch {
                    // A transient RPC error shouldn't kill the sweep.
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    onProgress(Progress(account: account, phase: .failed(msg)))
                }
            }
            if case .hardware(let client) = source { client.setDerivationPathOverride(nil) }
            if accountHadActivity { consecutiveEmpty = 0 } else { consecutiveEmpty += 1 }
            account += 1
        }
        if includeFirstAccountAlways,
           let first = firstAccountEntry,
           !hits.contains(where: { $0.account == 0 }) {
            hits.insert(first, at: 0)
        }
        return hits
    }
}
