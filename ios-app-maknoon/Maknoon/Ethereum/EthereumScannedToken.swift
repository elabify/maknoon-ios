// Decide what a scanned EIP-681 token-payment QR means for THIS wallet on THIS
// chain. Pure and unit-testable: the send view does the RPC probing, this file
// only classifies.
//
// The case that forced this to exist: a Coinbase Arbitrum deposit QR requests
// bridged USDC.e (0xff97…5cc8) while the wallet holds native USDC
// (0xaf88…5831). Both contracts return symbol() == "USDC" on chain, so symbol
// alone cannot tell them apart and the UI must always show the contract too.
// Matching the contract strictly is correct (they really are different tokens,
// and a payee may credit only one of them), but dead-ending there is not: the
// wallet can offer the token it holds and let the user decide.
//
// Deliberately NOT a silent substitution. `sameSymbolCandidates` is a prompt,
// never an auto-selection.

import Foundation

enum EthereumScannedTokenMatch: Equatable {
    /// The wallet already has this exact contract on this chain: apply the QR
    /// with no questions asked (today's happy path).
    case alreadyAdded(EthereumToken)
    /// The contract is absent, but the wallet holds one or more tokens whose
    /// symbol matches what the contract reports. The user picks.
    case sameSymbolCandidates([EthereumToken])
    /// The contract is absent and nothing in the wallet resembles it. The only
    /// path forward is adding the probed contract.
    case unknown
}

enum EthereumScannedToken {

    /// - requestedContract: the URI target (the ERC-20 contract) from the QR.
    /// - requestedSymbol: `symbol()` read from that contract, or nil when the
    ///   probe has not run or failed. Without it there is nothing to match a
    ///   same-symbol candidate against, so the result can only be
    ///   `.alreadyAdded` or `.unknown`.
    /// - added: every token configured for this (wallet, chain).
    static func resolve(
        requestedContract: String,
        requestedSymbol: String?,
        added: [EthereumToken]
    ) -> EthereumScannedTokenMatch {
        let needle = requestedContract.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .unknown }
        if let exact = added.first(where: { $0.contractAddress.lowercased() == needle }) {
            return .alreadyAdded(exact)
        }
        guard let symbol = requestedSymbol?.trimmingCharacters(in: .whitespacesAndNewlines),
              !symbol.isEmpty
        else { return .unknown }
        let candidates = added.filter {
            $0.contractAddress.lowercased() != needle
                && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
        }
        return candidates.isEmpty ? .unknown : .sameSymbolCandidates(candidates)
    }
}
