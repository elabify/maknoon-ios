// Signs an SPL token transfer under the sandwich seed and returns
// the base64-encoded wire-ready transaction, ready for
// `SolanaRPCClient.sendTransaction`. Mirrors
// `SolanaDescriptors.signTransferFromSandwich` for native SOL.
//
// SPL transfers are more involved than native SOL: every wallet that
// holds a given mint owns a separate Associated Token Account (ATA),
// a Solana PDA derived deterministically from (owner, mint, token
// program). The sender's ATA holds the source balance; the
// recipient's ATA receives the transfer. If the recipient has never
// touched this mint before, their ATA doesn't exist on chain yet and
// the tx has to create it first.
//
// Both ATA derivation and the dual-shape transaction (transfer-only
// vs create-then-transfer) are routed through Trust Wallet Core so we
// don't hand-roll the SPL Token Program / Associated Token Account
// Program instruction encoding ourselves; TWC does both, validated
// against the standard Solana JSON-RPC test vectors.

import Foundation
import WalletCore

enum SolanaSPLTransferError: LocalizedError {
    case invalidRecipient(String)
    case invalidMint(String)
    case ataDerivationFailed
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecipient(let s):
            return "Recipient address is not a valid Solana pubkey: \(s)"
        case .invalidMint(let s):
            return "SPL mint is not a valid Solana pubkey: \(s)"
        case .ataDerivationFailed:
            return "Could not derive the recipient's token account."
        case .signingFailed(let m):
            return "SPL signing failed: \(m)"
        }
    }
}

enum SolanaSPLTransferBuilder {

    /// Derive the Associated Token Account address for a given
    /// `(owner, mint)` pair. ATA derivation is deterministic and
    /// doesn't touch the chain. Used both at signing time (to
    /// compute the recipient ATA) and at probe time (to decide
    /// whether a `createAccount` instruction needs to be prepended).
    static func associatedTokenAddress(ownerBase58: String, mintBase58: String) throws -> String {
        guard let owner = WalletCore.SolanaAddress(string: ownerBase58) else {
            throw SolanaSPLTransferError.invalidRecipient(ownerBase58)
        }
        guard let ata = owner.defaultTokenAddress(tokenMintAddress: mintBase58), !ata.isEmpty else {
            throw SolanaSPLTransferError.ataDerivationFailed
        }
        return ata
    }

    /// Sign an SPL transfer under the sandwich seed.
    ///
    /// - Parameters:
    ///   - recipientOwnerBase58: the recipient's wallet (system) address.
    ///     The builder derives their ATA from this + the mint.
    ///   - recipientHasATA: whether the recipient already has an ATA for
    ///     this mint on chain. The caller probes via
    ///     `SolanaRPCClient.accountExists` and passes the result here so
    ///     the builder picks `SolanaTokenTransfer` vs
    ///     `SolanaCreateAndTransferToken`.
    ///   - rawAmount: integer token amount expressed in base units (so
    ///     "1.00 USDC" is `1_000_000` because USDC has 6 decimals). The
    ///     caller is responsible for the decimals math; the builder
    ///     forwards the raw amount on the wire.
    static func sign(
        sandwich: IdentitySandwich,
        account: UInt32,
        mintBase58: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipientOwnerBase58: String,
        recipientHasATA: Bool,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64,
        biometricReason: String
    ) throws -> String {
        guard WalletCore.AnyAddress(string: recipientOwnerBase58, coin: .solana) != nil else {
            throw SolanaSPLTransferError.invalidRecipient(recipientOwnerBase58)
        }
        guard WalletCore.AnyAddress(string: mintBase58, coin: .solana) != nil else {
            throw SolanaSPLTransferError.invalidMint(mintBase58)
        }
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = WalletCore.HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw SolanaSPLTransferError.signingFailed("HDWallet init returned nil")
        }
        let priv = wallet.getKeyByCurve(
            curve: .ed25519,
            derivationPath: SolanaDescriptors.derivationPath(account: account)
        )
        let ownerAddress = WalletCore.CoinType.solana.deriveAddress(privateKey: priv)
        let senderATA = try associatedTokenAddress(ownerBase58: ownerAddress, mintBase58: mintBase58)
        let recipientATA = try associatedTokenAddress(ownerBase58: recipientOwnerBase58, mintBase58: mintBase58)

        var input = WalletCore.SolanaSigningInput()
        input.privateKey = priv.data
        input.recentBlockhash = recentBlockhashBase58
        // base64 output so sendTransaction (encoding: base64) accepts
        // it. TWC's base58 default only fails intermittently (when the
        // string length isn't a multiple of 4), which is the
        // "invalid base64 invalidLength" RPC error.
        input.txEncoding = .base64
        if priorityFeeMicroLamports > 0 {
            var price = WalletCore.SolanaPriorityFeePrice()
            price.price = priorityFeeMicroLamports
            input.priorityFeePrice = price
        }
        if recipientHasATA {
            var transfer = WalletCore.SolanaTokenTransfer()
            transfer.tokenMintAddress = mintBase58
            transfer.senderTokenAddress = senderATA
            transfer.recipientTokenAddress = recipientATA
            transfer.amount = rawAmount
            transfer.decimals = UInt32(decimals)
            input.tokenTransferTransaction = transfer
        } else {
            // Combined instruction: create-ATA-then-transfer. TWC
            // emits both the AssociatedTokenAccount::Create and the
            // SPL Token::TransferChecked instructions in one tx.
            var combined = WalletCore.SolanaCreateAndTransferToken()
            combined.recipientMainAddress = recipientOwnerBase58
            combined.tokenMintAddress = mintBase58
            combined.recipientTokenAddress = recipientATA
            combined.senderTokenAddress = senderATA
            combined.amount = rawAmount
            combined.decimals = UInt32(decimals)
            input.createAndTransferTokenTransaction = combined
        }
        let output: WalletCore.SolanaSigningOutput = WalletCore.AnySigner.sign(
            input: input, coin: .solana
        )
        if !output.errorMessage.isEmpty {
            throw SolanaSPLTransferError.signingFailed(output.errorMessage)
        }
        return output.encoded
    }

    /// Build the unsigned SPL transfer message for hardware sign.
    /// Mirrors `SolanaDescriptors.unsignedMessageForTransfer` but
    /// for token transfers. Uses TWC's `TransactionCompiler.preImageHashes`
    /// to produce the wire-format bytes the Ledger Solana app
    /// signs.
    static func unsignedMessage(
        signerBase58: String,
        mintBase58: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipientOwnerBase58: String,
        recipientHasATA: Bool,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64
    ) throws -> Data {
        let input = try buildSPLInput(
            signerBase58: signerBase58,
            mintBase58: mintBase58,
            decimals: decimals,
            rawAmount: rawAmount,
            recipientOwnerBase58: recipientOwnerBase58,
            recipientHasATA: recipientHasATA,
            recentBlockhashBase58: recentBlockhashBase58,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let inputBytes: Data
        do {
            inputBytes = try input.serializedData()
        } catch {
            throw SolanaSPLTransferError.signingFailed("preImage: serializedData failed: \(error)")
        }
        let preImageBytes = WalletCore.TransactionCompiler.preImageHashes(
            coinType: .solana,
            txInputData: inputBytes
        )
        let preImage: WalletCore.SolanaPreSigningOutput
        do {
            preImage = try WalletCore.SolanaPreSigningOutput(serializedData: preImageBytes)
        } catch {
            throw SolanaSPLTransferError.signingFailed("preImage: deserialize failed: \(error)")
        }
        if !preImage.errorMessage.isEmpty {
            throw SolanaSPLTransferError.signingFailed("preImage: \(preImage.errorMessage)")
        }
        return preImage.data
    }

    /// Combine an externally-produced Ed25519 signature with the SPL
    /// transfer parameters to produce a wire-ready signed tx in
    /// base64 form. Used by the hardware SPL send path after the
    /// Ledger returns the signature for `unsignedMessage`.
    static func assembleSigned(
        signerBase58: String,
        mintBase58: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipientOwnerBase58: String,
        recipientHasATA: Bool,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64,
        signature: Data,
        signerPublicKey: Data
    ) throws -> String {
        guard signature.count == 64 else {
            throw SolanaSPLTransferError.signingFailed(
                "Ledger signature was \(signature.count) bytes; expected 64"
            )
        }
        guard signerPublicKey.count == 32 else {
            throw SolanaSPLTransferError.signingFailed(
                "Signer pubkey was \(signerPublicKey.count) bytes; expected 32"
            )
        }
        let input = try buildSPLInput(
            signerBase58: signerBase58,
            mintBase58: mintBase58,
            decimals: decimals,
            rawAmount: rawAmount,
            recipientOwnerBase58: recipientOwnerBase58,
            recipientHasATA: recipientHasATA,
            recentBlockhashBase58: recentBlockhashBase58,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let inputBytes: Data
        do {
            inputBytes = try input.serializedData()
        } catch {
            throw SolanaSPLTransferError.signingFailed("compile: serializedData failed: \(error)")
        }
        let signatures = WalletCore.DataVector()
        signatures.add(data: signature)
        let pubkeys = WalletCore.DataVector()
        pubkeys.add(data: signerPublicKey)
        let outputBytes = WalletCore.TransactionCompiler.compileWithSignatures(
            coinType: .solana,
            txInputData: inputBytes,
            signatures: signatures,
            publicKeys: pubkeys
        )
        let output: WalletCore.SolanaSigningOutput
        do {
            output = try WalletCore.SolanaSigningOutput(serializedData: outputBytes)
        } catch {
            throw SolanaSPLTransferError.signingFailed("compile: deserialize failed: \(error)")
        }
        if !output.errorMessage.isEmpty {
            throw SolanaSPLTransferError.signingFailed("compile: \(output.errorMessage)")
        }
        return output.encoded
    }

    /// Shared SolanaSigningInput constructor for the SPL transfer
    /// shape. `feePayer = signerBase58` so TransactionCompiler can
    /// resolve signer names before the signature is attached.
    /// Used by both the hardware (no private key) and software
    /// (private-key inline) paths.
    private static func buildSPLInput(
        signerBase58: String,
        mintBase58: String,
        decimals: UInt8,
        rawAmount: UInt64,
        recipientOwnerBase58: String,
        recipientHasATA: Bool,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64
    ) throws -> WalletCore.SolanaSigningInput {
        guard WalletCore.AnyAddress(string: recipientOwnerBase58, coin: .solana) != nil else {
            throw SolanaSPLTransferError.invalidRecipient(recipientOwnerBase58)
        }
        guard WalletCore.AnyAddress(string: mintBase58, coin: .solana) != nil else {
            throw SolanaSPLTransferError.invalidMint(mintBase58)
        }
        let senderATA = try associatedTokenAddress(ownerBase58: signerBase58, mintBase58: mintBase58)
        let recipientATA = try associatedTokenAddress(ownerBase58: recipientOwnerBase58, mintBase58: mintBase58)

        var input = WalletCore.SolanaSigningInput()
        input.recentBlockhash = recentBlockhashBase58
        // base64 output to match sendTransaction (encoding: base64).
        input.txEncoding = .base64
        // `sender` (proto field 14) is REQUIRED by TWC for building
        // the pre-signing hash of a token transfer: it identifies the
        // authority that owns `senderTokenAddress`. Without it TWC's
        // preImageHashes fails with "Sender address is either not set
        // or invalid". `feePayer` is NOT a substitute here (that's an
        // optional *separate* fee-paying account). The signer is also
        // the fee payer, which is the default when feePayer is unset.
        input.sender = signerBase58
        if priorityFeeMicroLamports > 0 {
            var price = WalletCore.SolanaPriorityFeePrice()
            price.price = priorityFeeMicroLamports
            input.priorityFeePrice = price
        }
        if recipientHasATA {
            var transfer = WalletCore.SolanaTokenTransfer()
            transfer.tokenMintAddress = mintBase58
            transfer.senderTokenAddress = senderATA
            transfer.recipientTokenAddress = recipientATA
            transfer.amount = rawAmount
            transfer.decimals = UInt32(decimals)
            input.tokenTransferTransaction = transfer
        } else {
            var combined = WalletCore.SolanaCreateAndTransferToken()
            combined.recipientMainAddress = recipientOwnerBase58
            combined.tokenMintAddress = mintBase58
            combined.recipientTokenAddress = recipientATA
            combined.senderTokenAddress = senderATA
            combined.amount = rawAmount
            combined.decimals = UInt32(decimals)
            input.createAndTransferTokenTransaction = combined
        }
        return input
    }
}
