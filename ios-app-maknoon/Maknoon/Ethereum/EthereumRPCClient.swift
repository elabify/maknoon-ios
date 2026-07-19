// Minimal JSON-RPC client for EVM chains. Phase 1 shipped read-only
// methods; Phase 2 adds the surface needed to send a transaction:
// transaction count (nonce), EIP-1559 fee oracle (feeHistory +
// maxPriorityFeePerGas), gas estimation, and broadcast.

import Foundation

struct EthereumRPCClient: Sendable {
    let url: URL

    init?(urlString: String) {
        guard let u = URL(string: urlString) else { return nil }
        self.url = u
    }

    enum Error: LocalizedError {
        case http(Int, String)
        case rpc(code: Int, message: String)
        case malformedResponse(String)
        var errorDescription: String? {
            switch self {
            case .http(let s, let body):
                return "HTTP \(s): \(body)"
            case .rpc(let c, let m):
                // JSON-RPC -32603 = internal error: the provider
                // accepted the request but their backend failed.
                // Almost always a provider-side issue. Common with
                // rate-limited free RPC endpoints. Point the user
                // at the workaround rather than the raw error.
                if c == -32603 {
                    return "RPC provider returned an internal error. This is usually a rate-limit or transient outage on the public endpoint. Try a different RPC URL under Settings → Networks → Ethereum."
                }
                return "RPC error \(c): \(m)"
            case .malformedResponse(let m):
                return "Malformed RPC response: \(m)"
            }
        }
    }

    // MARK: -- read methods

    func getBalance(_ address: String) async throws -> EthereumWeiValue {
        let hex: String = try await call(method: "eth_getBalance", params: [.string(address), .string("latest")])
        return try EthereumWeiValue(hex: hex)
    }

    func chainId() async throws -> UInt64 {
        let hex: String = try await call(method: "eth_chainId", params: [])
        return try parseUInt64(hex: hex)
    }

    func blockNumber() async throws -> UInt64 {
        let hex: String = try await call(method: "eth_blockNumber", params: [])
        return try parseUInt64(hex: hex)
    }

    /// Number of transactions sent from `address`, used as the nonce
    /// for the next send. `pending` includes mempool-only txs so we
    /// don't collide with anything we already broadcast.
    func transactionCount(_ address: String, block: String = "pending") async throws -> UInt64 {
        let hex: String = try await call(
            method: "eth_getTransactionCount",
            params: [.string(address), .string(block)]
        )
        return try parseUInt64(hex: hex)
    }

    /// Legacy gas price. We only use it as a fallback for chains where
    /// eth_maxPriorityFeePerGas isn't supported (rare on EIP-1559
    /// chains, but Polygon has been spotty historically).
    func gasPrice() async throws -> EthereumWeiValue {
        let hex: String = try await call(method: "eth_gasPrice", params: [])
        return try EthereumWeiValue(hex: hex)
    }

    /// EIP-1559 priority fee suggestion (the "tip"). All chains in
    /// our catalog support this since the merge.
    func maxPriorityFeePerGas() async throws -> EthereumWeiValue {
        let hex: String = try await call(method: "eth_maxPriorityFeePerGas", params: [])
        return try EthereumWeiValue(hex: hex)
    }

    /// Recent base-fee history. We use the `baseFeePerGas` array's
    /// last entry (next-block base fee) and ignore the reward arrays
    /// since maxPriorityFeePerGas is already a one-shot tip estimate.
    func nextBlockBaseFee() async throws -> EthereumWeiValue {
        let res: FeeHistoryResult = try await call(
            method: "eth_feeHistory",
            params: [.string("0x1"), .string("latest"), .array([])]
        )
        guard let last = res.baseFeePerGas.last else {
            throw Error.malformedResponse("empty baseFeePerGas in eth_feeHistory")
        }
        return try EthereumWeiValue(hex: last)
    }

    /// Estimate gas units for a transaction. Returns the upper-bound
    /// gas the node would charge; we pad it slightly in the send flow
    /// to absorb tip variance.
    func estimateGas(
        from: String,
        to: String,
        value: EthereumWeiValue,
        data: Data?
    ) async throws -> UInt64 {
        let call = EstimateGasCall(
            from: from,
            to: to,
            value: "0x" + value.hex,
            data: data.map { "0x" + $0.map { String(format: "%02x", $0) }.joined() }
        )
        let hex: String = try await self.call(
            method: "eth_estimateGas",
            params: [.object(call.asAnyDict()), .string("latest")]
        )
        return try parseUInt64(hex: hex)
    }

    /// Read-only contract call. Used for ERC-20 `balanceOf`,
    /// `symbol`, `decimals`. Returns the raw response bytes as a
    /// 0x-prefixed hex string; callers ABI-decode.
    func ethCall(to: String, data: Data, from: String? = nil, block: String = "latest") async throws -> String {
        let hexData = "0x" + data.map { String(format: "%02x", $0) }.joined()
        var call: [String: Param] = [
            "to":   .string(to),
            "data": .string(hexData),
        ]
        // Some reads depend on the caller: e.g. a Uniswap v4 Quoter simulates the
        // swap, so the pool's beforeSwap hook checks isAllowed(tx.origin); without
        // `from` the simulation sees address(0) and reverts.
        if let from { call["from"] = .string(from) }
        return try await self.call(
            method: "eth_call",
            params: [.object(call), .string(block)]
        )
    }

    /// Broadcast a fully signed transaction. Returns the tx hash.
    func sendRawTransaction(_ rawHex: String) async throws -> String {
        let hex = rawHex.hasPrefix("0x") ? rawHex : "0x" + rawHex
        return try await call(
            method: "eth_sendRawTransaction",
            params: [.string(hex)]
        )
    }

    /// Receipt of a mined transaction, including its event logs. Throws if the
    /// tx is unknown/pending (null result) — callers treat that as "unreadable".
    func getTransactionReceipt(_ txHash: String) async throws -> EthereumTxReceipt {
        let hex = txHash.hasPrefix("0x") ? txHash : "0x" + txHash
        return try await call(method: "eth_getTransactionReceipt", params: [.string(hex)])
    }

    // MARK: -- transport

    private func call<T: Decodable>(method: String, params: [Param]) async throws -> T {
        let body = RPCRequest(jsonrpc: "2.0", id: 1, method: method, params: params)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            LogStore.shared.error("eth.rpc", "\(method) at \(url.host ?? url.absoluteString): \(error.localizedDescription)")
            throw error
        }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let s = String(data: data, encoding: .utf8) ?? ""
            LogStore.shared.warn("eth.rpc", "\(method) http \(http.statusCode) at \(url.host ?? "?")")
            throw Error.http(http.statusCode, s)
        }
        let env = try JSONDecoder().decode(RPCEnvelope<T>.self, from: data)
        if let err = env.error {
            LogStore.shared.warn("eth.rpc", "\(method) rpc \(err.code) at \(url.host ?? "?"): \(err.message)")
            throw Error.rpc(code: err.code, message: err.message)
        }
        guard let res = env.result else {
            throw Error.malformedResponse("Neither result nor error in RPC envelope")
        }
        return res
    }

    private func parseUInt64(hex: String) throws -> UInt64 {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard let n = UInt64(s, radix: 16) else {
            throw Error.malformedResponse("Bad hex integer '\(hex)'")
        }
        return n
    }
}

// MARK: -- wire types

private struct RPCRequest: Encodable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [Param]
}

private struct RPCEnvelope<T: Decodable>: Decodable {
    let jsonrpc: String?
    let id: Int?
    let result: T?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}

/// eth_getTransactionReceipt result (only the fields we read).
struct EthereumTxReceipt: Decodable {
    let logs: [EthereumLog]
}

struct EthereumLog: Decodable {
    let address: String
    let topics: [String]
    let data: String
}

private struct FeeHistoryResult: Decodable {
    let oldestBlock: String
    let baseFeePerGas: [String]
    let gasUsedRatio: [Double]?
}

private struct EstimateGasCall {
    let from: String
    let to: String
    let value: String
    let data: String?
    func asAnyDict() -> [String: Param] {
        var d: [String: Param] = [
            "from": .string(from),
            "to":   .string(to),
            "value": .string(value),
        ]
        if let data { d["data"] = .string(data) }
        return d
    }
}

/// Heterogenous JSON-RPC param values. Phase 2 adds `.object` and
/// `.array` so we can encode `eth_estimateGas` (object) and
/// `eth_feeHistory` (array of percentiles).
enum Param: Encodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case object([String: Param])
    case array([Param])
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        }
    }
}
