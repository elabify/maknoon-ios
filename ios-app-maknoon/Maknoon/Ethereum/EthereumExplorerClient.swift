// Etherscan-family transaction-history client. Each chain's
// explorer (Etherscan, Arbiscan, Basescan, BscScan, ...) exposes the
// same `module=account&action=txlist` shape, so this client works
// uniformly across them. Per-network base URL + optional API key
// come from EthereumSettings.

import Foundation

struct EthereumTx: Codable, Hashable, Identifiable, Sendable {
    let hash: String
    let blockNumber: String
    let timeStamp: String
    let from: String
    // Optional: contract-creation transactions have a null `to` on
    // Etherscan/Blockscout. Keeping this non-optional made one such tx
    // fail the whole-array decode, silently emptying the history list.
    let to: String?
    let value: String          // wei as decimal string
    let gas: String?
    let gasPrice: String?
    let gasUsed: String?
    let isError: String?       // "0" or "1"
    let txreceiptStatus: String?
    let input: String?
    var id: String { hash }
}

/// One ERC-20 transfer event involving the watched address, as
/// returned by Etherscan-family `module=account&action=tokentx`. We
/// only need the contract address (to cross-reference against the
/// reputable token list); the rest is preserved for future use.
struct EthereumTokenTransfer: Codable, Hashable, Sendable {
    let hash: String
    let blockNumber: String
    let timeStamp: String
    let from: String
    let to: String
    let value: String              // raw token units as decimal string
    let contractAddress: String
    let tokenName: String?
    let tokenSymbol: String?
    let tokenDecimal: String?      // sic — Etherscan field is singular
}

/// Unified history item rendered in the wallet's tx list. Etherscan
/// returns ETH transactions on the `txlist` endpoint and ERC-20
/// transfer events on `tokentx`; for an incoming token receive the
/// recipient appears ONLY in tokentx. The wallet view merges both
/// feeds and sorts by timestamp.
enum EthereumTxItem: Identifiable, Hashable, Sendable {
    case native(EthereumTx)
    case token(EthereumTokenTransfer)

    var id: String {
        switch self {
        case .native(let t): return "n:\(t.hash)"
        case .token(let t):  return "t:\(t.hash):\(t.contractAddress)"
        }
    }

    var timestampSeconds: TimeInterval {
        switch self {
        case .native(let t): return TimeInterval(t.timeStamp) ?? 0
        case .token(let t):  return TimeInterval(t.timeStamp) ?? 0
        }
    }

    var hash: String {
        switch self {
        case .native(let t): return t.hash
        case .token(let t):  return t.hash
        }
    }
}

/// A clean, user-facing failure for the history feed. Public block
/// explorers (free Blockscout instances especially) intermittently answer
/// with HTML error pages, 404s, or 502 gateway bodies. Surfacing the raw
/// URLSession / JSONDecoder error (e.g. "DecodingError.dataCorrupted: Data
/// was corrupted") is confusing, so we map those to this instead.
enum EthereumExplorerError: LocalizedError {
    case unavailable(host: String, status: Int?)
    var errorDescription: String? {
        switch self {
        case .unavailable(let host, let status):
            if let status {
                return "Transaction history is temporarily unavailable (\(host) returned HTTP \(status))."
            }
            return "Transaction history is temporarily unavailable from \(host)."
        }
    }
}

struct EthereumExplorerClient: Sendable {
    let apiURL: URL
    let apiKey: String?
    /// EIP-155 chain id. Required by the unified Etherscan v2 API
    /// (`https://api.etherscan.io/v2/api?chainid=<N>`). Non-Etherscan
    /// custom endpoints can ignore it; we add the query parameter
    /// regardless and it's harmless when unused.
    let chainId: UInt64

    init?(apiURL: String?, apiKey: String?, chainId: UInt64) {
        guard let raw = apiURL, !raw.isEmpty, let u = URL(string: raw) else {
            return nil
        }
        self.apiURL = u
        self.apiKey = apiKey
        self.chainId = chainId
    }

    /// Fetch + validate an explorer response before decoding. Checks the
    /// HTTP status and rejects non-JSON bodies, converting flaky-explorer
    /// responses (HTML 404/502, gateway pages) into a clean
    /// `EthereumExplorerError` instead of letting a raw decode error leak.
    private func fetchValidated(_ url: URL, label: String) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(from: url)
        } catch {
            LogStore.shared.warn("eth.explorer", "\(label) \(apiURL.host ?? "?"): \(error.localizedDescription)")
            throw error
        }
        if let http = resp as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            LogStore.shared.warn("eth.explorer", "\(label) \(apiURL.host ?? "?"): HTTP \(http.statusCode)")
            throw EthereumExplorerError.unavailable(host: apiURL.host ?? "explorer", status: http.statusCode)
        }
        // Reject HTML/text bodies up front: a JSON response begins with
        // '{' or '[' once leading whitespace is dropped.
        let firstByte = data.first { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\n")
            && $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\t") }
        guard firstByte == UInt8(ascii: "{") || firstByte == UInt8(ascii: "[") else {
            LogStore.shared.warn("eth.explorer", "\(label) \(apiURL.host ?? "?"): non-JSON body")
            throw EthereumExplorerError.unavailable(host: apiURL.host ?? "explorer", status: nil)
        }
        return data
    }

    /// Common query items used by every Etherscan-family request.
    /// v2 requires `chainid`; v1 accepted it as a harmless extra
    /// parameter; custom Blockscout-style endpoints typically ignore
    /// unknown query items.
    private func commonQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = [URLQueryItem(name: "chainid", value: "\(chainId)")]
        if let key = apiKey { items.append(URLQueryItem(name: "apikey", value: key)) }
        return items
    }

    /// Recent ERC-20 transfers involving `address`. Mirrors the
    /// `recentTransactions` shape but hits `action=tokentx`. Used
    /// by the auto-discover code path to detect tokens the user
    /// actually holds.
    func recentTokenTransfers(for address: String, page: Int = 1, perPage: Int = 100) async throws -> [EthereumTokenTransfer] {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "tokentx"),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "startblock", value: "0"),
            URLQueryItem(name: "endblock", value: "99999999"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "offset", value: "\(perPage)"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        items.append(contentsOf: commonQueryItems())
        components.queryItems = items

        let data = try await fetchValidated(components.url!, label: "tokentx")
        let env: TokenTxEnvelope
        do {
            env = try JSONDecoder().decode(TokenTxEnvelope.self, from: data)
        } catch {
            LogStore.shared.warn("eth.explorer", "tokentx \(apiURL.host ?? "?"): decode failed")
            throw EthereumExplorerError.unavailable(host: apiURL.host ?? "explorer", status: nil)
        }
        if env.status != "1" {
            if env.message?.contains("No transactions") == true { return [] }
            let reason = env.resultMessage ?? env.message ?? "Unknown explorer error"
            LogStore.shared.warn("eth.explorer", "tokentx \(apiURL.host ?? "?"): \(reason)")
            throw NSError(
                domain: "EthereumExplorerClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
        return env.resultArray ?? []
    }

    /// Recent transactions for `address`. Etherscan returns up to
    /// `offset` rows per page, sorted newest first when `sort=desc`.
    func recentTransactions(for address: String, page: Int = 1, perPage: Int = 25) async throws -> [EthereumTx] {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "txlist"),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "startblock", value: "0"),
            URLQueryItem(name: "endblock", value: "99999999"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "offset", value: "\(perPage)"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        items.append(contentsOf: commonQueryItems())
        components.queryItems = items

        let data = try await fetchValidated(components.url!, label: "txlist")
        let env: EtherscanEnvelope
        do {
            env = try JSONDecoder().decode(EtherscanEnvelope.self, from: data)
        } catch {
            LogStore.shared.warn("eth.explorer", "txlist \(apiURL.host ?? "?"): decode failed")
            throw EthereumExplorerError.unavailable(host: apiURL.host ?? "explorer", status: nil)
        }
        if env.status != "1" {
            // status=0 with message=No transactions found is a normal
            // empty result; surface only "real" errors.
            if env.message?.contains("No transactions") == true { return [] }
            // Etherscan returns the human-readable reason in `result`
            // (a string) when status=0, not in `message`. Prefer
            // `result` when present so rate-limit / api-key errors
            // surface in the UI.
            let reason = env.resultMessage ?? env.message ?? "Unknown explorer error"
            LogStore.shared.warn("eth.explorer", "txlist \(apiURL.host ?? "?"): \(reason)")
            throw NSError(
                domain: "EthereumExplorerClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
        return env.resultArray ?? []
    }
}

/// Same envelope shape but typed for the `action=tokentx` endpoint.
/// Etherscan's bimorphic `result` field requires the same array-or
/// -string handling as the regular txlist envelope.
private struct TokenTxEnvelope: Decodable {
    let status: String?
    let message: String?
    let resultArray: [EthereumTokenTransfer]?
    let resultMessage: String?

    enum CodingKeys: String, CodingKey { case status, message, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
        if let arr = try? c.decode([Throwable<EthereumTokenTransfer>].self, forKey: .result) {
            self.resultArray = arr.compactMap { $0.value }
            self.resultMessage = nil
        } else if let s = try? c.decode(String.self, forKey: .result) {
            self.resultArray = nil
            self.resultMessage = s
        } else {
            self.resultArray = nil
            self.resultMessage = nil
        }
    }
}

/// Envelope wrapper that tolerates Etherscan's bimorphic `result`
/// field: an array of transactions when status=1, a plain string
/// (the failure reason) when status=0. Without this we crash on
/// "Missing/Invalid API Key" responses with a decoding error.
private struct EtherscanEnvelope: Decodable {
    let status: String?
    let message: String?
    let resultArray: [EthereumTx]?
    let resultMessage: String?

    enum CodingKeys: String, CodingKey { case status, message, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
        // Lossy: decode element-by-element so one malformed tx (an
        // unexpected null/shape on a single row) drops just that row
        // instead of emptying the entire history list.
        if let arr = try? c.decode([Throwable<EthereumTx>].self, forKey: .result) {
            self.resultArray = arr.compactMap { $0.value }
            self.resultMessage = nil
        } else if let s = try? c.decode(String.self, forKey: .result) {
            self.resultArray = nil
            self.resultMessage = s
        } else {
            self.resultArray = nil
            self.resultMessage = nil
        }
    }
}

/// Decodes any `Decodable` without throwing: a per-element failure is
/// captured as `nil` rather than aborting the surrounding array decode.
/// Used for lossy `result` arrays so a single bad row can't empty the list.
private struct Throwable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
