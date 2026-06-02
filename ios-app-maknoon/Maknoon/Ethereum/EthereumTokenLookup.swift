// Auto-detect ERC-20 token metadata from just a contract address by
// calling the standard `name()`, `symbol()`, `decimals()` ABI
// methods via `eth_call`. Used by the AddTokenSheet to skip manual
// entry when the contract responds; falls back to the manual path
// if any call fails (legacy `bytes32` symbol contracts, proxies
// that don't implement the spec, etc.).

import Foundation

struct ERC20Metadata: Sendable, Hashable {
    let symbol: String
    let name: String
    let decimals: Int
}

enum EthereumTokenLookup {

    /// Hit the configured RPC for all three reads in parallel and
    /// reassemble. Returns nil if `decimals()` or `symbol()` both
    /// fail to decode (those two are the user-facing critical
    /// fields); `name` defaults to the symbol when only `name()`
    /// fails (rare; some ancient tokens shipped without it).
    static func fetch(contract: String, rpcURL: String) async -> ERC20Metadata? {
        guard let rpc = EthereumRPCClient(urlString: rpcURL) else { return nil }
        let symbolPayload = EthereumABI.symbolData()
        let decimalsPayload = EthereumABI.decimalsData()
        let namePayload = EthereumABI.nameData()
        async let symbolHex = try? rpc.ethCall(to: contract, data: symbolPayload)
        async let decimalsHex = try? rpc.ethCall(to: contract, data: decimalsPayload)
        async let nameHex = try? rpc.ethCall(to: contract, data: namePayload)
        let (sHex, dHex, nHex) = await (symbolHex, decimalsHex, nameHex)
        guard let sHex,
              let symbol = EthereumABI.parseSymbol(sHex),
              !symbol.isEmpty,
              let dHex,
              let decimals = EthereumABI.parseDecimals(dHex)
        else { return nil }
        let name: String = {
            if let nHex, let n = EthereumABI.parseSymbol(nHex), !n.isEmpty { return n }
            return symbol
        }()
        return ERC20Metadata(symbol: symbol, name: name, decimals: decimals)
    }
}
