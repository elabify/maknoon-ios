// Bitcoin on-chain payment leg for Maknoon Pay (ADR-0031), the twin of the EVM
// / Solana / Tron legs. Native BTC only, software wallets only (Bitcoin
// hardware commerce is a later add). BDK builds + signs a PSBT; the finalized
// transaction's txid is deterministic and known BEFORE broadcast, so the
// commerce flow posts identity + the txid ref first, then broadcasts.
//
// The build + SIGN happen through BitcoinWallet + BitcoinSigningHelpers (they
// own the sandwich + the BDK descriptor); this facade adds the BTC->sats parse,
// the pre-broadcast txid extraction, and a standalone Electrum broadcast.

import BitcoinDevKit
import Foundation

enum CommerceBitcoinPaymentError: LocalizedError {
    case badAmount(String)

    var errorDescription: String? {
        switch self {
        case .badAmount(let s): return "Payment amount is not valid: \(s)"
        }
    }
}

enum CommerceBitcoinPayment {

    /// BTC decimal amount -> integer satoshis (8 decimals), no floating point.
    static func satsFromBTC(_ amount: String) throws -> UInt64 {
        let parts = amount.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.first.map(String.init) ?? "0"
        var frac = parts.count > 1 ? String(parts[1]) : ""
        guard intPart.allSatisfy(\.isNumber), frac.allSatisfy(\.isNumber) else {
            throw CommerceBitcoinPaymentError.badAmount(amount)
        }
        let decimals = 8
        if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        frac = frac.padding(toLength: decimals, withPad: "0", startingAt: 0)
        let combined = (intPart + frac).drop(while: { $0 == "0" })
        let s = combined.isEmpty ? "0" : String(combined)
        guard let v = UInt64(s), v > 0 else {
            throw CommerceBitcoinPaymentError.badAmount(amount)
        }
        return v
    }

    /// Open the (software) wallet, sync its UTXO set, build the unsigned PSBT,
    /// sign it with the sandwich, and return the signed PSBT base64 + the
    /// pre-broadcast txid. `@MainActor` because the software signer derives the
    /// seed (biometric) on the main actor.
    @MainActor
    static func buildSignedTransfer(
        descriptor: BitcoinWalletDescriptor,
        sandwich: IdentitySandwich,
        account: UInt32,
        recipient: String,
        amountSat: UInt64,
        feeRateSatsPerVb: UInt64,
        electrumURL: String
    ) async throws -> (signed: String, txid: String) {
        let wallet = try BitcoinWallet.open(descriptor: descriptor, sandwich: sandwich)
        // Ensure the BDK wallet knows its UTXOs before building the spend.
        try await wallet.sync(electrumURL: electrumURL)
        let unsigned = try await wallet.buildUnsignedPSBT(
            toAddressString: recipient,
            amountSat: amountSat,
            feeRateSatsPerVb: feeRateSatsPerVb,
            enableRbf: true,
            selectedUtxoOutpoints: nil
        )
        let signed = try BitcoinSigningHelpers.signSoftware(
            unsignedBase64: unsigned,
            sandwich: sandwich,
            account: account,
            network: descriptor.network
        )
        let txid = try Self.txid(fromSignedPSBT: signed)
        return (signed, txid)
    }

    /// Open + sync the (hardware / watch-only) wallet and build the unsigned
    /// PSBT for a hardware signer. Hardware wallets open watch-only from the
    /// cached xpub, so no sandwich is needed.
    @MainActor
    static func buildUnsignedForHardware(
        descriptor: BitcoinWalletDescriptor,
        recipient: String,
        amountSat: UInt64,
        feeRateSatsPerVb: UInt64,
        electrumURL: String
    ) async throws -> String {
        let wallet = try BitcoinWallet.open(descriptor: descriptor, sandwich: nil)
        try await wallet.sync(electrumURL: electrumURL)
        return try await wallet.buildUnsignedPSBT(
            toAddressString: recipient,
            amountSat: amountSat,
            feeRateSatsPerVb: feeRateSatsPerVb,
            enableRbf: true,
            selectedUtxoOutpoints: nil
        )
    }

    /// Finalize a signed PSBT into its transaction. Software signing already
    /// finalizes (`extractTx` works directly); hardware signers (Ledger/Trezor)
    /// return partial sigs, so we combine with the original unsigned PSBT and
    /// finalize (mirrors BitcoinWallet.importSignedPSBTAndBroadcast).
    private static func finalizedTx(signedB64: String, unsignedB64: String?) throws -> Transaction {
        let psbt = try Psbt(psbtBase64: signedB64)
        let inputs = psbt.input()
        let allFinalized = !inputs.isEmpty && inputs.allSatisfy {
            $0.finalScriptWitness != nil || $0.finalScriptSig != nil
        }
        if allFinalized {
            return try psbt.extractTx()
        }
        var merged = psbt
        if let unsignedB64 {
            merged = try psbt.combine(other: try Psbt(psbtBase64: unsignedB64))
        }
        let finalized = merged.finalize()
        guard finalized.couldFinalize else {
            let errs = (finalized.errors ?? []).map { "\($0)" }.joined(separator: "; ")
            throw CommerceBitcoinPaymentError.badAmount("PSBT could not be finalized. \(errs)")
        }
        return try finalized.psbt.extractTx()
    }

    /// Deterministic txid, derivable before broadcast so the merchant gets the
    /// settlement ref first. `unsignedB64` is needed only for hardware-signed
    /// PSBTs that still need finalizing.
    static func txid(fromSignedPSBT signedB64: String, unsignedPSBT unsignedB64: String? = nil) throws -> String {
        String(describing: try finalizedTx(signedB64: signedB64, unsignedB64: unsignedB64).computeTxid())
    }

    /// Broadcast the signed PSBT over Electrum off the main actor; returns the
    /// txid (hex). Standalone (no BitcoinWallet instance). `unsignedB64` lets a
    /// hardware-signed (not-yet-finalized) PSBT finalize the same way the txid
    /// was derived, so the broadcast txid matches the ref posted to the merchant.
    static func broadcast(_ signedB64: String, unsignedB64: String? = nil, electrumURL: String) async throws -> String {
        try await Task.detached {
            let tx = try finalizedTx(signedB64: signedB64, unsignedB64: unsignedB64)
            let client = try ElectrumClient(url: electrumURL, socks5: nil)
            return String(describing: try client.transactionBroadcast(tx: tx))
        }.value
    }
}
