// Self-send detection: is the recipient one of this wallet's own addresses for
// the selected network. Pure and unit-testable.
//
// Sending to your own address is not fund loss, but on account-model chains it
// is almost always a mistake (a paste of your own address instead of the payee)
// and on Tron a self-transfer is rejected on-chain and just burns the fee. The
// send screens use this to warn-and-confirm (Ethereum, Solana) or hard-block
// (Tron). Bitcoin is intentionally not covered: a UTXO wallet has many derived
// addresses and sending to your own address (consolidation / change) is normal.

import Foundation

enum SelfSendGuard {
    /// True when `recipient` equals one of `ownAddresses`. `caseInsensitive` is
    /// used for hex (Ethereum) addresses where case is not significant; base58
    /// networks (Solana, Tron) compare exactly. Empty recipient -> false.
    static func isSelfSend(recipient: String, ownAddresses: [String], caseInsensitive: Bool) -> Bool {
        let r = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return false }
        let target = caseInsensitive ? r.lowercased() : r
        return ownAddresses.contains {
            let own = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return caseInsensitive ? own.lowercased() == target : own == target
        }
    }
}
