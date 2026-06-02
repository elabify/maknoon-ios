// Tron key derivation + address helpers. BIP44 path is
// `m/44'/195'/<account>'/0/0` with secp256k1; the address is the
// 34-character base58check form starting with `T`.
//
// Native TRX signing piggybacks on TWC's `AnySigner.sign(input:
// SolanaSigningInput, coin: .tron)` equivalent for Tron, after the
// caller has fetched a fresh block reference from TronGrid
// (`/wallet/getnowblock`) and passed it in as a `BlockReference`.
//
// We deliberately keep the on-chain encoding work in TWC rather
// than hand-rolling protobuf framing — TWC is validated against the
// Tron mainnet test vectors and matches the TRX format byte-for-byte.

import Foundation
import WalletCore

enum TronDescriptorError: LocalizedError {
    case invalidAddress(String)
    case hdWalletFailed(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let s): return "Invalid Tron address: \(s)"
        case .hdWalletFailed(let m): return "HD wallet derivation failed: \(m)"
        case .signingFailed(let m):  return "Tron signing failed: \(m)"
        }
    }
}

/// Block reference values pulled from TronGrid's `/wallet/getnowblock`
/// and folded into the signed transaction so the network accepts it.
/// Tron transactions are tied to a specific block by these fields;
/// they expire after 65 blocks (~3 minutes).
struct TronBlockRef: Sendable {
    let number: Int64
    let timestamp: Int64
    let parentHash: Data
    let txTrieRoot: Data
    let witnessAddress: Data
    let version: Int32
}

enum TronDescriptors {

    static func derivationPath(account: UInt32) -> String {
        "m/44'/195'/\(account)'/0/0"
    }

    static func addressFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        biometricReason: String
    ) throws -> String {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = WalletCore.HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw TronDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let priv = wallet.getKeyByCurve(
            curve: .secp256k1,
            derivationPath: derivationPath(account: account)
        )
        return WalletCore.CoinType.tron.deriveAddress(privateKey: priv)
    }

    /// Validate a Tron base58check address.
    static func parseAddress(_ s: String) -> String? {
        guard WalletCore.AnyAddress(string: s, coin: .tron) != nil else { return nil }
        return s
    }

    /// Sign a native TRX transfer. Returns the broadcast-ready JSON
    /// payload that goes into TronGrid's `/wallet/broadcasttransaction`.
    static func signNativeTransferFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        senderBase58: String,
        recipientBase58: String,
        sunAmount: Int64,
        blockRef: TronBlockRef,
        feeLimitSun: Int64,
        biometricReason: String
    ) throws -> String {
        guard parseAddress(recipientBase58) != nil else {
            throw TronDescriptorError.invalidAddress(recipientBase58)
        }
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = WalletCore.HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw TronDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let priv = wallet.getKeyByCurve(
            curve: .secp256k1,
            derivationPath: derivationPath(account: account)
        )

        var input = WalletCore.TronSigningInput()
        input.privateKey = priv.data

        var tx = WalletCore.TronTransaction()
        tx.timestamp = blockRef.timestamp
        // Tron transactions expire ~65 blocks after the reference;
        // a 60-second window is well inside that bound and keeps the
        // user from broadcasting against a stale ref after the
        // biometric prompt + manual confirm latency.
        tx.expiration = blockRef.timestamp + 60_000
        tx.feeLimit = feeLimitSun
        tx.blockHeader = makeBlockHeader(blockRef)

        var transfer = WalletCore.TronTransferContract()
        transfer.ownerAddress = senderBase58
        transfer.toAddress = recipientBase58
        transfer.amount = sunAmount
        tx.contractOneof = .transfer(transfer)

        input.transaction = tx
        let output: WalletCore.TronSigningOutput = WalletCore.AnySigner.sign(input: input, coin: .tron)
        if !output.errorMessage.isEmpty {
            throw TronDescriptorError.signingFailed(output.errorMessage)
        }
        return output.json
    }

    /// Hardware-signed native TRX transfer. Routes through
    /// TronGrid's `/wallet/createtransaction` so the Ledger gets
    /// the EXACT raw_data protobuf bytes the network expects,
    /// avoiding the TWC `TransactionCompiler.preImageHashes` quirk
    /// for Tron (it returns the SHA-256 hash, not raw_data, which
    /// caused the Ledger to silently return 0 bytes on SIGN).
    ///
    /// Returns the wire-ready signed transaction JSON which is
    /// POSTed to `/wallet/broadcasttransaction`.
    static func signNativeTransferOnHardware(
        rpc: TronRPCClient,
        ledger: HardwareWallet,
        account: UInt32,
        senderBase58: String,
        recipientBase58: String,
        sunAmount: Int64,
        feeLimitSun: Int64
    ) async throws -> TronUnsignedAndSignature {
        guard parseAddress(recipientBase58) != nil else {
            throw TronDescriptorError.invalidAddress(recipientBase58)
        }
        // Server builds the unsigned tx; we trust TronGrid for the
        // raw_data shape because the broadcast endpoint also lives
        // there. Native TRX transfers don't need a fee_limit (the
        // sender pays bandwidth/energy out of pocket); pass nil so
        // the server uses its own default.
        let unsigned = try await rpc.createNativeTransaction(
            senderBase58: senderBase58,
            recipientBase58: recipientBase58,
            sunAmount: sunAmount,
            feeLimitSun: nil
        )
        let sig = try await ledger.signTronTransaction(
            rawTxProto: unsigned.rawData,
            account: account
        )
        guard sig.r.count == 32, sig.s.count == 32 else {
            throw TronDescriptorError.signingFailed(
                "Ledger returned malformed signature components"
            )
        }
        var signatureRSV = Data()
        signatureRSV.append(sig.r)
        signatureRSV.append(sig.s)
        signatureRSV.append(sig.v)
        _ = feeLimitSun  // reserved for TRC-20 hardware path; native uses bandwidth/energy
        return TronUnsignedAndSignature(
            envelopeJSON: unsigned.envelopeJSON,
            signatureRSV: signatureRSV
        )
    }

    /// Carries the createtransaction envelope + the Ledger
    /// signature from `signNativeTransferOnHardware` to the
    /// broadcast call. The send view holds this on its `.signed`
    /// state so the user can review before broadcasting.
    struct TronUnsignedAndSignature: Sendable {
        let envelopeJSON: String
        let signatureRSV: Data
    }

    /// Shared block-header construction so both native + TRC-20
    /// signers populate the same fields.
    static func makeBlockHeader(_ ref: TronBlockRef) -> WalletCore.TronBlockHeader {
        var header = WalletCore.TronBlockHeader()
        header.timestamp = ref.timestamp
        header.txTrieRoot = ref.txTrieRoot
        header.parentHash = ref.parentHash
        header.number = ref.number
        header.witnessAddress = ref.witnessAddress
        header.version = ref.version
        return header
    }
}
