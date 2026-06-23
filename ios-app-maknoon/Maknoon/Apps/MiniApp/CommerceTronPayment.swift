// Tron payment leg for Maknoon Pay (ADR-0031), the twin of the EVM / Solana
// legs. Native TRX + TRC-20, software wallets only (Tron hardware commerce is a
// later add). The signed transaction JSON carries the txID = sha256(raw_data),
// which is known BEFORE broadcast, so the commerce flow posts identity + the
// txID ref first, then broadcasts.
//
// The SIGN happens through TronWallet (it owns the sandwich + block ref);
// this facade holds the decimal parse, the txID extraction, and the broadcast.

import Foundation

enum CommerceTronPaymentError: LocalizedError {
    case badAmount(String)
    case noTxID

    var errorDescription: String? {
        switch self {
        case .badAmount(let s): return "Payment amount is not valid: \(s)"
        case .noTxID: return "Could not read the Tron transaction id from the signed transaction."
        }
    }
}

enum CommerceTronPayment {

    /// Decimal amount -> integer base units as a base-10 string (sun for TRX at
    /// 6 decimals, or the token's base units). String form avoids overflow on
    /// high-decimal tokens and is what TronTRC20TransferBuilder.sign expects.
    static func baseUnits(_ amount: String, decimals: Int) throws -> String {
        let parts = amount.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = parts.first.map(String.init) ?? "0"
        var frac = parts.count > 1 ? String(parts[1]) : ""
        guard intPart.allSatisfy(\.isNumber), frac.allSatisfy(\.isNumber) else {
            throw CommerceTronPaymentError.badAmount(amount)
        }
        if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        frac = frac.padding(toLength: decimals, withPad: "0", startingAt: 0)
        let combined = (intPart + frac).drop(while: { $0 == "0" })
        let s = combined.isEmpty ? "0" : String(combined)
        guard s != "0", s.allSatisfy(\.isNumber) else {
            throw CommerceTronPaymentError.badAmount(amount)
        }
        return s
    }

    /// Integer base units as Int64 (for native sun + sufficiency checks).
    static func baseUnitsInt64(_ amount: String, decimals: Int) throws -> Int64 {
        guard let v = Int64(try baseUnits(amount, decimals: decimals)) else {
            throw CommerceTronPaymentError.badAmount(amount)
        }
        return v
    }

    /// Pull the txID (hex) out of a Tron signed-transaction JSON so the merchant
    /// can be handed the settlement ref before the tx is broadcast.
    static func txID(fromSignedJSON signedJSON: String) throws -> String {
        guard let data = signedJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txID = obj["txID"] as? String, !txID.isEmpty
        else {
            throw CommerceTronPaymentError.noTxID
        }
        return txID
    }

    /// Splice an externally-produced 65-byte (R||S||V) signature into the
    /// createtransaction envelope JSON, producing the wire-ready signed
    /// transaction JSON (mirrors TronRPCClient.broadcastWithSignature's splice).
    /// Used for the hardware path, where the device returns the signature
    /// separately from the envelope; the signed JSON then broadcasts uniformly
    /// via `broadcast(_:rpcURLString:)`.
    static func assembleSignedJSON(envelopeJSON: String, signatureRSV: Data) throws -> String {
        guard signatureRSV.count == 65 else {
            throw CommerceTronPaymentError.noTxID
        }
        guard let data = envelopeJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              var signed = obj as? [String: Any]
        else {
            throw CommerceTronPaymentError.noTxID
        }
        signed["signature"] = [signatureRSV.map { String(format: "%02x", $0) }.joined()]
        let out = try JSONSerialization.data(withJSONObject: signed)
        return String(data: out, encoding: .utf8) ?? ""
    }

    /// Broadcast the holder's signed transaction JSON; returns the txid (hex).
    static func broadcast(_ signedJSON: String, rpcURLString: String) async throws -> String {
        guard let rpc = TronRPCClient(baseString: rpcURLString) else {
            throw TronRPCError.transport("Invalid Tron RPC URL")
        }
        return try await rpc.broadcastTransaction(signedJSON: signedJSON)
    }
}
