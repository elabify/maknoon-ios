// Solana payment leg for Maknoon Pay (ADR-0031), the Solana twin of
// CommerceEVMPayment. The holder signs a native SOL or SPL-token transfer
// WITHOUT broadcasting, so the commerce flow can post the identity + the
// settlement ref FIRST and only then broadcast (identity-first ordering).
//
// Thin orchestrator over the existing Solana send primitives so there is one
// signing path:
//   - SolanaRPCClient                       (latest blockhash, ATA probe, send)
//   - SolanaDescriptors.signTransferFromSandwich   (native SOL, software)
//   - SolanaSPLTransferBuilder.sign                (SPL token, software; ATA-aware)
// P1: software wallets only (the holder's consumer sandwich). Hardware Solana
// commerce is a later add.

import Foundation
import WalletCore

enum CommerceSolanaPayment {
    enum Failure: LocalizedError {
        case badAmount
        case badRPCURL
        case noSignature
        var errorDescription: String? {
            switch self {
            case .badAmount: return "Payment amount is not a positive number."
            case .badRPCURL: return "The network RPC URL is invalid."
            case .noSignature: return "Could not read the transaction signature."
            }
        }
    }

    /// Parse a decimal amount string into integer base units (lamports / token
    /// base units) WITHOUT floating point, so 0.1 SOL is exactly 100_000_000.
    static func baseUnits(_ amount: String, decimals: Int) throws -> UInt64 {
        let parts = amount.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.isEmpty ? "0" : String(parts[0])
        var frac = parts.count > 1 ? String(parts[1]) : ""
        guard intPart.allSatisfy(\.isNumber), frac.allSatisfy(\.isNumber) else { throw Failure.badAmount }
        if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        while frac.count < decimals { frac += "0" }
        let combined = (intPart.isEmpty ? "0" : intPart) + frac
        guard let v = UInt64(combined), v > 0 else { throw Failure.badAmount }
        return v
    }

    /// The canonical Solana tx id = the first signature (base58), read from the
    /// signed wire tx BEFORE broadcast. Wire layout: shortvec(sigCount) then the
    /// 64-byte signatures. For our single-signer txs sigCount is 1.
    static func transactionSignature(signedBase64: String) -> String? {
        guard let data = Data(base64Encoded: signedBase64), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var idx = 0, count = 0, shift = 0
        while idx < bytes.count {
            let b = bytes[idx]; idx += 1
            count |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        guard count >= 1, bytes.count >= idx + 64 else { return nil }
        return Base58.encodeNoCheck(data: Data(bytes[idx ..< idx + 64]))
    }

    /// Sign a native SOL or SPL transfer (software). `mint == nil` -> native SOL
    /// (`decimals` ignored, 9 used); otherwise an SPL token at `mint`/`decimals`
    /// (the builder adds a create-ATA instruction when the recipient lacks one).
    /// Returns the signed base64 tx + its base58 signature ref, NOT broadcast.
    static func buildSignedTransfer(
        sandwich: IdentitySandwich,
        account: UInt32,
        rpcURLString: String,
        recipient: String,
        amount: String,
        mint: String?,
        decimals: Int,
        biometricReason: String
    ) async throws -> (signed: String, signature: String) {
        guard let url = URL(string: rpcURLString) else { throw Failure.badRPCURL }
        let rpc = SolanaRPCClient(endpoint: url)
        let bh = try await rpc.getLatestBlockhash()
        let signed: String
        if let mint, !mint.isEmpty {
            let raw = try baseUnits(amount, decimals: decimals)
            let ata = try SolanaSPLTransferBuilder.associatedTokenAddress(ownerBase58: recipient, mintBase58: mint)
            let hasATA = (try? await rpc.accountExists(address: ata)) ?? false
            signed = try SolanaSPLTransferBuilder.sign(
                sandwich: sandwich, account: account, mintBase58: mint, decimals: UInt8(decimals),
                rawAmount: raw, recipientOwnerBase58: recipient, recipientHasATA: hasATA,
                recentBlockhashBase58: bh.blockhash, priorityFeeMicroLamports: 0,
                biometricReason: biometricReason)
        } else {
            let lamports = try baseUnits(amount, decimals: 9)
            signed = try SolanaDescriptors.signTransferFromSandwich(
                sandwich: sandwich, account: account, recipientBase58: recipient, lamports: lamports,
                recentBlockhashBase58: bh.blockhash, priorityFeeMicroLamports: 0,
                biometricReason: biometricReason)
        }
        guard let sig = transactionSignature(signedBase64: signed) else { throw Failure.noSignature }
        return (signed, sig)
    }

    /// Broadcast the holder's signed transaction; returns the base58 signature.
    static func broadcast(_ signedBase64: String, rpcURLString: String) async throws -> String {
        guard let url = URL(string: rpcURLString) else { throw Failure.badRPCURL }
        return try await SolanaRPCClient(endpoint: url).sendTransaction(signedBase64: signedBase64)
    }
}
