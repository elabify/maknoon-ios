// Actor wrapping the on-chain operations for a single Ethereum
// wallet (one descriptor + network). Phase 1: balance + transaction
// history + receive address. Phase 2: send-flow prep (nonce, gas
// estimate, fee tiers) and broadcast.
//
// We deliberately do NOT cache an `inner` wallet object the way
// BitcoinWallet does. EVM chains are stateless from the holder's
// perspective: there's no SQLite to maintain, no descriptor to
// validate, no chain index to keep in sync. The actor's job is
// just to be the place where chain reads happen so the SwiftUI
// view layer can `await wallet.balance()` without worrying about
// thread safety.

import Foundation

actor EthereumWallet {

    enum WalletError: LocalizedError {
        case missingAddress
        case rpcURLInvalid
        case rpcFailure(String)
        case sandwichRequired
        case hardwareSigningNotImplemented
        case insufficientBalance(have: EthereumWeiValue, need: EthereumWeiValue)
        case invalidRecipient(String)
        var errorDescription: String? {
            switch self {
            case .missingAddress: return "Wallet has no derived address"
            case .rpcURLInvalid:  return "Configured RPC URL is not a valid URL"
            case .rpcFailure(let m): return m
            case .sandwichRequired: return "Identity Sandwich must be loaded to sign"
            case .hardwareSigningNotImplemented:
                return "Hardware-wallet Ethereum signing is not yet shipped. Use a software wallet for now."
            case .insufficientBalance(let have, let need):
                return "Insufficient balance. Have \(have.display(ticker: "ETH", maxDecimals: 6)), need \(need.display(ticker: "ETH", maxDecimals: 6))."
            case .invalidRecipient(let s):
                return "Recipient address is not a valid 0x-prefixed 20-byte hex string: '\(s)'."
            }
        }
    }

    let descriptor: EthereumWalletDescriptor

    init(descriptor: EthereumWalletDescriptor) {
        self.descriptor = descriptor
    }

    var address: String? { descriptor.address }

    /// Native-coin balance for the wallet's address on its network.
    func balance(rpcURL: String) async throws -> EthereumWeiValue {
        guard let addr = descriptor.address, !addr.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        do {
            return try await client.getBalance(addr)
        } catch {
            throw WalletError.rpcFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// ERC-20 balance for `token`. Hits the contract's `balanceOf`
    /// via eth_call, parses the 32-byte big-endian uint256.
    func tokenBalance(token: EthereumToken, rpcURL: String) async throws -> EthereumWeiValue {
        guard let addr = descriptor.address, !addr.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        guard let data = EthereumABI.balanceOfData(holderAddress: addr) else {
            throw WalletError.invalidRecipient(addr)
        }
        do {
            let hex = try await client.ethCall(to: token.contractAddress, data: data)
            return EthereumABI.parseUint256(hex) ?? .zero
        } catch {
            throw WalletError.rpcFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Probe a contract address for its `symbol()` and `decimals()`.
    /// Used by the Add Custom Token flow to auto-fill those fields.
    /// Returns nil if the contract doesn't implement either function
    /// (i.e. it's probably not an ERC-20).
    func probeTokenMetadata(contract: String, rpcURL: String) async throws -> (symbol: String, decimals: Int)? {
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        let symbolData = EthereumABI.symbolData()
        let decimalsData = EthereumABI.decimalsData()
        async let symHex = client.ethCall(to: contract, data: symbolData)
        async let decHex = client.ethCall(to: contract, data: decimalsData)
        do {
            let (sym, dec) = try await (symHex, decHex)
            guard let s = EthereumABI.parseSymbol(sym),
                  let d = EthereumABI.parseDecimals(dec)
            else { return nil }
            return (s, d)
        } catch {
            return nil
        }
    }

    /// Pending nonce for the next outbound send. Reading `pending`
    /// (not `latest`) catches anything we already broadcast that
    /// hasn't been mined yet.
    func pendingNonce(rpcURL: String) async throws -> UInt64 {
        guard let addr = descriptor.address, !addr.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        do {
            return try await client.transactionCount(addr, block: "pending")
        } catch {
            throw WalletError.rpcFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Estimate the gas units the recipient call would consume.
    /// Native ETH transfer to an EOA is always 21000; we still call
    /// the RPC because the destination might be a contract address.
    /// ERC-20 transfers pass the encoded `transfer(...)` data so the
    /// estimate reflects the contract's storage writes.
    func estimateGasUnits(
        to: String,
        value: EthereumWeiValue,
        data: Data?,
        rpcURL: String
    ) async throws -> UInt64 {
        guard let from = descriptor.address, !from.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        do {
            return try await client.estimateGas(from: from, to: to, value: value, data: data)
        } catch {
            // Some chains' RPCs reject estimateGas (state-pruning
            // issues, archive-only methods). Fall back to canonical
            // ballparks: 21000 for native EOA, 100000 for ERC-20.
            return data == nil ? 21000 : 100000
        }
    }

    /// Broadcast a signed transaction. Returns the tx hash.
    func broadcast(rawTx: String, rpcURL: String) async throws -> String {
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        do {
            return try await client.sendRawTransaction(rawTx)
        } catch {
            throw WalletError.rpcFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// ERC-20 transfer events for the wallet's address. Used by the
    /// auto-discover code path: dedupe contracts, cross-reference
    /// against EthereumTokenCatalog.reputable, auto-install matches.
    func recentTokenTransfers(
        explorerAPIURL: String?,
        apiKey: String?,
        chainId: UInt64,
        perPage: Int = 100
    ) async throws -> [EthereumTokenTransfer] {
        guard let addr = descriptor.address, !addr.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumExplorerClient(apiURL: explorerAPIURL, apiKey: apiKey, chainId: chainId) else {
            return []
        }
        return try await client.recentTokenTransfers(for: addr, perPage: perPage)
    }

    /// Activity probe used by wallet auto-discovery: returns true if
    /// the address has either non-zero balance OR any tx history. The
    /// discovery view uses this to decide whether to pre-add an
    /// account during a sweep across BIP44 indices.
    static func probeActivity(
        address: String,
        rpcURL: String,
        explorerAPIURL: String?,
        apiKey: String?,
        chainId: UInt64
    ) async throws -> (hasBalance: Bool, txCount: Int) {
        guard let rpc = EthereumRPCClient(urlString: rpcURL) else {
            throw WalletError.rpcURLInvalid
        }
        let bal = (try? await rpc.getBalance(address)) ?? .zero
        let hasBal = bal > .zero
        var txCount = 0
        if let exp = EthereumExplorerClient(apiURL: explorerAPIURL, apiKey: apiKey, chainId: chainId) {
            let txs = (try? await exp.recentTransactions(for: address, page: 1, perPage: 1)) ?? []
            txCount = txs.isEmpty ? 0 : 1
        }
        return (hasBal, txCount)
    }

    /// Recent transactions via the configured Etherscan-family API.
    /// Returns an empty list if no API URL is configured for this
    /// network (zkSync Era, Hyperliquid EVM today).
    func recentTransactions(
        explorerAPIURL: String?,
        apiKey: String?,
        chainId: UInt64,
        perPage: Int = 25
    ) async throws -> [EthereumTx] {
        guard let addr = descriptor.address, !addr.isEmpty else {
            throw WalletError.missingAddress
        }
        guard let client = EthereumExplorerClient(apiURL: explorerAPIURL, apiKey: apiKey, chainId: chainId) else {
            return []
        }
        return try await client.recentTransactions(for: addr, perPage: perPage)
    }
}
