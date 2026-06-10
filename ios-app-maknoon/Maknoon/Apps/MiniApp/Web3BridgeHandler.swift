// EIP-1193 "eth" namespace handler (window.ethereum), pinned to Sepolia.
//
// Reads (chainId, balances, calls, gas) proxy straight to the Sepolia
// EthereumRPCClient with no approval. Privileged calls each route through
// MiniAppWeb3Coordinator for explicit consent + Face ID before any key is
// touched:
//   * eth_requestAccounts -> connect approval, returns the active address
//   * personal_sign / eth_sign -> EIP-191 message signing
//   * eth_sendTransaction -> native Sepolia send (build plan, sign, broadcast)
//
// Scope, by design for the demo: Sepolia only; software wallets only
// (hardware EVM signing is a separate, unshipped path); native-value
// sends only (arbitrary contract calldata is refused rather than
// blind-signed). Anything else returns EIP-1193 4200.

import Foundation

@MainActor
final class Web3BridgeHandler: MiniAppNamespaceHandler {
    let namespace = "eth"
    let requiredPermission: String? = "evm"

    private let store: HolderStore
    private let coordinator: MiniAppWeb3Coordinator
    private let appTitle: String

    // Demo is pinned to Sepolia.
    private let network: EthereumNetwork = .sepolia
    private var connected = false

    init(store: HolderStore, coordinator: MiniAppWeb3Coordinator, appTitle: String) {
        self.store = store
        self.coordinator = coordinator
        self.appTitle = appTitle
    }

    private var rpcURL: String { store.ethereumSettings.rpcURL(for: network) }
    private var chainIdHex: String { "0x" + String(network.chainId, radix: 16) }

    func handle(method: String, params: Any?) async throws -> Any? {
        let p = params as? [Any] ?? []
        switch method {
        // --- chain identity (no approval) ---
        case "eth_chainId":
            return chainIdHex
        case "net_version":
            return String(network.chainId)

        // --- accounts ---
        case "eth_accounts":
            return connected ? [try activeAddress()] : []
        case "eth_requestAccounts":
            return try await requestAccounts()

        // --- reads (no approval) ---
        case "eth_blockNumber":
            return "0x" + String(try await rpc().blockNumber(), radix: 16)
        case "eth_getBalance":
            let addr = try (p.first as? String) ?? activeAddress()
            return "0x" + (try await rpc().getBalance(addr)).hex
        case "eth_gasPrice":
            return "0x" + (try await rpc().gasPrice()).hex
        case "eth_getTransactionCount":
            let addr = try (p.first as? String) ?? activeAddress()
            return "0x" + String(try await rpc().transactionCount(addr, block: "pending"), radix: 16)
        case "eth_call":
            guard let tx = p.first as? [String: Any], let to = tx["to"] as? String else {
                throw MiniAppBridgeError.invalidParams("eth_call requires { to, data }")
            }
            let data = dataFromHex(tx["data"] as? String) ?? Data()
            return try await rpc().ethCall(to: to, data: data)
        case "eth_estimateGas":
            guard let tx = p.first as? [String: Any], let to = tx["to"] as? String else {
                throw MiniAppBridgeError.invalidParams("eth_estimateGas requires { to }")
            }
            let value = (try? EthereumWeiValue(hex: (tx["value"] as? String) ?? "0x0")) ?? .zero
            let data = dataFromHex(tx["data"] as? String)
            let from = try (tx["from"] as? String) ?? activeAddress()
            let units = try await rpc().estimateGas(from: from, to: to, value: value, data: data)
            return "0x" + String(units, radix: 16)

        // --- signing (approval + Face ID) ---
        case "personal_sign":
            // params: [message, address]
            return try await personalSign(messageParam: p.first)
        case "eth_sign":
            // params: [address, message]
            return try await personalSign(messageParam: p.count > 1 ? p[1] : nil)
        case "eth_sendTransaction":
            guard let tx = p.first as? [String: Any] else {
                throw MiniAppBridgeError.invalidParams("eth_sendTransaction requires a tx object")
            }
            return try await sendTransaction(tx: tx)

        case "wallet_switchEthereumChain":
            guard let req = p.first as? [String: Any],
                  let want = (req["chainId"] as? String)?.lowercased() else {
                throw MiniAppBridgeError.invalidParams("wallet_switchEthereumChain requires { chainId }")
            }
            if want == chainIdHex { return NSNull() }
            throw MiniAppBridgeError(code: 4902, message: "This demo wallet only supports Sepolia (\(chainIdHex)).")

        default:
            throw MiniAppBridgeError.unsupported("eth.\(method)")
        }
    }

    // MARK: -- privileged flows

    private func requestAccounts() async throws -> [String] {
        let addr = try activeAddress()
        if !connected {
            try await coordinator.present(appTitle: appTitle, kind: .connect(address: addr))
            connected = true
        }
        return [addr]
    }

    private func personalSign(messageParam: Any?) async throws -> String {
        guard let raw = messageParam as? String else {
            throw MiniAppBridgeError.invalidParams("message must be a string")
        }
        let message = dataFromHex(raw) ?? Data(raw.utf8)
        let (desc, account) = try activeSoftwareWallet()
        guard let sandwich = store.sandwich else { throw MiniAppBridgeError.unauthorized("wallet is locked") }
        _ = desc
        let preview = String(decoding: message.prefix(200), as: UTF8.self)
        try await coordinator.present(appTitle: appTitle, kind: .signMessage(preview: preview.isEmpty ? raw : preview))
        do {
            return try EthereumDescriptors.signPersonalMessageFromSandwich(
                sandwich: sandwich, account: account, message: message,
                biometricReason: "Sign a message for \(appTitle)")
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func sendTransaction(tx: [String: Any]) async throws -> String {
        guard let to = tx["to"] as? String, !to.isEmpty else {
            throw MiniAppBridgeError.invalidParams("eth_sendTransaction requires `to`")
        }
        // Native sends only. Reject arbitrary calldata rather than blind-sign.
        if let dataHex = tx["data"] as? String, let d = dataFromHex(dataHex), !d.isEmpty {
            throw MiniAppBridgeError.unsupported("contract calldata (this demo signs native Sepolia sends only)")
        }
        let value = (try? EthereumWeiValue(hex: (tx["value"] as? String) ?? "0x0")) ?? .zero
        let (_, account) = try activeSoftwareWallet()
        guard let sandwich = store.sandwich else { throw MiniAppBridgeError.unauthorized("wallet is locked") }

        // Approval before any chain prep / signing.
        try await coordinator.present(
            appTitle: appTitle,
            kind: .sendTransaction(to: to, amountEth: value.display(ticker: "ETH", maxDecimals: 6), network: network.displayName)
        )

        let wallet = EthereumWallet(descriptor: try activeDescriptor())
        let nonce = try await wallet.pendingNonce(rpcURL: rpcURL)
        let gasLimit: UInt64
        if let provided = (tx["gas"] as? String).flatMap({ UInt64($0.dropFirst(2), radix: 16) }) {
            gasLimit = provided
        } else {
            gasLimit = try await wallet.estimateGasUnits(to: to, value: value, data: nil, rpcURL: rpcURL)
        }
        let fees = try await EthereumGasEstimator.estimate(rpcURL: rpcURL)
        let std = fees.first(where: { $0.tier == .standard }) ?? fees[0]

        let plan = EthereumTxPlan(
            chainId: network.chainId,
            nonce: nonce,
            toAddress: to,
            value: value,
            gasLimit: gasLimit,
            maxFeePerGas: std.maxFeePerGas,
            maxPriorityFeePerGas: std.maxPriorityFeePerGas,
            payload: .native
        )
        let signed: String
        do {
            signed = try EthereumDescriptors.signTransactionFromSandwich(
                sandwich: sandwich, account: account, plan: plan,
                biometricReason: "Authorize sending from your wallet")
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        do {
            let hash = try await wallet.broadcast(rawTx: signed, rpcURL: rpcURL)
            LogStore.shared.info("MiniApp", "eth_sendTransaction broadcast \(hash) for \(appTitle)")
            return hash
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: -- helpers

    private func rpc() throws -> EthereumRPCClient {
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw MiniAppBridgeError.internalError("Sepolia RPC URL is invalid")
        }
        return client
    }

    private func activeDescriptor() throws -> EthereumWalletDescriptor {
        guard let desc = store.ethereumWalletStore.activeWallet else {
            throw MiniAppBridgeError.unauthorized("no Ethereum wallet in this app")
        }
        return desc
    }

    private func activeAddress() throws -> String {
        guard let addr = try activeDescriptor().address, !addr.isEmpty else {
            throw MiniAppBridgeError.unauthorized("active Ethereum wallet has no address")
        }
        return addr
    }

    private func activeSoftwareWallet() throws -> (EthereumWalletDescriptor, UInt32) {
        let desc = try activeDescriptor()
        guard case let .software(account) = desc.kind else {
            throw MiniAppBridgeError.unsupported("hardware-wallet signing in mini apps")
        }
        return (desc, account)
    }

    private func dataFromHex(_ s: String?) -> Data? {
        guard var h = s else { return nil }
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.count % 2 == 0, !h.isEmpty else { return h.isEmpty ? Data() : nil }
        var bytes = [UInt8]()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return Data(bytes)
    }
}
