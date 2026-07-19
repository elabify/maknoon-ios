// EIP-1193 "eth" namespace handler (window.ethereum). Multi-chain across the
// app's known EVM networks, starting on Sepolia.
//
// Reads (chainId, balances, calls, gas) proxy straight to the active network's
// EthereumRPCClient with no approval. Privileged calls each route through
// MiniAppWeb3Coordinator for explicit consent + Face ID before any key is
// touched:
//   * eth_requestAccounts -> connect approval, returns the active address
//   * personal_sign / eth_sign -> EIP-191 message signing
//   * eth_signTypedData_v4 (+ v3) -> EIP-712 typed-data signing (0.6.3 hasher)
//   * eth_sendTransaction -> native OR contract call (calldata decoded for the
//     approval sheet when recognized, shown verbatim otherwise; never blind-signed)
//   * wallet_switchEthereumChain / addEthereumChain -> switch across known chains
//
// Signs with the active wallet whether software (identity sandwich) or
// hardware (Ledger / Trezor over BLE), routing through the same native signers
// the send flow uses. Scope, by design: only chains already configured in the
// app (no arbitrary RPC registration). Anything else returns EIP-1193 4200.

import Foundation

@MainActor
final class Web3BridgeHandler: MiniAppNamespaceHandler {
    let namespace = "eth"
    // Base permission (reads + connect + chain switch); writes and signing
    // require a stronger token, enforced per-method below (ADR-0057).
    let requiredPermission: String? = "wallet.ethereum.read"

    /// Per-method permission: reads/connect/switch need `wallet.ethereum.read`,
    /// sends need `wallet.ethereum.write`, signing needs `wallet.ethereum.sign`.
    /// So an app that declared only read is genuinely denied writes and signing.
    func requiredPermission(forMethod method: String) -> String? {
        switch method {
        case "eth_sendTransaction":
            return "wallet.ethereum.write"
        case "personal_sign", "eth_sign", "eth_signTypedData", "eth_signTypedData_v3", "eth_signTypedData_v4":
            return "wallet.ethereum.sign"
        default:
            return "wallet.ethereum.read"
        }
    }

    private let store: HolderStore
    private let coordinator: MiniAppWeb3Coordinator
    private let appTitle: String

    // The active EVM network for this session. Starts on Sepolia and can move
    // across the app's known EVM networks via wallet_switchEthereumChain.
    private var network: EthereumNetwork = .sepolia
    private var connected = false

    /// Optional hook the host wires to push an EIP-1193 `chainChanged` event to
    /// the page (window.__maknoonEmit) after a successful chain switch.
    var onChainChanged: ((String) -> Void)?

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
            // Forward `from` (caller-dependent reads like the v4 Quoter need it);
            // default to the connected wallet.
            let from = (tx["from"] as? String) ?? (try? activeAddress())
            return try await rpc().ethCall(to: to, data: data, from: from)
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
        case "eth_signTypedData_v4", "eth_signTypedData_v3", "eth_signTypedData":
            return try await signTypedData(params: p)

        // --- chain switching ---
        case "wallet_switchEthereumChain", "wallet_addEthereumChain":
            // We only move between chains already known to the app; we do not
            // register arbitrary RPCs, so add behaves like switch for a known chain.
            return try await switchChain(params: p)

        default:
            throw MiniAppBridgeError.unsupported("eth.\(method)")
        }
    }

    // MARK: -- privileged flows

    private func requestAccounts() async throws -> [String] {
        if !connected {
            // Offer the app's EVM wallets so the user can pick which to connect
            // (software or hardware); the sheet makes the choice active and we
            // then return that wallet's address.
            let ews = store.ethereumWalletStore
            let choices = ews.wallets.compactMap { w -> MiniAppWeb3Coordinator.WalletChoice? in
                guard let addr = w.address, !addr.isEmpty else { return nil }
                return .init(id: w.id, label: w.label, address: addr)
            }
            guard !choices.isEmpty else {
                throw MiniAppBridgeError.unauthorized("no Ethereum wallet in this app")
            }
            try await coordinator.present(
                appTitle: appTitle,
                kind: .connect(wallets: choices, activeId: ews.activeWallet?.id))
            connected = true
        }
        return [try activeAddress()]
    }

    private func personalSign(messageParam: Any?) async throws -> String {
        guard let raw = messageParam as? String else {
            throw MiniAppBridgeError.invalidParams("message must be a string")
        }
        let message = dataFromHex(raw) ?? Data(raw.utf8)
        let (desc, account) = try activeWalletInfo()
        let preview = String(decoding: message.prefix(200), as: UTF8.self)
        try await coordinator.present(appTitle: appTitle, kind: .signMessage(preview: preview.isEmpty ? raw : preview))
        do {
            switch desc.kind {
            case .software:
                guard let sandwich = store.sandwich else { throw MiniAppBridgeError.unauthorized("wallet is locked") }
                return try EthereumDescriptors.signPersonalMessageFromSandwich(
                    sandwich: sandwich, account: account, message: message,
                    biometricReason: "Sign a message for \(appTitle)")
            case .hardware(let deviceId, _, _):
                return try await EthereumMessageSigning.signOverBLE(
                    device: try hardwareDevice(for: deviceId), account: account,
                    message: message, hidden: desc.hidden)
            }
        } catch let e as MiniAppBridgeError {
            throw e
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func sendTransaction(tx: [String: Any]) async throws -> String {
        guard let to = tx["to"] as? String, !to.isEmpty else {
            throw MiniAppBridgeError.invalidParams("eth_sendTransaction requires `to`")
        }
        // Contract calldata is allowed but never blind-signed: it is decoded for
        // the approval sheet when recognized, and shown verbatim otherwise.
        let data = dataFromHex(tx["data"] as? String) ?? Data()
        let value = (try? EthereumWeiValue(hex: (tx["value"] as? String) ?? "0x0")) ?? .zero
        let (desc, account) = try activeWalletInfo()

        let decoded = data.isEmpty ? nil : EthereumCallDataDecoder.decode(to: to, data: data)
        let dataHex = data.isEmpty ? nil : "0x" + data.map { String(format: "%02x", $0) }.joined()

        // Approval before any chain prep / signing.
        try await coordinator.present(
            appTitle: appTitle,
            kind: .sendTransaction(
                to: to,
                amountEth: value.display(ticker: "ETH", maxDecimals: 6),
                network: network.displayName,
                summary: decoded?.summary,
                dataHex: dataHex)
        )

        let wallet = EthereumWallet(descriptor: desc)
        let nonce = try await wallet.pendingNonce(rpcURL: rpcURL)
        let gasLimit: UInt64
        if let provided = (tx["gas"] as? String).flatMap({ UInt64($0.dropFirst(2), radix: 16) }) {
            gasLimit = provided
        } else {
            gasLimit = try await wallet.estimateGasUnits(to: to, value: value, data: data.isEmpty ? nil : data, rpcURL: rpcURL)
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
            payload: data.isEmpty ? .native : .contractCall(data: data)
        )
        let signed: String
        do {
            switch desc.kind {
            case .software:
                guard let sandwich = store.sandwich else { throw MiniAppBridgeError.unauthorized("wallet is locked") }
                signed = try EthereumDescriptors.signTransactionFromSandwich(
                    sandwich: sandwich, account: account, plan: plan,
                    biometricReason: "Authorize sending from your wallet")
            case .hardware(let deviceId, _, _):
                // Arbitrary contract calls (approve, swap) are blind-signed on the
                // device: the raw calldata shows on-screen, not a decoded amount.
                signed = try await EthereumHardwareTx.sign(
                    plan: plan, device: try hardwareDevice(for: deviceId), account: account,
                    hidden: desc.hidden, derivationPath: desc.derivationPath)
            }
        } catch let e as MiniAppBridgeError {
            throw e
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        do {
            let hash = try await wallet.broadcast(rawTx: signed, rpcURL: rpcURL)
            LogStore.shared.info("MiniApp", "eth_sendTransaction broadcast \(hash) for \(appTitle)")
            // Record an optimistic pending row + point the wallet at this chain,
            // so opening the wallet (including via walletView.open after a swap)
            // shows the tx confirming. Mirrors the WalletConnect + in-app send paths.
            store.ethereumWalletStore.markPendingOutbound(
                senderWalletId: desc.id,
                txHash: hash,
                senderAddress: desc.address ?? "",
                recipientAddress: to,
                weiValue: value.decimal.description
            )
            store.ethereumWalletStore.setCurrentNetwork(network, for: desc.id)
            return hash
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func switchChain(params p: [Any]) async throws -> Any? {
        guard let req = p.first as? [String: Any],
              let want = (req["chainId"] as? String)?.lowercased() else {
            throw MiniAppBridgeError.invalidParams("requires { chainId }")
        }
        let hexDigits = want.hasPrefix("0x") ? String(want.dropFirst(2)) : want
        guard let wantId = UInt64(hexDigits, radix: 16) else {
            throw MiniAppBridgeError.invalidParams("chainId must be 0x-hex")
        }
        if wantId == network.chainId { return NSNull() }
        guard let target = EthereumNetwork.allCases.first(where: { $0.chainId == wantId }) else {
            throw MiniAppBridgeError(code: 4902, message: "Chain 0x\(String(wantId, radix: 16)) is not configured in this wallet.")
        }
        // Switch silently, no confirmation sheet: this only ever moves between
        // chains already configured in the wallet (unknown chains 4902 above),
        // and any actual transaction still shows its chain in its own approval.
        network = target
        let hex = "0x" + String(target.chainId, radix: 16)
        onChainChanged?(hex)
        LogStore.shared.info("MiniApp", "wallet_switchEthereumChain -> \(target.displayName) for \(appTitle)")
        return NSNull()
    }

    private func signTypedData(params p: [Any]) async throws -> String {
        // MetaMask order is [address, jsonString]; some callers pass [jsonString]
        // or an already-parsed object. Accept all three.
        let jsonParam: Any? = p.count > 1 ? p[1] : p.first
        let json: String
        if let s = jsonParam as? String {
            json = s
        } else if let obj = jsonParam,
                  let d = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: d, encoding: .utf8) {
            json = s
        } else {
            throw MiniAppBridgeError.invalidParams("eth_signTypedData_v4 requires typed-data JSON")
        }
        let (desc, account) = try activeWalletInfo()

        try await coordinator.present(
            appTitle: appTitle,
            kind: .signTypedData(domain: typedDataDomainName(json), preview: String(json.prefix(400))))
        do {
            switch desc.kind {
            case .software:
                guard let sandwich = store.sandwich else { throw MiniAppBridgeError.unauthorized("wallet is locked") }
                return try EthereumDescriptors.signTypedDataFromSandwich(
                    sandwich: sandwich, account: account, typedDataJSON: json,
                    biometricReason: "Sign typed data for \(appTitle)")
            case .hardware(let deviceId, _, _):
                return try await EthereumMessageSigning.signTypedDataOverBLE(
                    device: try hardwareDevice(for: deviceId), account: account,
                    typedDataJSON: json, hidden: desc.hidden)
            }
        } catch let e as MiniAppBridgeError {
            throw e
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func typedDataDomainName(_ json: String) -> String {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let domain = obj["domain"] as? [String: Any],
              let name = domain["name"] as? String else { return "" }
        return name
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

    /// The active wallet + its account index, for either kind. Hardware signing
    /// routes through the paired device (resolved from the descriptor's deviceId).
    private func activeWalletInfo() throws -> (EthereumWalletDescriptor, UInt32) {
        let desc = try activeDescriptor()
        switch desc.kind {
        case .software(let account):
            return (desc, account)
        case .hardware(_, let account, _):
            return (desc, account)
        }
    }

    /// Resolve the paired hardware device for a hardware wallet descriptor.
    private func hardwareDevice(for deviceId: UUID) throws -> RegisteredDevice {
        guard let device = store.devices.find(id: deviceId) else {
            throw MiniAppBridgeError.unauthorized("the paired device for this wallet was not found")
        }
        return device
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
