// Solana software-wallet primitives: BIP44 + SLIP-0010 Ed25519
// derivation at m/44'/501'/<account>'/0' and host-side signing for
// native SOL transfers (SPL token transfers ship in a follow-on PR).
//
// Uses Trust Wallet Core throughout. TWC's HDWallet exposes
// `getKeyByCurve(curve: .ed25519, derivationPath:)`. TWC also ships
// `AnySigner.sign(input: SolanaSigningInput, coin: .solana)` plus the
// generated SolanaSigningInput / SolanaSigningOutput protobufs, so we
// can describe a transfer declaratively and let TWC handle the wire
// shape (compact-array message + 64-byte Ed25519 signature).

import Foundation
import WalletCore

enum SolanaDescriptorError: LocalizedError {
    case hdWalletFailed(String)
    case derivationFailed(String)
    case signingFailed(String)
    case invalidAddress(String)

    var errorDescription: String? {
        switch self {
        case .hdWalletFailed(let m):  return "Solana HDWallet derivation failed: \(m)"
        case .derivationFailed(let m): return "Solana key derivation failed: \(m)"
        case .signingFailed(let m):    return "Solana signing failed: \(m)"
        case .invalidAddress(let s):   return "Not a valid Solana address: \(s)"
        }
    }
}

enum SolanaDescriptors {

    /// Standard SLIP-0010 Ed25519 BIP44 path for Solana. The address
    /// index is omitted (Solana doesn't BIP44-walk per-address the
    /// way Bitcoin does); each account's primary key IS the address.
    static func derivationPath(account: UInt32) -> String {
        "m/44'/501'/\(account)'/0'"
    }

    /// Read the sandwich seed under a biometric prompt, derive the
    /// Ed25519 key at the BIP44 path for `account`, return the base58
    /// public-key string Solana uses as the address.
    static func addressFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        biometricReason: String
    ) throws -> String {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw SolanaDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let priv = wallet.getKeyByCurve(curve: .ed25519, derivationPath: derivationPath(account: account))
        return CoinType.solana.deriveAddress(privateKey: priv)
    }

    /// Validate a Solana address as a 32-byte base58 pubkey. Returns
    /// nil if malformed.
    static func parseAddress(_ s: String) -> String? {
        guard AnyAddress(string: s, coin: .solana) != nil else { return nil }
        return s
    }

    /// Sign a native SOL transfer. Returns the wire-ready signed
    /// transaction as base64, suitable for `sendTransaction` over the
    /// JSON-RPC endpoint.
    ///
    /// `recentBlockhash` is a 32-byte hash from `getLatestBlockhash`
    /// (returned as base58); transactions older than ~150 slots get
    /// rejected. `lamports` is the integer SOL amount (1 SOL = 10^9
    /// lamports). `priorityFeeMicroLamports` is the optional priority
    /// fee budget added as a ComputeBudget instruction; 0 means "no
    /// priority fee".
    static func signTransferFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        recipientBase58: String,
        lamports: UInt64,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64,
        biometricReason: String
    ) throws -> String {
        guard parseAddress(recipientBase58) != nil else {
            throw SolanaDescriptorError.invalidAddress(recipientBase58)
        }
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw SolanaDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let priv = wallet.getKeyByCurve(curve: .ed25519, derivationPath: derivationPath(account: account))

        var input = SolanaSigningInput()
        input.privateKey = priv.data
        input.recentBlockhash = recentBlockhashBase58
        // Emit base64: SolanaRPCClient.sendTransaction passes
        // `encoding: base64`. TWC defaults to base58, whose chars are
        // a subset of base64 so it only fails when the length isn't a
        // multiple of 4 (the "invalid base64 invalidLength" RPC
        // error). Force base64 so every signed tx is accepted.
        input.txEncoding = .base64
        if priorityFeeMicroLamports > 0 {
            // Solana's ComputeBudget program accepts a priority fee
            // expressed as micro-lamports per compute unit; TWC
            // exposes it via `priorityFeePrice` + `priorityFeeLimit`.
            // For a simple transfer the default CU limit (200_000) is
            // fine; we set the unit price and let TWC encode the
            // ComputeBudget::SetComputeUnitPrice instruction.
            var pricePriority = SolanaPriorityFeePrice()
            pricePriority.price = priorityFeeMicroLamports
            input.priorityFeePrice = pricePriority
        }

        var transfer = SolanaTransfer()
        transfer.recipient = recipientBase58
        transfer.value = lamports
        input.transferTransaction = transfer

        let output: SolanaSigningOutput = AnySigner.sign(input: input, coin: .solana)
        if !output.errorMessage.isEmpty {
            throw SolanaDescriptorError.signingFailed(output.errorMessage)
        }
        // TWC returns the wire-ready signed transaction as `encoded`
        // (base64). Solana's JSON-RPC sendTransaction accepts base64
        // when the call's encoding option is set; we'll send it that
        // way from SolanaRPCClient.
        return output.encoded
    }

    /// Build a SolanaSigningInput protobuf describing a native SOL
    /// transfer. Used by both the software path (sign locally) and the
    /// hardware path (TransactionCompiler preImageHashes + external
    /// signature). Note: the input does NOT carry a private key. The
    /// software call site sets `privateKey` before signing.
    private static func transferInput(
        signerBase58: String,
        recipientBase58: String,
        lamports: UInt64,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64
    ) -> SolanaSigningInput {
        var input = SolanaSigningInput()
        input.recentBlockhash = recentBlockhashBase58
        // base64 output to match sendTransaction's encoding (see note
        // in the software-sign path).
        input.txEncoding = .base64
        // `sender` (proto field 14) is REQUIRED by TWC's external-signing
        // path: it names the authority that funds + signs the transfer so
        // preImageHashes can list the signer before any signature exists.
        // Without it TWC fails with "Sender address is either not set or
        // invalid". `feePayer` is NOT a substitute (it's an optional,
        // *separate* fee-paying account, and TWC rejects it when it equals
        // an account already in the list); the signer is the fee payer by
        // default when `feePayer` is unset. Mirrors the SPL builder.
        input.sender = signerBase58
        if priorityFeeMicroLamports > 0 {
            var pricePriority = SolanaPriorityFeePrice()
            pricePriority.price = priorityFeeMicroLamports
            input.priorityFeePrice = pricePriority
        }
        var transfer = SolanaTransfer()
        transfer.recipient = recipientBase58
        transfer.value = lamports
        input.transferTransaction = transfer
        return input
    }

    /// Build the unsigned message bytes for a native SOL transfer.
    /// Returned bytes are exactly what gets fed to the Ledger Solana
    /// app's SIGN_MESSAGE APDU. Use `assembleSignedTransfer` to
    /// stitch the resulting 64-byte signature into a wire-ready tx.
    static func unsignedMessageForTransfer(
        signerBase58: String,
        recipientBase58: String,
        lamports: UInt64,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64
    ) throws -> Data {
        guard parseAddress(recipientBase58) != nil else {
            throw SolanaDescriptorError.invalidAddress(recipientBase58)
        }
        let input = transferInput(
            signerBase58: signerBase58,
            recipientBase58: recipientBase58,
            lamports: lamports,
            recentBlockhashBase58: recentBlockhashBase58,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let inputBytes: Data
        do {
            inputBytes = try input.serializedData()
        } catch {
            throw SolanaDescriptorError.signingFailed("preImage: serializedData failed: \(error)")
        }
        let preImageHashesBytes = TransactionCompiler.preImageHashes(
            coinType: .solana,
            txInputData: inputBytes
        )
        let preImage: SolanaPreSigningOutput
        do {
            preImage = try SolanaPreSigningOutput(serializedData: preImageHashesBytes)
        } catch {
            throw SolanaDescriptorError.signingFailed("preImage: deserialize failed: \(error)")
        }
        if !preImage.errorMessage.isEmpty {
            throw SolanaDescriptorError.signingFailed("preImage: \(preImage.errorMessage)")
        }
        // For Solana, TWC populates `data` with the wire-format
        // message bytes (signers + recent blockhash + instructions).
        // That's exactly what the device signs.
        return preImage.data
    }

    /// Combine an externally-produced 64-byte Ed25519 signature with
    /// the transfer parameters to produce a wire-ready signed tx in
    /// base64 form, ready for `sendTransaction`.
    static func assembleSignedTransfer(
        signerBase58: String,
        recipientBase58: String,
        lamports: UInt64,
        recentBlockhashBase58: String,
        priorityFeeMicroLamports: UInt64,
        signature: Data,
        signerPublicKey: Data
    ) throws -> String {
        guard signature.count == 64 else {
            throw SolanaDescriptorError.signingFailed(
                "Ledger signature was \(signature.count) bytes; expected 64"
            )
        }
        guard signerPublicKey.count == 32 else {
            throw SolanaDescriptorError.signingFailed(
                "Signer public key was \(signerPublicKey.count) bytes; expected 32"
            )
        }
        let input = transferInput(
            signerBase58: signerBase58,
            recipientBase58: recipientBase58,
            lamports: lamports,
            recentBlockhashBase58: recentBlockhashBase58,
            priorityFeeMicroLamports: priorityFeeMicroLamports
        )
        let inputBytes: Data
        do {
            inputBytes = try input.serializedData()
        } catch {
            throw SolanaDescriptorError.signingFailed("compile: serializedData failed: \(error)")
        }
        let signatures = DataVector()
        signatures.add(data: signature)
        let pubkeys = DataVector()
        pubkeys.add(data: signerPublicKey)
        let outputBytes = TransactionCompiler.compileWithSignatures(
            coinType: .solana,
            txInputData: inputBytes,
            signatures: signatures,
            publicKeys: pubkeys
        )
        let output: SolanaSigningOutput
        do {
            output = try SolanaSigningOutput(serializedData: outputBytes)
        } catch {
            throw SolanaDescriptorError.signingFailed("compile: deserialize failed: \(error)")
        }
        if !output.errorMessage.isEmpty {
            throw SolanaDescriptorError.signingFailed("compile: \(output.errorMessage)")
        }
        return output.encoded
    }
}
