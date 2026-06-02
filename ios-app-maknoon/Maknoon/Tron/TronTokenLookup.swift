// Auto-detect TRC-20 token metadata from a contract address by
// reading `name()`, `symbol()`, and `decimals()` via TronGrid's
// `triggerConstantContract`. Mirrors `EthereumTokenLookup` since
// TRC-20 follows the same ERC-20 ABI shape on the wire (Tron's VM
// is EVM-derived). Returns nil if the contract isn't a TRC-20, so
// the caller can fall back to the manual path.

import Foundation

struct TRC20Metadata: Sendable, Hashable {
    let symbol: String
    let name: String
    let decimals: Int
}

enum TronTokenLookup {

    /// Hit the configured TronGrid endpoint for all three reads in
    /// parallel. Tron's response format is the same ABI hex as
    /// Ethereum's `eth_call`, so we re-use `EthereumABI.parseSymbol`
    /// and `EthereumABI.parseDecimals` for the decode.
    static func fetch(contract: String, rpcURL: String, ownerAddressBase58: String? = nil) async -> TRC20Metadata? {
        guard let rpc = TronRPCClient(baseString: rpcURL) else { return nil }
        // TronGrid requires an owner_address even for read-only
        // calls. A throwaway sentinel that's a valid base58 address
        // works because `triggerConstantContract` doesn't actually
        // touch the caller's account. If the caller has a wallet
        // address handy (the user's wallet), it's slightly cleaner
        // to use that.
        let owner = ownerAddressBase58 ?? "T9yD14Nj9j7xAB4dbGeiX9h8unkKLxmGkn"
        async let sym = try? rpc.triggerConstantContract(
            ownerAddressBase58: owner,
            contractAddressBase58: contract,
            functionSelector: "symbol()",
            parameterHex: ""
        )
        async let dec = try? rpc.triggerConstantContract(
            ownerAddressBase58: owner,
            contractAddressBase58: contract,
            functionSelector: "decimals()",
            parameterHex: ""
        )
        async let nm = try? rpc.triggerConstantContract(
            ownerAddressBase58: owner,
            contractAddressBase58: contract,
            functionSelector: "name()",
            parameterHex: ""
        )
        let (sHex, dHex, nHex) = await (sym, dec, nm)
        guard let sHex, let symbol = EthereumABI.parseSymbol(sHex), !symbol.isEmpty,
              let dHex, let decimals = EthereumABI.parseDecimals(dHex)
        else { return nil }
        let name: String = {
            if let nHex, let n = EthereumABI.parseSymbol(nHex), !n.isEmpty { return n }
            return symbol
        }()
        return TRC20Metadata(symbol: symbol, name: name, decimals: decimals)
    }
}
