// Per-chain payment-request URIs for the POS "receive" QR.
//
// The customer scans this with their own wallet and pays from there, so we
// emit the de-facto standard each chain's wallets understand:
//   * EVM     EIP-681   ethereum:<addr>@<chainId>?value=<wei>
//   * Bitcoin BIP21     bitcoin:<addr>?amount=<btc>[&label=]
//   * Solana  Solana Pay solana:<addr>?amount=<sol>[&label=]
//   * Tron    (de-facto) tron:<addr>?amount=<trx>   (best-effort; no formal std)
//
// Amounts are carried in each chain's human unit except EVM, where EIP-681
// puts the value in wei. The native-coin value never includes token logic
// (POS receive is native-coin only for now).

import Foundation

enum PaymentURI: Equatable {
    /// EVM: `value` is the amount in wei (decimal integer string).
    case ethereum(address: String, chainId: UInt64, weiValue: String?)
    /// Bitcoin: amount in BTC.
    case bitcoin(address: String, btc: Decimal?)
    /// Solana: amount in SOL.
    case solana(address: String, sol: Decimal?)
    /// Tron: amount in TRX.
    case tron(address: String, trx: Decimal?)

    var string: String {
        switch self {
        case let .ethereum(address, chainId, weiValue):
            var uri = "ethereum:\(address)@\(chainId)"
            if let wei = weiValue, !wei.isEmpty, wei != "0" {
                uri += "?value=\(wei)"
            }
            return uri
        case let .bitcoin(address, btc):
            var uri = "bitcoin:\(address)"
            if let amt = positiveAmount(btc) { uri += "?amount=\(amt)" }
            return uri
        case let .solana(address, sol):
            var uri = "solana:\(address)"
            if let amt = positiveAmount(sol) { uri += "?amount=\(amt)" }
            return uri
        case let .tron(address, trx):
            var uri = "tron:\(address)"
            if let amt = positiveAmount(trx) { uri += "?amount=\(amt)" }
            return uri
        }
    }

    /// Format a positive decimal without exponent/trailing noise; nil if the
    /// amount is nil or <= 0 (an amount-less request is a bare address QR).
    private func positiveAmount(_ d: Decimal?) -> String? {
        guard let d, d > 0 else { return nil }
        var value = d
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 18, .plain)
        let s = NSDecimalNumber(decimal: rounded).stringValue
        return s
    }
}
