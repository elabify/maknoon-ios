// Thin Solana JSON-RPC client. Phase B1 surface:
//   - getBalance              (lamports for an address)
//   - getLatestBlockhash      (needed by the tx builder)
//   - sendTransaction         (broadcast a base64 signed tx)
//   - getSignatureStatuses    (poll a freshly-broadcast signature)
//   - getSignaturesForAddress (cheap pagination of recent activity)
//   - getTransaction          (per-signature detail for the tx-list)
//
// Following the chain plan: no third-party Swift package; we hand-roll
// the JSON envelopes (Solana JSON-RPC is exhaustively documented at
// https://docs.solana.com/api/http). One URLSession per client so we
// can pin or proxy per-instance later without touching call sites.

import Foundation

enum SolanaRPCError: LocalizedError {
    case badURL(String)
    case transport(String)
    case decode(String)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):       return "Invalid Solana RPC URL: \(s)"
        case .transport(let m):    return "Solana RPC transport error: \(m)"
        case .decode(let m):       return "Solana RPC decode error: \(m)"
        case .rpc(let c, let m):   return "Solana RPC error \(c): \(m)"
        }
    }
}

/// One RPC client per (network, endpoint URL). Stateless beyond the
/// session; safe to recreate per call if endpoint changes.
struct SolanaRPCClient: Sendable {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    init?(urlString: String, session: URLSession = .shared) {
        guard let url = URL(string: urlString) else { return nil }
        self.init(endpoint: url, session: session)
    }

    // MARK: -- public methods

    /// Returns lamports (UInt64). 1 SOL = 10^9 lamports.
    func getBalance(address: String) async throws -> UInt64 {
        struct Result: Decodable { let value: UInt64 }
        let r: Result = try await call(method: "getBalance", params: [.string(address)])
        return r.value
    }

    /// Returns the most recent blockhash as base58 plus the slot it's
    /// valid until. Solana transactions are rejected if their
    /// blockhash is older than ~150 slots.
    struct LatestBlockhash: Decodable, Sendable {
        let blockhash: String
        let lastValidBlockHeight: UInt64
    }
    func getLatestBlockhash() async throws -> LatestBlockhash {
        struct Result: Decodable { let value: LatestBlockhash }
        let r: Result = try await call(method: "getLatestBlockhash", params: [])
        return r.value
    }

    /// Broadcast a signed transaction. `signedBase64` is what
    /// `SolanaDescriptors.signTransferFromSandwich(...)` returns.
    /// Returns the signature (base58) which is the canonical tx id
    /// on Solana.
    func sendTransaction(signedBase64: String) async throws -> String {
        let opts = JSONRPCParam.object([
            "encoding": .string("base64"),
            "skipPreflight": .bool(false),
            "preflightCommitment": .string("processed"),
        ])
        let signature: String = try await callRaw(
            method: "sendTransaction",
            params: [.string(signedBase64), opts]
        )
        return signature
    }

    /// Poll signature statuses for one or more signatures. Returns
    /// the per-signature status (nil if the network hasn't seen it
    /// yet). Used by the send-flow state machine to surface
    /// confirmation progress.
    struct SignatureStatus: Decodable, Sendable {
        let slot: UInt64
        let confirmations: UInt64?
        let confirmationStatus: String?
        let err: AnyJSONValue?
    }
    func getSignatureStatuses(_ signatures: [String]) async throws -> [SignatureStatus?] {
        struct Result: Decodable { let value: [SignatureStatus?] }
        let r: Result = try await call(
            method: "getSignatureStatuses",
            params: [.array(signatures.map { .string($0) })]
        )
        return r.value
    }

    /// Pagination-friendly recent signatures for `address`. The
    /// dashboard's "Recent transactions" list pages through this.
    /// `before` and `until` are signature cursors; `limit` defaults
    /// to 20.
    struct SignatureRecord: Decodable, Sendable {
        let signature: String
        let slot: UInt64
        let blockTime: Int64?
        let memo: String?
        let err: AnyJSONValue?
        let confirmationStatus: String?
    }
    func getSignaturesForAddress(
        _ address: String,
        before: String? = nil,
        until: String? = nil,
        limit: Int = 20
    ) async throws -> [SignatureRecord] {
        var options: [String: JSONRPCParam] = [
            "limit": .int(limit),
        ]
        if let before { options["before"] = .string(before) }
        if let until  { options["until"]  = .string(until) }
        let r: [SignatureRecord] = try await callRaw(
            method: "getSignaturesForAddress",
            params: [.string(address), .object(options)]
        )
        return r
    }

    /// SOL delta for an owner inside a single transaction. Negative
    /// = sent, positive = received, zero = passthrough or fee-only.
    /// Computed from the transaction's pre/post balance arrays at the
    /// owner's account-key index.
    struct TransactionDelta: Sendable {
        /// Signed lamport delta. Includes the network fee on the
        /// outgoing leg (the signer always pays the fee).
        let lamports: Int64
        /// Lamport fee burnt by this transaction. Useful for showing
        /// "of which X SOL fee" if we ever want to.
        let feeLamports: UInt64
        /// True iff the transaction errored on-chain (still consumed
        /// the fee). Rows surface this as "Failed".
        let isError: Bool
    }

    /// Fetch a single transaction's SOL delta for `ownerAddress`.
    /// Returns nil when the transaction is missing or hasn't propagated
    /// yet, so the row can fall back to "-".
    func getTransactionDelta(
        signature: String,
        ownerAddress: String
    ) async throws -> TransactionDelta? {
        // `getTransaction` is one of the few Solana RPC methods whose
        // result is NOT wrapped in `{ context, value }`; it returns the
        // transaction directly. Reflect that in the response shape.
        struct ResponseRoot: Decodable {
            let slot: UInt64
            let meta: Meta?
            let transaction: Transaction
            struct Meta: Decodable {
                let fee: UInt64
                let preBalances: [UInt64]
                let postBalances: [UInt64]
                let err: AnyJSONValue?
            }
            struct Transaction: Decodable {
                let message: Message
                struct Message: Decodable {
                    let accountKeys: [String]
                }
            }
        }
        let cfg = JSONRPCParam.object([
            "encoding": .string("json"),
            "maxSupportedTransactionVersion": .int(0),
            "commitment": .string("confirmed"),
        ])
        let root: ResponseRoot?
        do {
            root = try await callRaw(
                method: "getTransaction",
                params: [.string(signature), cfg]
            )
        } catch SolanaRPCError.decode {
            return nil
        }
        guard let root, let meta = root.meta else { return nil }
        guard let idx = root.transaction.message.accountKeys.firstIndex(of: ownerAddress) else {
            return nil
        }
        guard idx < meta.preBalances.count, idx < meta.postBalances.count else {
            return nil
        }
        let pre = Int64(bitPattern: meta.preBalances[idx])
        let post = Int64(bitPattern: meta.postBalances[idx])
        let delta = post - pre
        let isError: Bool = {
            guard let raw = meta.err else { return false }
            return !raw.isNull
        }()
        return TransactionDelta(
            lamports: delta,
            feeLamports: meta.fee,
            isError: isError
        )
    }

    // MARK: -- SPL token methods

    /// Single SPL token holding for a wallet, returned by
    /// `getTokenAccountsByOwner` (jsonParsed encoding). Each token
    /// account holds exactly one SPL mint, owned by the wallet's
    /// system-account address. Wallets that hold multiple mints
    /// have one entry per mint.
    struct TokenAccount: Sendable {
        /// Base58 mint pubkey (the token's identity).
        let mint: String
        /// Raw on-chain amount (integer). Apply `decimals` to display.
        let amount: UInt64
        let decimals: UInt8
        /// Base58 token-account pubkey (the PDA holding this balance).
        /// Needed for transfer instructions as the source account.
        let tokenAccountPubkey: String
    }

    /// Walk every SPL token account the wallet owns. Filtered to the
    /// SPL Token Program (TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA)
    /// to match the canonical fungible-token program; Token-2022 is
    /// not yet included in the auto-discover pass.
    func getTokenAccountsByOwner(ownerAddress: String) async throws -> [TokenAccount] {
        // Token Program ID. Token-2022 has its own program id and is
        // intentionally excluded here; the auto-discover trust model
        // covers standard SPL only for v1.
        let programId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        let filter = JSONRPCParam.object(["programId": .string(programId)])
        let cfg = JSONRPCParam.object(["encoding": .string("jsonParsed")])
        struct Parsed: Decodable {
            struct Account: Decodable {
                struct Data: Decodable {
                    struct Parsed: Decodable {
                        struct Info: Decodable {
                            struct Amount: Decodable {
                                let amount: String
                                let decimals: UInt8
                            }
                            let mint: String
                            let tokenAmount: Amount
                        }
                        let info: Info
                    }
                    let parsed: Parsed
                }
                let data: Data
            }
            let pubkey: String
            let account: Account
        }
        struct Result: Decodable { let value: [Parsed] }
        let r: Result = try await call(
            method: "getTokenAccountsByOwner",
            params: [.string(ownerAddress), filter, cfg]
        )
        return r.value.compactMap { p -> TokenAccount? in
            guard let amount = UInt64(p.account.data.parsed.info.tokenAmount.amount) else {
                return nil
            }
            return TokenAccount(
                mint: p.account.data.parsed.info.mint,
                amount: amount,
                decimals: p.account.data.parsed.info.tokenAmount.decimals,
                tokenAccountPubkey: p.pubkey
            )
        }
    }

    /// Fetch the balance of a specific SPL token account. Used when
    /// the dashboard wants to refresh a single token row without
    /// re-walking every owned account.
    func getTokenAccountBalance(tokenAccountPubkey: String) async throws -> (amount: UInt64, decimals: UInt8) {
        struct Inner: Decodable {
            let amount: String
            let decimals: UInt8
        }
        struct Result: Decodable { let value: Inner }
        let r: Result = try await call(
            method: "getTokenAccountBalance",
            params: [.string(tokenAccountPubkey)]
        )
        guard let parsed = UInt64(r.value.amount) else {
            throw SolanaRPCError.decode("getTokenAccountBalance: amount not an integer")
        }
        return (parsed, r.value.decimals)
    }

    /// Whether an account exists on chain. Used by the SPL transfer
    /// builder to decide if the recipient already has an Associated
    /// Token Account for the mint, or if the tx needs to prepend a
    /// `CreateAssociatedTokenAccount` instruction first.
    func accountExists(address: String) async throws -> Bool {
        struct Result: Decodable {
            let value: AnyJSONValue?
        }
        let cfg = JSONRPCParam.object(["encoding": .string("base64")])
        let r: Result = try await call(
            method: "getAccountInfo",
            params: [.string(address), cfg]
        )
        // value is null for missing accounts; non-null when present.
        return r.value != nil && r.value?.isNull == false
    }

    /// SPL Mint account metadata as returned by `getAccountInfo`
    /// with `encoding: "jsonParsed"`. The RPC pre-parses the SPL
    /// Token program account layout for us, so the user gets the
    /// mint's `decimals` (1 byte at offset 44 in the raw account
    /// data) without us doing the base64 + manual layout decode.
    /// Returns nil when the address does not exist or is not a
    /// `spl-token` mint account.
    struct ParsedMint: Sendable, Decodable {
        let decimals: UInt8
        let supplyRaw: String
    }
    func getParsedMint(address: String) async throws -> ParsedMint? {
        struct Envelope: Decodable {
            let value: Inner?
            struct Inner: Decodable {
                let data: DataField
                struct DataField: Decodable {
                    let parsed: Parsed
                    let program: String
                    struct Parsed: Decodable {
                        let type: String
                        let info: Info
                        struct Info: Decodable {
                            let decimals: UInt8
                            let supply: String
                        }
                    }
                }
            }
        }
        let cfg = JSONRPCParam.object(["encoding": .string("jsonParsed")])
        do {
            let env: Envelope = try await call(
                method: "getAccountInfo",
                params: [.string(address), cfg]
            )
            guard let inner = env.value,
                  inner.data.program == "spl-token",
                  inner.data.parsed.type == "mint"
            else { return nil }
            return ParsedMint(
                decimals: inner.data.parsed.info.decimals,
                supplyRaw: inner.data.parsed.info.supply
            )
        } catch {
            // The RPC returns a structured error if the account
            // exists but isn't a jsonParsed-known program; surface
            // as nil so the caller falls back to manual entry.
            return nil
        }
    }

    // MARK: -- envelope

    private func call<T: Decodable>(method: String, params: [JSONRPCParam]) async throws -> T {
        // Solana JSON-RPC `result` for most methods is a wrapper of
        // shape `{ context: { slot }, value: <T> }`. The single-shot
        // `call` helper expects the caller's `T` to model that
        // wrapper (e.g. `struct Result { let value: UInt64 }`).
        try await callRaw(method: method, params: params)
    }

    private func callRaw<T: Decodable>(method: String, params: [JSONRPCParam]) async throws -> T {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope = JSONRPCRequest(jsonrpc: "2.0", id: 1, method: method, params: params)
        do {
            req.httpBody = try JSONEncoder().encode(envelope)
        } catch {
            throw SolanaRPCError.decode("encode params: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SolanaRPCError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw SolanaRPCError.transport("HTTP \(http.statusCode)")
        }

        do {
            let env = try JSONDecoder().decode(JSONRPCEnvelope<T>.self, from: data)
            if let err = env.error {
                throw SolanaRPCError.rpc(code: err.code, message: err.message)
            }
            guard let r = env.result else {
                throw SolanaRPCError.decode("empty result for method \(method)")
            }
            return r
        } catch let e as SolanaRPCError {
            throw e
        } catch {
            throw SolanaRPCError.decode("\(method): \(error.localizedDescription)")
        }
    }
}

// MARK: -- JSON-RPC primitives

/// A parameter value for a JSON-RPC call. Mirrors the small subset of
/// JSON shapes Solana methods accept (string, int, bool, array,
/// object). Lets us build typed param lists without descending into
/// Any.
indirect enum JSONRPCParam: Encodable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONRPCParam])
    case object([String: JSONRPCParam])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let n):    try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

private struct JSONRPCRequest: Encodable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [JSONRPCParam]
}

private struct JSONRPCEnvelope<R: Decodable>: Decodable {
    let result: R?
    let error: RPCError?
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }
}

/// Catch-all for fields whose shape varies by error case. Used for
/// the `err` field on getSignatureStatuses / getSignaturesForAddress
/// where Solana returns either `null` or a heterogeneous structured
/// error object we don't want to model exhaustively.
struct AnyJSONValue: Decodable, Sendable, Hashable {
    let isNull: Bool
    let raw: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.isNull = true; self.raw = nil; return }
        self.isNull = false
        if let s = try? c.decode(String.self) {
            self.raw = s
        } else if let n = try? c.decode(Double.self) {
            self.raw = String(n)
        } else if let b = try? c.decode(Bool.self) {
            self.raw = String(b)
        } else {
            // Object or array: re-encode for display. Cheap enough
            // for the few cases this hits.
            let data = try JSONSerialization.data(withJSONObject: [:], options: [])
            self.raw = String(data: data, encoding: .utf8)
        }
    }
}
