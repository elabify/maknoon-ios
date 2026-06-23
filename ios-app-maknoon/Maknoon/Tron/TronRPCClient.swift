// Thin TronGrid HTTP client. Tron's API isn't JSON-RPC; instead each
// method is its own POST endpoint under `/wallet/...` taking a JSON
// body and returning JSON. The methods exposed here are the
// dashboard-driver subset:
//
//   - getAccount        balance + bandwidth + frozen state for an address
//   - getNowBlock       latest block header (needed by the tx builder)
//   - broadcastTransaction
//   - getTransactionsByAddress  recent activity
//   - getAccountResource        bandwidth / energy (informational)
//   - triggerConstantContract   TRC-20 read calls (balanceOf, decimals...)
//
// One URLSession per client so a future pin-or-proxy doesn't touch
// call sites.

import Foundation
import WalletCore

enum TronRPCError: LocalizedError {
    case badURL(String)
    case transport(String)
    case decode(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):    return "Invalid Tron RPC URL: \(s)"
        case .transport(let m): return "Tron RPC transport error: \(m)"
        case .decode(let m):    return "Tron RPC decode error: \(m)"
        case .server(let m):    return "Tron RPC server error: \(m)"
        }
    }
}

struct TronRPCClient: Sendable {
    let base: URL
    private let session: URLSession

    init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    init?(baseString: String, session: URLSession = .shared) {
        guard let url = URL(string: baseString) else { return nil }
        self.init(base: url, session: session)
    }

    // MARK: -- account + balance

    struct AccountRecord: Decodable, Sendable {
        let balance: Int64?  // sun (1 TRX = 1_000_000)
        let address: String? // hex-prefixed (41...)
    }

    /// Sun balance for an address. Returns 0 for accounts that don't
    /// exist on chain yet (Tron treats unfunded addresses as
    /// implicitly zero, no need to surface "account not found").
    func getBalance(addressBase58: String) async throws -> Int64 {
        let body: [String: Any] = [
            "address": addressBase58,
            "visible": true,
        ]
        let record: AccountRecord = try await call(path: "/wallet/getaccount", body: body)
        return record.balance ?? 0
    }

    // MARK: -- block reference

    /// Latest block header. The Tron tx builder folds these fields
    /// into the transaction so the network accepts it.
    struct NowBlock: Sendable {
        let number: Int64
        let timestamp: Int64
        let parentHashHex: String
        let txTrieRootHex: String
        let witnessAddressHex: String
        let version: Int32
    }

    func getNowBlock() async throws -> NowBlock {
        // TronGrid mixes snake_case and camelCase keys inside the
        // same JSON envelope: `block_header` and `raw_data` are
        // snake_case, but most fields INSIDE raw_data are camelCase
        // EXCEPT `witness_address`, which is snake_case. We pin
        // every key with `CodingKeys` so a default JSONDecoder
        // (no snake_case strategy) finds them all, and tolerate
        // genesis/empty-block omissions by making `txTrieRoot` +
        // `witnessAddress` optional with empty-string defaults.
        struct Header: Decodable {
            struct RawData: Decodable {
                let number: Int64
                let timestamp: Int64
                let parentHash: String
                let txTrieRoot: String?
                let witnessAddress: String?
                let version: Int32?
                enum CodingKeys: String, CodingKey {
                    case number, timestamp, version
                    case parentHash, txTrieRoot
                    case witnessAddress = "witness_address"
                }
            }
            let rawData: RawData
            enum CodingKeys: String, CodingKey {
                case rawData = "raw_data"
            }
        }
        struct Block: Decodable {
            let blockHeader: Header
            enum CodingKeys: String, CodingKey {
                case blockHeader = "block_header"
            }
        }
        let block: Block = try await call(path: "/wallet/getnowblock", body: [:])
        let h = block.blockHeader.rawData
        return NowBlock(
            number: h.number,
            timestamp: h.timestamp,
            parentHashHex: h.parentHash,
            txTrieRootHex: h.txTrieRoot ?? "",
            witnessAddressHex: h.witnessAddress ?? "",
            version: h.version ?? 0
        )
    }

    // MARK: -- broadcast

    /// Broadcast a signed transaction JSON (the `json` field returned
    /// by TWC's `AnySigner.sign`). Returns the txid (hex) on
    /// success; throws a server error with TronGrid's `message` /
    /// `code` if the network rejected it.
    func broadcastTransaction(signedJSON: String) async throws -> String {
        guard let data = signedJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let body = obj as? [String: Any]
        else {
            throw TronRPCError.decode("signedJSON not parseable: \(signedJSON.prefix(80))")
        }
        struct Result: Decodable {
            let result: Bool?
            let txid: String?
            let message: String?
            let code: String?
        }
        let r: Result = try await call(path: "/wallet/broadcasttransaction", body: body)
        if let msg = r.message, r.result != true {
            // Tron returns `message` as hex when `code` is set;
            // decode best-effort so the user sees the human-readable
            // reason ("CONTRACT_VALIDATE_ERROR" + reason).
            let decoded = hexDecodeString(msg) ?? msg
            throw TronRPCError.server("[\(r.code ?? "?")] \(decoded)")
        }
        guard let txid = r.txid else {
            throw TronRPCError.decode("broadcastTransaction returned no txid")
        }
        return txid
    }

    // MARK: -- recent activity

    /// Recent transactions for an address. TronGrid's v1 endpoint is
    /// the cleanest paginated API; we ask for the most recent N.
    struct TxRecord: Decodable, Sendable, Hashable, Identifiable {
        let txID: String
        let blockTimestamp: Int64?
        let rawData: RawData?
        let ret: [Receipt]?
        var id: String { txID }
        struct Receipt: Decodable, Sendable, Hashable {
            let contractRet: String?  // "SUCCESS" / "REVERT" / "OUT_OF_ENERGY" etc.
        }
        struct RawData: Decodable, Sendable, Hashable {
            let contract: [Contract]?
        }
        struct Contract: Decodable, Sendable, Hashable {
            let type: String?
            let parameter: Parameter?
        }
        struct Parameter: Decodable, Sendable, Hashable {
            let value: ContractValue?
        }
        struct ContractValue: Decodable, Sendable, Hashable {
            let amount: Int64?
            let ownerAddress: String?
            let toAddress: String?
            let contractAddress: String?
            // ABI-encoded TRC-20 call payload. For
            // TriggerSmartContract this carries the function selector
            // + amount; we don't decode it inline (the dashboard
            // labels these as TRC-20 transfers and shows the
            // contract address).
            let data: String?
            enum CodingKeys: String, CodingKey {
                case amount, data
                case ownerAddress = "owner_address"
                case toAddress = "to_address"
                case contractAddress = "contract_address"
            }
        }
        enum CodingKeys: String, CodingKey {
            case txID, blockTimestamp = "block_timestamp", rawData = "raw_data", ret
        }

        // MARK: -- decoded display fields

        /// "SUCCESS" / "REVERT" / nil. Lifted off the first receipt.
        var contractStatus: String? { ret?.first?.contractRet }

        /// Tron contract type from the first contract entry. "TransferContract" for
        /// native TRX; "TriggerSmartContract" for TRC-20.
        var contractType: String? { rawData?.contract?.first?.type }

        /// The contract's first value object, the most useful shape
        /// for surfacing amount + counterparty.
        var contractValue: ContractValue? {
            rawData?.contract?.first?.parameter?.value
        }

        /// Native TRX amount in sun (1 TRX = 1_000_000 sun). nil
        /// when this isn't a TransferContract.
        var nativeSunAmount: Int64? {
            guard contractType == "TransferContract" else { return nil }
            return contractValue?.amount
        }
    }
    func getTransactionsByAddress(addressBase58: String, limit: Int = 20) async throws -> [TxRecord] {
        // TronGrid v1 path; visible address (base58) is preferred so
        // we don't have to lift the response into hex form.
        let url = base.appending(path: "/v1/accounts/\(addressBase58)/transactions")
            .appending(queryItems: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "only_confirmed", value: "true"),
            ])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        struct Envelope: Decodable {
            let data: [TxRecord]
        }
        let env: Envelope = try await rawGET(url: url)
        return env.data
    }

    // MARK: -- TRC-20 reads

    /// Read-only contract call (no on-chain state change). Used by
    /// the TRC-20 balance probe. Returns the raw hex-encoded return
    /// value; caller is responsible for ABI-decoding.
    func triggerConstantContract(
        ownerAddressBase58: String,
        contractAddressBase58: String,
        functionSelector: String,  // e.g. "balanceOf(address)"
        parameterHex: String        // ABI-encoded parameters, hex
    ) async throws -> String {
        let body: [String: Any] = [
            "owner_address": ownerAddressBase58,
            "contract_address": contractAddressBase58,
            "function_selector": functionSelector,
            "parameter": parameterHex,
            "visible": true,
        ]
        struct Result: Decodable {
            let constant_result: [String]?
            let result: ResultObj?
            struct ResultObj: Decodable {
                let result: Bool?
                let message: String?
            }
        }
        let r: Result = try await call(path: "/wallet/triggerconstantcontract", body: body)
        if let msg = r.result?.message, r.result?.result == false {
            let decoded = hexDecodeString(msg) ?? msg
            throw TronRPCError.server(decoded)
        }
        return r.constant_result?.first ?? ""
    }

    // MARK: -- hardware-sign helpers
    //
    // TWC's `TransactionCompiler.preImageHashes(.tron, ...)` returns
    // the SHA-256 hash of the raw_data, not the raw_data bytes, so
    // we can't use it for Ledger sign (the device expects the
    // protobuf bytes and hashes them internally). Instead we ask
    // TronGrid to build the canonical transaction and hand back
    // both the raw_data_hex (signed by the Ledger) and the JSON
    // envelope (broadcast after splicing the signature in).

    /// Server-built unsigned native TRX transfer. Returns the bytes
    /// the Ledger Tron app signs plus the JSON envelope to splice
    /// the signature into for broadcast.
    struct UnsignedTransaction {
        /// Raw protobuf bytes of `Transaction.raw_data`, what the
        /// Ledger SIGN APDU consumes.
        let rawData: Data
        /// Hex of `rawData`. Stored on the broadcast JSON's
        /// `raw_data_hex` field so the server doesn't re-derive it.
        let rawDataHex: String
        /// Original JSON envelope returned by `/wallet/createtransaction`,
        /// re-serialized as a string so it round-trips cleanly. The
        /// broadcast step rehydrates this, attaches `signature: […]`,
        /// and POSTs.
        let envelopeJSON: String
    }

    /// Build a server-side unsigned native TRX transfer via
    /// TronGrid's `/wallet/createtransaction`. The server picks the
    /// block ref + expiration; the caller decides only the actor +
    /// recipient + amount + (optional) fee limit.
    func createNativeTransaction(
        senderBase58: String,
        recipientBase58: String,
        sunAmount: Int64,
        feeLimitSun: Int64?
    ) async throws -> UnsignedTransaction {
        var body: [String: Any] = [
            "owner_address": senderBase58,
            "to_address": recipientBase58,
            "amount": sunAmount,
            "visible": true,
        ]
        if let feeLimitSun {
            body["fee_limit"] = feeLimitSun
        }
        try Task.checkCancellation()
        let url = base.appending(path: "/wallet/createtransaction")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TronRPCError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TronRPCError.transport("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let envelope = obj as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("createtransaction: not JSON. Raw: \(raw.prefix(200))")
        }
        // TronGrid surfaces input errors via `Error` (capital E) on
        // a 200 response; treat that as a server rejection rather
        // than a parse failure.
        if let errMsg = envelope["Error"] as? String {
            throw TronRPCError.server(errMsg)
        }
        guard let rawHex = envelope["raw_data_hex"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("createtransaction: missing raw_data_hex. Raw: \(raw.prefix(200))")
        }
        let rawBytes = decodeHex(rawHex)
        if rawBytes.isEmpty {
            throw TronRPCError.decode("createtransaction: raw_data_hex decoded to 0 bytes")
        }
        let envelopeJSON = String(data: data, encoding: .utf8) ?? ""
        return UnsignedTransaction(
            rawData: rawBytes,
            rawDataHex: rawHex,
            envelopeJSON: envelopeJSON
        )
    }

    /// Build a server-side unsigned TRC-20 token transfer via
    /// `/wallet/triggersmartcontract`. The server returns a
    /// `transaction.raw_data_hex` we can ship to the Ledger
    /// unchanged. Mirrors `createNativeTransaction` for the
    /// contract-call shape.
    ///
    /// `rawAmount` is the integer base-units value as a base-10
    /// string (TRC-20 amounts can exceed UInt64).
    func createTRC20Transaction(
        senderBase58: String,
        contractAddressBase58: String,
        recipientBase58: String,
        rawAmount: String,
        feeLimitSun: Int64
    ) async throws -> UnsignedTransaction {
        // ABI-encode `transfer(address,uint256)`. Selector + 32-byte
        // address (left-padded with the 0x41 byte stripped) + 32-byte
        // amount.
        let selector = "a9059cbb"  // keccak256("transfer(address,uint256)")[:4]
        let toHex = try encodeAddressParameter(recipientBase58)
        let amountHex = encodeUint256Decimal(rawAmount)
        let dataHex = selector + toHex + amountHex

        let body: [String: Any] = [
            "owner_address": senderBase58,
            "contract_address": contractAddressBase58,
            "function_selector": "transfer(address,uint256)",
            "parameter": toHex + amountHex,
            "fee_limit": feeLimitSun,
            "call_value": 0,
            "visible": true,
        ]
        _ = dataHex
        try Task.checkCancellation()
        let url = base.appending(path: "/wallet/triggersmartcontract")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TronRPCError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TronRPCError.transport("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let envelope = obj as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("triggersmartcontract: not JSON. Raw: \(raw.prefix(200))")
        }
        if let result = envelope["result"] as? [String: Any],
           let resultBool = result["result"] as? Bool, !resultBool {
            let msg = (result["message"] as? String).flatMap { hexDecodeString($0) }
                ?? "unknown error"
            throw TronRPCError.server(msg)
        }
        // The relevant sub-object is `transaction`. Extract raw_data_hex
        // and re-serialize the envelope as the broadcast body (Tron's
        // broadcast endpoint accepts the same shape).
        guard let txObj = envelope["transaction"] as? [String: Any],
              let rawHex = txObj["raw_data_hex"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("triggersmartcontract: missing transaction.raw_data_hex. Raw: \(raw.prefix(200))")
        }
        let rawBytes = decodeHex(rawHex)
        if rawBytes.isEmpty {
            throw TronRPCError.decode("triggersmartcontract: raw_data_hex decoded to 0 bytes")
        }
        // Serialize ONLY the transaction sub-object for broadcast.
        let txData: Data
        do {
            txData = try JSONSerialization.data(withJSONObject: txObj)
        } catch {
            throw TronRPCError.decode("could not re-serialize tx envelope: \(error)")
        }
        let envelopeJSON = String(data: txData, encoding: .utf8) ?? ""
        return UnsignedTransaction(
            rawData: rawBytes,
            rawDataHex: rawHex,
            envelopeJSON: envelopeJSON
        )
    }

    /// ABI-encode an address parameter for the Tron VM. Strips the
    /// 0x41 prefix (Tron addresses) and left-pads the remaining 20
    /// bytes to 32. Returns hex without 0x prefix.
    private func encodeAddressParameter(_ base58: String) throws -> String {
        let raw = WalletCore.Base58.decodeNoCheck(string: base58) ?? Data()
        guard raw.count == 25, raw[0] == 0x41 else {
            throw TronRPCError.decode("encodeAddressParameter: bad base58check for \(base58)")
        }
        let hash = raw.subdata(in: 1..<21)
        let padded = Data(repeating: 0, count: 12) + hash
        return padded.map { String(format: "%02x", $0) }.joined()
    }

    /// Encode a decimal-string uint256 value as 32-byte big-endian
    /// hex. Big enough to handle TRC-20 amounts up to 2^256 - 1.
    private func encodeUint256Decimal(_ decString: String) -> String {
        // Build the bytes by repeated divmod-256 on the decimal
        // digits string. Avoids pulling in a bignum dependency.
        var digits = Array(decString)
        var bytes: [UInt8] = []
        while !digits.isEmpty {
            var rem: UInt = 0
            var newDigits: [Character] = []
            for ch in digits {
                guard let d = ch.hexDigitValue, d < 10 else { return String(repeating: "0", count: 64) }
                let value = rem * 10 + UInt(d)
                let q = value / 256
                rem = value % 256
                if !newDigits.isEmpty || q > 0 {
                    newDigits.append(Character(String(q)))
                }
            }
            bytes.insert(UInt8(rem), at: 0)
            digits = newDigits
        }
        let padded = [UInt8](repeating: 0, count: max(0, 32 - bytes.count)) + bytes
        return padded.map { String(format: "%02x", $0) }.joined()
    }

    /// Splice an externally-produced 65-byte (R || S || V) signature
    /// into the JSON envelope returned by `createNativeTransaction`
    /// and broadcast it. Returns the txid on success.
    func broadcastWithSignature(
        envelopeJSON: String,
        signatureRSV: Data
    ) async throws -> String {
        guard signatureRSV.count == 65 else {
            throw TronRPCError.decode("signature must be 65 bytes (R||S||V), got \(signatureRSV.count)")
        }
        guard let envelopeData = envelopeJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: envelopeData),
              var signed = obj as? [String: Any]
        else {
            throw TronRPCError.decode("envelopeJSON could not be re-parsed")
        }
        signed["signature"] = [signatureRSV.map { String(format: "%02x", $0) }.joined()]
        let signedJSON: String
        do {
            let data = try JSONSerialization.data(withJSONObject: signed)
            signedJSON = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw TronRPCError.decode("could not re-serialize signed JSON: \(error)")
        }
        return try await broadcastTransaction(signedJSON: signedJSON)
    }

    /// Hex string → bytes, tolerating `0x` prefix and odd-length
    /// input (truncates to the last even prefix). Returns empty
    /// Data on any non-hex character so the caller can surface a
    /// "raw_data_hex decoded to 0 bytes" diagnostic.
    private func decodeHex(_ hex: String) -> Data {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            guard let b = UInt8(cleaned[i..<next], radix: 16) else { return Data() }
            bytes.append(b)
            i = next
        }
        return Data(bytes)
    }

    private func hexDecodeString(_ hex: String) -> String? {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            guard let b = UInt8(cleaned[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    // MARK: -- envelope

    private func call<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        try Task.checkCancellation()
        let url = base.appending(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw TronRPCError.decode("encode \(path): \(error.localizedDescription)")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Task cancellation (user flipped the network chip mid-
            // sync, pull-to-refresh fired a new request before the
            // previous finished, view dismissed). Re-throw as
            // CancellationError so the caller can drop it silently
            // instead of surfacing "Tron RPC transport error:
            // cancelled" to the dashboard.
            throw CancellationError()
        } catch {
            throw TronRPCError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TronRPCError.transport("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // TronGrid sometimes returns `{}` for empty accounts; let
            // the caller decide how to handle that via the optional
            // fields on its target type.
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("\(path): \(error.localizedDescription). Raw: \(raw.prefix(200))")
        }
    }

    private func rawGET<T: Decodable>(url: URL) async throws -> T {
        try Task.checkCancellation()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TronRPCError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TronRPCError.transport("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TronRPCError.decode("GET \(url.path): \(error.localizedDescription). Raw: \(raw.prefix(200))")
        }
    }
}

/// Same shape as the Solana RPC's `AnyJSONValue`; carries an opaque
/// blob through Decodable so we can expose the raw transaction body
/// to the diagnostics log without exhaustively modelling Tron's
/// many contract shapes.
extension TronRPCClient {
    struct AnyJSONValue: Decodable, Sendable, Hashable {
        let raw: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self.raw = nil; return }
            if let s = try? c.decode(String.self) { self.raw = s; return }
            // Object / array: skip detailed decode.
            self.raw = nil
        }
    }
}
