// Actor-isolated facade over a single BDK `Wallet`. Holds the
// SQLite-backed Persister, the ElectrumClient bound to the wallet's
// network, and exposes the small set of operations our SwiftUI views
// need: balance, transactions, addresses, sync, send.
//
// Construction is async because we may need to unlock the Identity
// Sandwich (Face ID gate) to derive the descriptor for a fresh
// software wallet.

import Foundation
import BitcoinDevKit

actor BitcoinWallet {

    enum WalletError: LocalizedError {
        case sandwichRequired
        case descriptorFailed(String)
        case syncFailed(String)
        case sendFailed(String)
        case hardwareSigningNotImplemented
        case bleSigningNotYetImplemented
        var errorDescription: String? {
            switch self {
            case .sandwichRequired:                  return "Identity Sandwich is locked"
            case .descriptorFailed(let m):           return "Descriptor: \(m)"
            case .syncFailed(let m):                 return "Sync failed: \(m)"
            case .sendFailed(let m):                 return "Send failed: \(m)"
            case .bleSigningNotYetImplemented:
                return """
                Bluetooth signing on Ledger / Trezor is not wired up yet (Ledger SIGN_PSBT v2 / Trezor SignTx). Use the "Or sign offline (PSBT QR)" button below to export the unsigned PSBT and sign it on the device through Ledger Live / Trezor Suite / Sparrow / Specter, then paste the signed PSBT back in to broadcast.
                """
            case .hardwareSigningNotImplemented:
                return """
                This wallet is hardware-backed, and live on-device signing for this device kind is not implemented yet. Use the offline-PSBT path: tap "Generate PSBT for offline signing", scan or transfer the unsigned PSBT to the device, sign there, then paste the signed PSBT back into Maknoon to broadcast.
                """
            }
        }
    }

    /// Returned from `open(...)` so the caller can decide how to
    /// surface a local-cache rebuild event. The wallet is usable in
    /// either case; `rebuilt == true` means the local SQLite was
    /// unreadable (after an app rename, BDK schema change, partial
    /// write, etc.) and we wiped it. The caller MUST clear
    /// `lastSyncAt` so the next refresh does a full scan, otherwise
    /// the user sees a zero balance with no transactions.
    struct OpenResult: Sendable {
        let wallet: BitcoinWallet
        let rebuilt: Bool
        let rebuildReason: String?
        /// If non-nil, the caller should persist this back into the
        /// wallet store because we populated the public-key cache
        /// during this open (legacy migration path).
        let updatedDescriptor: BitcoinWalletDescriptor?
    }

    let descriptor: BitcoinWalletDescriptor
    private let inner: Wallet
    private let persister: Persister

    /// Build (or load if the persisted SQLite already exists) a
    /// BitcoinWallet for the given descriptor. For software wallets we
    /// also need the sandwich so the BDK signer can sign PSBTs without
    /// a hardware device round-trip. Electrum URLs flow in at call
    /// time from `BitcoinSettings` on the main actor; the actor
    /// itself stays Sendable.
    /// Convenience that returns just the wallet, for callers that
    /// don't need to distinguish a self-heal event.
    static func open(
        descriptor: BitcoinWalletDescriptor,
        sandwich: IdentitySandwich?
    ) throws -> BitcoinWallet {
        return try openWithResult(descriptor: descriptor, sandwich: sandwich).wallet
    }

    static func openWithResult(
        descriptor: BitcoinWalletDescriptor,
        sandwich: IdentitySandwich?
    ) throws -> OpenResult {
        let descriptorPair: BitcoinDescriptorPair
        // Updated descriptor that the caller should persist back into
        // the wallet store if we had to populate the public-key
        // cache during this open. Nil when nothing changed.
        var maybeUpdatedDescriptor: BitcoinWalletDescriptor? = nil

        switch descriptor.kind {
        case .software(let account):
            // Public-key cache populated? Build a watch-only
            // descriptor with NO seed access and therefore no
            // biometric prompt. This is the steady-state path.
            if let fingerprint = descriptor.cachedAccountFingerprint,
               let xpub = descriptor.cachedAccountXpub,
               !fingerprint.isEmpty, !xpub.isEmpty
            {
                descriptorPair = try BitcoinDescriptors.watchOnlyFromCachedKey(
                    accountFingerprint: fingerprint,
                    accountXpub: xpub,
                    network: descriptor.network
                )
            } else {
                // Legacy wallet (created before the cache existed)
                // or freshly-created wallet whose AddBitcoinWalletSheet
                // skipped the pre-derive step. Read the seed once
                // here, then return the cacheable values to the
                // caller via OpenResult.
                guard let sandwich else { throw WalletError.sandwichRequired }
                let derived = try BitcoinDescriptors.deriveFromSeed(
                    sandwich: sandwich,
                    account: account,
                    network: descriptor.network,
                    biometricReason: "Set up your Bitcoin wallet"
                )
                descriptorPair = derived.pair
                var updated = descriptor
                updated.cachedAccountFingerprint = derived.accountFingerprint
                updated.cachedAccountXpub = derived.accountXpub
                maybeUpdatedDescriptor = updated
            }
        case .hardware(_, let fingerprint, let xpub):
            descriptorPair = try BitcoinDescriptors.watchOnlyFromXpub(
                xpub: xpub,
                fingerprint: fingerprint,
                network: descriptor.network
            )
        }

        // Ensure the per-wallet directory exists before BDK tries to
        // open the SQLite file. The previous version used try? and
        // swallowed creation errors, which led to BDK reporting an
        // opaque "open failed because wallet.sqlite database file"
        // when the directory wasn't there yet.
        try descriptor.ensureDatabaseDirectoryExists()
        let dbURL = descriptor.databaseFileURL
        let dbPath = dbURL.path
        let fileAlreadyExists = FileManager.default.fileExists(atPath: dbPath)
        var persister = try Persister.newSqlite(path: dbPath)

        // If the SQLite file existed before this call, BDK's
        // descriptor record should already be inside it; use `load`.
        // Otherwise the persister is fresh and we go through `init`
        // to write the descriptor records for the first time.
        let bdkWallet: Wallet
        var rebuilt = false
        var rebuildReason: String? = nil
        if fileAlreadyExists {
            do {
                bdkWallet = try Wallet.load(
                    descriptor: descriptorPair.external,
                    changeDescriptor: descriptorPair.internal,
                    persister: persister
                )
            } catch {
                // Stale or partial DB. This shows up after:
                //   - BDK version bumps that change the on-disk
                //     schema.
                //   - The previous build of Maknoon crashing before
                //     it persisted post-applyUpdate state.
                //   - Hand-edited or partially-restored Documents.
                //
                // We wipe and re-init so the wallet is usable, then
                // signal `rebuilt = true` so the caller forces a
                // full scan on the next refresh AND surfaces a banner
                // explaining that local cache was rebuilt (so the
                // user does not think we drained their funds).
                rebuilt = true
                rebuildReason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                NSLog("[Maknoon] BitcoinWallet.load failed for \(descriptor.label) (\(descriptor.network.displayName)); wiping local SQLite and rebuilding from descriptor. reason=\(rebuildReason ?? "unknown")")
                try? FileManager.default.removeItem(at: dbURL)
                persister = try Persister.newSqlite(path: dbPath)
                bdkWallet = try Wallet(
                    descriptor: descriptorPair.external,
                    changeDescriptor: descriptorPair.internal,
                    network: descriptor.network.bdk,
                    persister: persister
                )
            }
        } else {
            bdkWallet = try Wallet(
                descriptor: descriptorPair.external,
                changeDescriptor: descriptorPair.internal,
                network: descriptor.network.bdk,
                persister: persister
            )
        }

        // Ensure the descriptor records BDK just wrote into the
        // freshly-built wallet actually hit disk before we hand the
        // actor back to the caller. Without this, a process exit
        // before the first sync would leave an empty SQLite that
        // load() then rejects on next launch.
        _ = try bdkWallet.persist(persister: persister)

        let actor = BitcoinWallet(
            descriptor: maybeUpdatedDescriptor ?? descriptor,
            inner: bdkWallet,
            persister: persister
        )
        return OpenResult(
            wallet: actor,
            rebuilt: rebuilt,
            rebuildReason: rebuildReason,
            updatedDescriptor: maybeUpdatedDescriptor
        )
    }

    private init(
        descriptor: BitcoinWalletDescriptor,
        inner: Wallet,
        persister: Persister
    ) {
        self.descriptor = descriptor
        self.inner = inner
        self.persister = persister
    }

    // MARK: -- read-only accessors

    func balance() -> Balance { inner.balance() }

    /// Transactions, newest first.
    func transactions() -> [CanonicalTx] {
        let txs = inner.transactions()
        return txs.sorted { lhs, rhs in
            timestamp(of: lhs) > timestamp(of: rhs)
        }
    }

    func nextReceiveAddress() throws -> AddressInfo {
        let info = inner.revealNextAddress(keychain: .external)
        // Reveal advances the keychain's next-index state; persist so
        // the user does not see the same address re-revealed after a
        // reload.
        _ = try inner.persist(persister: persister)
        return info
    }

    /// Next receive address that BDK has not yet seen any history
    /// against, per the latest sync. Does NOT advance the keychain,
    /// so it's safe to call on every wallet refresh (e.g. to keep
    /// the address-book mirror fresh). If every revealed address
    /// has activity, BDK still returns a valid address (the next
    /// unrevealed one).
    func nextUnusedReceiveAddress() -> AddressInfo {
        inner.nextUnusedAddress(keychain: .external)
    }

    /// Walk the first `count` revealed addresses on a keychain.
    func revealedAddresses(keychain: KeychainKind, upTo count: UInt32) -> [AddressInfo] {
        return (0..<count).map { idx in
            inner.peekAddress(keychain: keychain, index: idx)
        }
    }

    func listUnspent() -> [LocalOutput] { inner.listUnspent() }

    /// Build an unsigned replacement PSBT for an existing
    /// unconfirmed, RBF-eligible transaction at a higher fee rate.
    /// Wraps BDK's `BumpFeeTxBuilder(txid:feeRate:).finish(wallet:)`.
    /// Returns the base64-encoded PSBT ready to route through the
    /// app's regular sign + broadcast pipeline. Caller is
    /// responsible for ensuring the original tx is unconfirmed,
    /// outgoing, and replaceable; BDK will surface a clear error
    /// (`InsufficientFunds`, `IrreplaceableTransaction`, etc.) if
    /// not.
    func buildBumpFeePSBT(
        originalTxidHex: String,
        newFeeRateSatsPerVb: UInt64
    ) throws -> String {
        let txid = try Txid.fromString(hex: originalTxidHex)
        let feeRate = try FeeRate.fromSatPerVb(satVb: newFeeRateSatsPerVb)
        let builder = BumpFeeTxBuilder(txid: txid, feeRate: feeRate)
        let psbt = try builder.finish(wallet: inner)
        // Persist so any change-address reveal that BumpFee may
        // have triggered (rare; usually it reuses the original
        // change output) sticks across app relaunches.
        _ = try inner.persist(persister: persister)
        return psbt.serialize()
    }

    /// Net wallet delta for a transaction: `received - sent`, in
    /// satoshis. Positive means money flowed INTO the wallet
    /// (receive), negative means OUT (send including fees).
    /// Used by the tx list to replace the placeholder em-dash
    /// with a real signed amount.
    func netAmount(tx: Transaction) -> Int64 {
        let values = inner.sentAndReceived(tx: tx)
        // BDK exposes Amount values; `toSat()` is the canonical
        // accessor. Cast to Int64 so we can return a SIGNED delta
        // without underflow risk on big-send cases.
        let received = Int64(values.received.toSat())
        let sent = Int64(values.sent.toSat())
        return received - sent
    }

    /// All wallet outputs, including spent ones. Used by the Addresses
    /// view to compute total-received per derivation index.
    func listOutput() -> [LocalOutput] { inner.listOutput() }

    // MARK: -- sync

    /// Run a full keychain scan against the given Electrum endpoint.
    /// Walks receive (chain 0) and change (chain 1) derivations until
    /// `stopGap` consecutive empty addresses are observed, the
    /// BIP-44 standard discovery rule.
    ///
    /// Use on first sync or after importing a new descriptor. For
    /// subsequent refreshes call `sync(electrumURL:)`, which is the
    /// same scan with the cached BDK keychain state already populated.
    func fullScan(electrumURL: String) throws {
        let client = try ElectrumClient(url: electrumURL, socks5: nil)
        let request = try inner.startFullScan().build()
        let update = try client.fullScan(
            request: request,
            stopGap: 20,
            batchSize: 10,
            fetchPrevTxouts: true
        )
        try inner.applyUpdate(update: update)
        // applyUpdate only STAGES; write to SQLite so a tab-switch or
        // app relaunch finds the same data on reopen.
        _ = try inner.persist(persister: persister)
    }

    /// Re-scan the keychain against the given Electrum endpoint.
    ///
    /// Implemented as the same full-keychain scan as `fullScan`,
    /// NOT as a revealed-spk-only sync. Previously this used
    /// `startSyncWithRevealedSpks()`, which only checked addresses
    /// the user had explicitly revealed via the Receive tab. That
    /// missed any UTXOs at indices the descriptor could generate
    /// but the user had not visited, e.g. after restoring from a
    /// backup or importing an old xpub.
    ///
    /// BDK + Electrum cache the wire responses for known-empty
    /// script hashes, so re-running a full scan against an already-
    /// synced wallet is roughly the same cost as the old "revealed
    /// only" sync; the gap-limit walk hits cached negatives. Worst-
    /// case bound is O(highest_derived + 20) script hashes per
    /// refresh.
    func sync(electrumURL: String) throws {
        try fullScan(electrumURL: electrumURL)
    }

    /// Persist any currently-staged changes. Cheap no-op when nothing
    /// has been staged. Called from the views after operations that
    /// mutate wallet state outside of sync (e.g. revealing a new
    /// receive address).
    func persistStaged() throws {
        _ = try inner.persist(persister: persister)
    }

    // MARK: -- offline PSBT (universal hardware-wallet path)
    //
    // Hardware wallets ship with their own signing UX (Sparrow,
    // Trezor Suite, Ledger Live with PSBT import, Specter, etc.).
    // Maknoon supports them all via the standard BIP174 PSBT flow:
    //
    //   buildUnsignedPSBT(...)  -> base64 string
    //       (user signs externally on whichever device they trust)
    //   importSignedPSBT(...)   -> finalize + broadcast
    //
    // Works for hardware-backed wallets (where Maknoon never holds
    // the private key) AND for software wallets when the user wants
    // to sign on a different machine, e.g. an air-gapped signer.

    /// Ask BDK what the actual max-spendable sat amount is right
    /// now. Builds a draft `drainTo + drainWallet` PSBT at the
    /// current fee rate (honouring an optional coin-control UTXO
    /// pin) and returns the sat value of the resulting single
    /// recipient output. Mirrors what BDK would do at real send
    /// time, so the user can paste the returned number into the
    /// amount field without tripping `Insufficient funds` later.
    ///
    /// The placeholder recipient script does not matter (it only
    /// affects vbytes by ~12 between p2pkh/p2wpkh/p2tr); BDK picks
    /// the same input set regardless. Callers pass the wallet's
    /// own next-unused receive script as a known-valid one.
    func previewMaxDrainSat(
        toAddressString address: String,
        feeRateSatsPerVb: UInt64,
        selectedUtxoOutpoints: [OutPoint]?
    ) throws -> UInt64 {
        let recipient = try Address(address: address, network: descriptor.network.bdk)
        let recipientScript = recipient.scriptPubkey()
        let feeRate = try FeeRate.fromSatPerVb(satVb: feeRateSatsPerVb)
        var builder = TxBuilder()
            .drainTo(script: recipientScript)
            .drainWallet()
            .feeRate(feeRate: feeRate)
        if let outpoints = selectedUtxoOutpoints, !outpoints.isEmpty {
            builder = builder.addUtxos(outpoints: outpoints).manuallySelectedOnly()
        }
        let psbt = try builder.finish(wallet: inner)
        let tx = try psbt.extractTx()
        let outs = tx.output()
        guard let drainOut = outs.first else { return 0 }
        return drainOut.value.toSat()
    }

    /// Build the unsigned PSBT for a planned spend. The user takes
    /// the returned base64 string to whichever signing surface they
    /// trust; Maknoon doesn't sign anything here.
    func buildUnsignedPSBT(
        toAddressString address: String,
        amountSat: UInt64,
        feeRateSatsPerVb: UInt64,
        enableRbf: Bool,
        selectedUtxoOutpoints: [OutPoint]?
    ) throws -> String {
        let recipient = try Address(address: address, network: descriptor.network.bdk)
        let recipientScript = recipient.scriptPubkey()
        let amount = Amount.fromSat(satoshi: amountSat)
        let feeRate = try FeeRate.fromSatPerVb(satVb: feeRateSatsPerVb)

        var builder = TxBuilder()
            .addRecipient(script: recipientScript, amount: amount)
            .feeRate(feeRate: feeRate)
        if !enableRbf {
            builder = builder.setExactSequence(nsequence: 0xFFFF_FFFE)
        }
        if let outpoints = selectedUtxoOutpoints, !outpoints.isEmpty {
            builder = builder.addUtxos(outpoints: outpoints).manuallySelectedOnly()
        }
        let psbt = try builder.finish(wallet: inner)
        // Persist after finish() because TxBuilder reserves change
        // addresses and reveals them on the keychain; without persist
        // the same change index would be reused on the next build.
        _ = try inner.persist(persister: persister)
        return psbt.serialize()
    }

    /// Import a fully-signed PSBT (base64), finalize signatures, and
    /// broadcast the extracted transaction via Electrum. Used by both
    /// the offline-signing path and (eventually) the on-device BLE
    /// signing path once that ships.
    ///
    /// `originalUnsignedBase64` is optional but strongly recommended
    /// for SeedSigner / Coldcard round-trips. Those signers strip
    /// witness-UTXO and other "input data" fields from the PSBT
    /// they emit (to keep the UR fragments small), leaving us with
    /// just the signatures. BDK can't finalize without the input
    /// data, so we BIP-174-merge the signed PSBT back with the
    /// original before finalizing.
    func importSignedPSBTAndBroadcast(
        signedPSBTBase64: String,
        originalUnsignedBase64: String? = nil,
        electrumURL: String
    ) throws -> String {
        var psbt = try Psbt(psbtBase64: signedPSBTBase64)

        // If the signer already produced final_script_witness /
        // final_script_sig for every input, the PSBT is fully
        // finalized and we can extract the tx directly. BDK's own
        // `Wallet.sign(tryFinalize: true)` (the software path) does
        // this. Calling `psbt.finalize()` again at this point would
        // misfire with "Missing pubkey for a pkh/wpkh" because
        // miniscript's per-input finalizer does not detect the
        // already-finalized state through BDK-FFI's wrapper.
        let preInputs = psbt.input()
        let allFinalized = !preInputs.isEmpty && preInputs.allSatisfy {
            $0.finalScriptWitness != nil || $0.finalScriptSig != nil
        }
        if allFinalized {
            let tx = try psbt.extractTx()
            return try broadcastAndApply(tx: tx, electrumURL: electrumURL)
        }

        // Otherwise (air-gapped signer path: SeedSigner / Coldcard
        // strip witness-UTXO and bip32 derivations to keep their UR
        // fragments small), splice the original unsigned PSBT back
        // in so BDK has enough context to finalize.
        if let originalUnsignedBase64 {
            let original = try Psbt(psbtBase64: originalUnsignedBase64)
            psbt = try psbt.combine(other: original)
        }
        let finalized = psbt.finalize()
        guard finalized.couldFinalize else {
            let errs = finalized.errors ?? []
            let summary = errs.map { "\($0)" }.joined(separator: "; ")
            let inputs = psbt.input()
            let diag = inputs.enumerated().map { idx, inp -> String in
                let sigs = inp.partialSigs.keys.map { String($0.prefix(12)) }.joined(separator: ",")
                let derivs = inp.bip32Derivation.keys.map { String($0.prefix(12)) }.joined(separator: ",")
                let hasWit = inp.witnessUtxo != nil
                let hasFinal = inp.finalScriptWitness != nil
                return "in[\(idx)] sigs=[\(sigs)] derivs=[\(derivs)] witUtxo=\(hasWit) finalWit=\(hasFinal)"
            }.joined(separator: " | ")
            throw WalletError.sendFailed(
                "PSBT could not be finalized. \(summary.isEmpty ? "No specific reason reported by BDK." : summary) [\(diag)]"
            )
        }
        let tx = try finalized.psbt.extractTx()
        return try broadcastAndApply(tx: tx, electrumURL: electrumURL)
    }

    private func broadcastAndApply(tx: Transaction, electrumURL: String) throws -> String {
        let client = try ElectrumClient(url: electrumURL, socks5: nil)
        let txid = try client.transactionBroadcast(tx: tx)
        // Apply the broadcast tx into the local view so the user
        // sees it in the recent-tx list without waiting for a sync.
        let unconfirmed = UnconfirmedTx(tx: tx, lastSeen: UInt64(Date().timeIntervalSince1970))
        inner.applyUnconfirmedTxs(unconfirmedTxs: [unconfirmed])
        _ = try inner.persist(persister: persister)
        return String(describing: txid)
    }
}

// MARK: -- helpers

private func timestamp(of tx: CanonicalTx) -> UInt64 {
    switch tx.chainPosition {
    case .confirmed(let blockTime, _):
        return blockTime.confirmationTime
    case .unconfirmed(let ts):
        return ts ?? UInt64.max  // unconfirmed sorts first
    }
}
