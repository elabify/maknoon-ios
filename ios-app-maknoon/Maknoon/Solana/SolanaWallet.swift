// One per-(descriptor, settings, sandwich) facade for Solana wallet
// operations. Mirrors `BitcoinWallet.swift`'s role: owns the RPC
// client, balance cache, and recent-tx fetch. Stateless beyond the
// in-memory cache; persistent state lives in SolanaWalletStore and
// SolanaSettings.
//
// Actor-isolated so the UI's `.task { ... await wallet.refresh() }`
// can call from MainActor without races on the balance cache or the
// in-flight URLSession.

import Foundation

actor SolanaWallet {
    let descriptor: SolanaWalletDescriptor
    /// Cluster this facade is wired against. Passed in by the caller
    /// (typically the SolanaWalletView's active-network selection)
    /// because the descriptor itself is cluster-agnostic in v2.
    let network: SolanaNetwork
    private let rpc: SolanaRPCClient
    private weak var sandwich: IdentitySandwich?

    /// Latest lamport balance, or nil if not yet fetched.
    private(set) var lamports: UInt64?
    private(set) var lastSync: Date?

    init(
        descriptor: SolanaWalletDescriptor,
        network: SolanaNetwork,
        rpcURL: String,
        sandwich: IdentitySandwich?
    ) {
        self.descriptor = descriptor
        self.network = network
        if let client = SolanaRPCClient(urlString: rpcURL) {
            self.rpc = client
        } else {
            // Fall back to the cluster's built-in default if the user
            // pasted an invalid URL; the UI surfaces an error
            // separately so this just means "the wallet still works
            // against the built-in default."
            self.rpc = SolanaRPCClient(endpoint: URL(string: network.defaultRpcURL)!)
        }
        self.sandwich = sandwich
    }

    // MARK: -- read

    /// Resolve the wallet's public address. Software wallets touch
    /// the sandwich (biometric prompt); hardware wallets read the
    /// cached pubkey from the descriptor.
    func address(biometricReason: String) throws -> String {
        switch descriptor.kind {
        case .software(let account):
            guard let sandwich else {
                throw SandwichError.masterUnavailable
            }
            return try SolanaDescriptors.addressFromSandwich(
                sandwich: sandwich,
                account: account,
                biometricReason: biometricReason
            )
        case .hardware(_, _, let publicKeyBase58):
            return publicKeyBase58
        }
    }

    /// Hardware wallets stash the pubkey at pair time; software
    /// wallets don't, but we cache it once derived per session so
    /// the dashboard doesn't biometric-prompt twice for one screen
    /// open.
    private var cachedAddress: String?
    func resolvedAddress(biometricReason: String) throws -> String {
        if let c = cachedAddress { return c }
        let a = try address(biometricReason: biometricReason)
        self.cachedAddress = a
        return a
    }

    /// Refresh balance from the RPC. Caller's responsibility to
    /// handle errors; we just update the cached lamport count.
    func refreshBalance(biometricReason: String) async throws -> UInt64 {
        let a = try resolvedAddress(biometricReason: biometricReason)
        let bal = try await rpc.getBalance(address: a)
        self.lamports = bal
        self.lastSync = Date()
        return bal
    }

    /// Recent signatures + metadata for the dashboard's tx list.
    func recentSignatures(limit: Int = 10, biometricReason: String) async throws -> [SolanaRPCClient.SignatureRecord] {
        let a = try resolvedAddress(biometricReason: biometricReason)
        return try await rpc.getSignaturesForAddress(a, limit: limit)
    }

    /// Walk every SPL token account this wallet owns. Returned
    /// entries are filtered to the standard SPL Token Program; Token-
    /// 2022 mints are intentionally excluded for v1.
    func tokenAccounts(biometricReason: String) async throws -> [SolanaRPCClient.TokenAccount] {
        let a = try resolvedAddress(biometricReason: biometricReason)
        return try await rpc.getTokenAccountsByOwner(ownerAddress: a)
    }

    /// Send an SPL token. The caller is responsible for converting
    /// human-readable amounts to base units (e.g. "1.5 USDC" with 6
    /// decimals is `1_500_000`). The builder probes the recipient's
    /// ATA existence on chain and picks the right TWC payload shape
    /// (transfer-only vs create-then-transfer) automatically.
    func sendSPLToken(
        mint: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipient: String,
        priorityFeeMicroLamports: UInt64,
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw SolanaDescriptorError.signingFailed("Wallet is hardware-backed; SPL software send not applicable")
        }
        // Derive the recipient's ATA off-chain, then probe whether
        // it already exists so the tx can prepend CreateATA only
        // when needed.
        let recipientATA = try SolanaSPLTransferBuilder.associatedTokenAddress(
            ownerBase58: recipient,
            mintBase58: mint
        )
        let recipientHasATA = (try? await rpc.accountExists(address: recipientATA)) ?? false
        let bh = try await rpc.getLatestBlockhash()
        let signedBase64 = try SolanaSPLTransferBuilder.sign(
            sandwich: sandwich,
            account: account,
            mintBase58: mint,
            decimals: decimals,
            rawAmount: rawAmount,
            recipientOwnerBase58: recipient,
            recipientHasATA: recipientHasATA,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            biometricReason: biometricReason
        )
        return try await rpc.sendTransaction(signedBase64: signedBase64)
    }

    // MARK: -- send

    /// Build, sign, and broadcast a native SOL transfer. Returns the
    /// signature (which is the canonical tx id). Lamport conversion
    /// is the caller's job: 1 SOL = 1_000_000_000 lamports.
    func sendSoftware(
        recipient: String,
        lamports: UInt64,
        priorityFeeMicroLamports: UInt64,
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw SolanaDescriptorError.signingFailed("Wallet is hardware-backed; software send not applicable")
        }
        let bh = try await rpc.getLatestBlockhash()
        let signedBase64 = try SolanaDescriptors.signTransferFromSandwich(
            sandwich: sandwich,
            account: account,
            recipientBase58: recipient,
            lamports: lamports,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            biometricReason: biometricReason
        )
        let sig = try await rpc.sendTransaction(signedBase64: signedBase64)
        return sig
    }

    /// Hardware-backed native SOL transfer. The Ledger holds the
    /// private key; Maknoon builds the unsigned message, ships it
    /// to the device over BLE, gets the 64-byte signature, then
    /// assembles the wire-ready signed transaction via TWC's
    /// TransactionCompiler.
    func sendHardware(
        recipient: String,
        lamports: UInt64,
        priorityFeeMicroLamports: UInt64,
        ledger: HardwareWallet,
        signerBase58: String,
        signerPublicKey: Data,
        account: UInt32
    ) async throws -> String {
        let bh = try await rpc.getLatestBlockhash()
        let unsignedMessage = try SolanaDescriptors.unsignedMessageForTransfer(
            signerBase58: signerBase58,
            recipientBase58: recipient,
            lamports: lamports,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let signature = try await ledger.signSolanaTransaction(
            unsignedTx: unsignedMessage,
            account: account
        )
        let signedBase64 = try SolanaDescriptors.assembleSignedTransfer(
            signerBase58: signerBase58,
            recipientBase58: recipient,
            lamports: lamports,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            signature: signature,
            signerPublicKey: signerPublicKey
        )
        return try await rpc.sendTransaction(signedBase64: signedBase64)
    }

    /// Sign-only step of the hardware native send. Returns the
    /// wire-ready signed transaction (base64); the caller broadcasts
    /// separately via `broadcastSignedBase64`. Splitting the steps
    /// lets the UI show a "signed, awaiting broadcast" state.
    func prepareHardwareNative(
        recipient: String,
        lamports: UInt64,
        priorityFeeMicroLamports: UInt64,
        ledger: HardwareWallet,
        signerBase58: String,
        signerPublicKey: Data,
        account: UInt32
    ) async throws -> String {
        let bh = try await rpc.getLatestBlockhash()
        let unsignedMessage = try SolanaDescriptors.unsignedMessageForTransfer(
            signerBase58: signerBase58,
            recipientBase58: recipient,
            lamports: lamports,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let signature = try await ledger.signSolanaTransaction(
            unsignedTx: unsignedMessage,
            account: account
        )
        return try SolanaDescriptors.assembleSignedTransfer(
            signerBase58: signerBase58,
            recipientBase58: recipient,
            lamports: lamports,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            signature: signature,
            signerPublicKey: signerPublicKey
        )
    }

    /// Broadcast a pre-signed base64 Solana transaction. Used by
    /// the send view after the user taps Broadcast on the "signed"
    /// interstitial state.
    func broadcastSignedBase64(_ signedBase64: String) async throws -> String {
        try await rpc.sendTransaction(signedBase64: signedBase64)
    }

    /// Rent-exempt minimum (lamports) for a plain 0-byte system
    /// account. Network-invariant under Solana's standard rent config.
    /// 0.00089088 SOL.
    static let rentExemptMinimumLamports: UInt64 = 890_880

    /// Pre-flight guard for a native SOL transfer: a transfer that
    /// would create a brand-new recipient account (one that doesn't
    /// exist on-chain yet) must leave it at or above the rent-exempt
    /// minimum, or the cluster rejects the whole tx with
    /// `InsufficientFundsForRent { account_index: 1 }` at simulation.
    /// Throws a clear, actionable error in that case so the user sees
    /// "send a bit more" instead of a raw RPC code. No-op once the
    /// recipient exists (any amount is then valid), and fail-open if
    /// the existence probe itself errors (let the real send surface it).
    func assertRentExemptForNativeTransfer(recipient: String, lamports: UInt64) async throws {
        guard lamports < Self.rentExemptMinimumLamports else { return }
        let exists = (try? await rpc.accountExists(address: recipient)) ?? true
        guard !exists else { return }
        throw SolanaDescriptorError.signingFailed(
            "\(recipient.prefix(6))… is a brand-new account. Solana requires at least "
            + "0.00089088 SOL to create it (rent exemption). Send at least that much, "
            + "or fund the address another way first."
        )
    }

    /// Hardware SPL token transfer. The Ledger holds the private
    /// key; Maknoon builds the unsigned SPL transfer message,
    /// ships it to the device, and assembles the signed wire form
    /// via TWC's TransactionCompiler.
    ///
    /// Returns the txid on success.
    func sendHardwareSPLToken(
        mint: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipient: String,
        priorityFeeMicroLamports: UInt64,
        ledger: HardwareWallet,
        signerBase58: String,
        signerPublicKey: Data,
        account: UInt32
    ) async throws -> String {
        let signedBase64 = try await prepareHardwareSPLToken(
            mint: mint,
            decimals: decimals,
            rawAmount: rawAmount,
            recipient: recipient,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            ledger: ledger,
            signerBase58: signerBase58,
            signerPublicKey: signerPublicKey,
            account: account
        )
        return try await rpc.sendTransaction(signedBase64: signedBase64)
    }

    /// Sign-only step of the hardware SPL send. Returns base64
    /// signed tx for `broadcastSignedBase64`.
    func prepareHardwareSPLToken(
        mint: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipient: String,
        priorityFeeMicroLamports: UInt64,
        ledger: HardwareWallet,
        signerBase58: String,
        signerPublicKey: Data,
        account: UInt32
    ) async throws -> String {
        let recipientATA = try SolanaSPLTransferBuilder.associatedTokenAddress(
            ownerBase58: recipient,
            mintBase58: mint
        )
        let recipientHasATA = (try? await rpc.accountExists(address: recipientATA)) ?? false
        let bh = try await rpc.getLatestBlockhash()
        let unsignedMessage = try SolanaSPLTransferBuilder.unsignedMessage(
            signerBase58: signerBase58,
            mintBase58: mint,
            decimals: decimals,
            rawAmount: rawAmount,
            recipientOwnerBase58: recipient,
            recipientHasATA: recipientHasATA,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let signature = try await ledger.signSolanaTransaction(
            unsignedTx: unsignedMessage,
            account: account
        )
        return try SolanaSPLTransferBuilder.assembleSigned(
            signerBase58: signerBase58,
            mintBase58: mint,
            decimals: decimals,
            rawAmount: rawAmount,
            recipientOwnerBase58: recipient,
            recipientHasATA: recipientHasATA,
            recentBlockhashBase58: bh.blockhash,
            priorityFeeMicroLamports: priorityFeeMicroLamports,
            signature: signature,
            signerPublicKey: signerPublicKey
        )
    }

    /// Poll for confirmation after a sendTransaction. Returns the
    /// status (or nil if the network hasn't seen it yet). Caller
    /// times out / retries as it sees fit.
    func signatureStatus(_ signature: String) async throws -> SolanaRPCClient.SignatureStatus? {
        let statuses = try await rpc.getSignatureStatuses([signature])
        return statuses.first ?? nil
    }
}
