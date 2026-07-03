// WalletConnect (EVM-only) manager (ADR-0049).
//
// Owns the Reown WalletKit lifecycle and bridges it to Maknoon's existing
// signers. It is deliberately decoupled from the wallet store: the app injects
// two closures (the EVM addresses to offer, and a personal-sign function that
// runs the existing biometric + signer), so this file has no dependency on
// EthereumWalletStore or the signing internals.
//
// Scope for this first cut: pair, approve/reject a session proposal, and handle
// personal_sign / eth_sign requests. eth_sendTransaction and eth_signTypedData
// (EIP-712) are advertised so sessions connect, but return a clear "not yet
// supported" error until the next pass (EIP-712 needs the cores' xcframeworks
// rebuilt to expose the hasher; sending reuses the send pipeline).

import Foundation
import Combine
import ReownWalletKit
import WalletConnectNetworking

@MainActor
final class WalletConnectManager: ObservableObject {
    static let shared = WalletConnectManager()

    @Published private(set) var sessions: [Session] = []
    @Published var pendingProposal: Session.Proposal?
    @Published var pendingRequest: PendingRequest?
    @Published var lastError: String?
    @Published private(set) var isConfigured = false
    /// Live relay-socket state, surfaced in the WalletConnect screen so the user
    /// can tell at a glance whether the relay is reachable. Driven by the SDK's
    /// socketConnectionStatusPublisher.
    @Published private(set) var relayConnected = false
    /// True while the WalletConnect screen is on top. When it is, that screen
    /// presents the proposal/sign approval itself (the root-level sheets cannot
    /// present on top of an already-presented sheet), so the root modifier
    /// stands down to avoid a silently-failed double presentation.
    @Published var screenVisible = false

    /// What the dApp is asking for. Drives which signer the approval runs and
    /// the wording on the sheet.
    enum Action {
        case sign               // personal_sign / eth_sign
        case signTypedData      // eth_signTypedData / _v4 (EIP-712)
        case sendTransaction    // eth_sendTransaction: sign + broadcast, return tx hash
        case signTransaction    // eth_signTransaction: sign only, return raw signed tx
    }

    struct PendingRequest: Identifiable {
        let id: String
        let request: Request
        let methodLabel: String
        let preview: String
        let address: String
        let action: Action
        /// Stable id (UUID string) of the wallet bound to this session at connect
        /// time. Disambiguates two wallets that share an address (e.g. a Ledger
        /// and a hidden-passphrase Trezor on the same seed). nil for sessions
        /// created before binding existed (falls back to address resolution).
        let walletId: String?
        /// Display label of the resolved wallet (shown above the message).
        let walletLabel: String?
        /// Non-nil when signing must go through a BLE hardware device; drives the
        /// prepare-device popup. nil for software wallets (sign directly). The
        /// app resolves this so the UI needs no store/environment access (a sheet
        /// presented from the app root would otherwise crash reading the store).
        let hardwareDevice: RegisteredDevice?
        /// True when the resolved wallet is a hidden (passphrase) Trezor that
        /// needs the passphrase typed on the host before signing.
        let requiresHostPassphrase: Bool
    }

    /// EVM addresses (0x...) to offer to dApps. Injected by the app.
    var evmAddressesProvider: (() -> [String])?
    /// Stable id (UUID string) of the wallet currently being connected (the
    /// active EVM wallet). Captured when a session is approved and bound to the
    /// session topic so signing routes to the exact wallet, not just any wallet
    /// with a matching address. Injected by the app.
    var connectingWalletId: (() -> String?)?
    /// Sign an EIP-191 personal message. Receives the message (hex or utf8), the
    /// requesting address, the bound wallet id (if known), and an optional
    /// host-typed passphrase (hidden Trezor). Must run the existing biometric /
    /// hardware-device flow and return a 0x-prefixed signature. Injected by the
    /// app; handles software + hardware.
    var personalSign: ((_ message: String, _ address: String, _ walletId: String?, _ hostPassphrase: String?) async throws -> String)?
    /// Sign EIP-712 typed data (`eth_signTypedData_v4`). Receives the typed-data
    /// JSON, the requesting address, the bound wallet id, and an optional
    /// host-typed passphrase. Returns a 0x-prefixed signature. Injected by the app.
    var signTypedData: ((_ typedDataJSON: String, _ address: String, _ walletId: String?, _ hostPassphrase: String?) async throws -> String)?
    /// Whether the wallet bound to a session (by id, falling back to address) is
    /// a hidden wallet needing a host-typed passphrase. Injected by the app.
    var walletRequiresHostPassphrase: ((_ address: String, _ walletId: String?) -> Bool)?
    /// Resolve the display label and (for hardware wallets) the BLE device for a
    /// request's wallet, so the UI can drive the prepare-device popup without
    /// touching the store. Injected by the app.
    var signerContext: ((_ address: String, _ walletId: String?) -> (label: String?, device: RegisteredDevice?))?
    /// Build, sign and (when `broadcast`) submit an `eth_sendTransaction` /
    /// `eth_signTransaction`. Returns the tx hash (send) or the 0x raw signed tx
    /// (sign). Resolves chain + gas + nonce + fees and runs the existing
    /// software / hardware signer. Injected by the app.
    var sendTransaction: ((_ request: Request, _ address: String, _ walletId: String?, _ broadcast: Bool, _ hostPassphrase: String?) async throws -> String)?
    /// Whether the wallet has a network configured (built-in or custom) for a
    /// chain id, so `wallet_switchEthereumChain` can answer truthfully. Injected
    /// by the app.
    var isChainConfigured: ((_ chainId: UInt64) -> Bool)?

    private var cancellables = Set<AnyCancellable>()
    /// Persistent topic -> walletId binding so signing survives relaunch.
    private let sessionBindingKey = "walletconnect.sessionWalletId.v1"
    private var sessionWalletId: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: sessionBindingKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: sessionBindingKey) }
    }
    private func bindSession(topic: String, walletId: String?) {
        guard let walletId else { return }
        var map = sessionWalletId; map[topic] = walletId; sessionWalletId = map
    }
    private func unbindSession(topic: String) {
        var map = sessionWalletId; map.removeValue(forKey: topic); sessionWalletId = map
    }

    // Common EVM chains we offer. AutoNamespaces intersects these with what the
    // dApp requests, so listing extra chains is harmless.
    private let supportedChainIds: [Int] = [1, 11155111, 137, 8453, 42161, 10, 56, 43114]
    private let supportedMethods = [
        "personal_sign", "eth_sign",
        "eth_signTypedData", "eth_signTypedData_v3", "eth_signTypedData_v4",
        "eth_sendTransaction", "eth_signTransaction", "wallet_switchEthereumChain",
        "wallet_addEthereumChain",
    ]
    private let supportedEvents = ["chainChanged", "accountsChanged"]

    private init() {}

    /// Storage identifier the Reown SDK uses for both its UserDefaults suite and
    /// its keychain access group. We deliberately use the app's OWN
    /// application-identifier access group (TEAMID.bundleId) rather than a shared
    /// App Group: the app is always entitled to it (no `application-groups`
    /// entitlement or dev-portal capability needed), and as a UserDefaults suite
    /// name it is non-nil because it differs from the bare bundle id. The team
    /// prefix matches DEVELOPMENT_TEAM in project.yml.
    static let storageGroup = "PQ34VD5384.com.elabify.app.maknoon"

    /// `relayHost` is an optional self-hosted relay override (see Ethereum
    /// network settings, Advanced). Empty falls back to the built-in default
    /// relay. Applies to all networks; takes effect on next launch only because
    /// `Networking.configure` runs once per process.
    func configureIfNeeded(projectId: String, relayHost: String = "") {
        guard !isConfigured, !projectId.isEmpty else { return }
        guard let redirect = try? AppMetadata.Redirect(native: "wc://", universal: nil) else {
            lastError = "WalletConnect metadata configuration failed."
            return
        }
        let host = relayHost.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            Networking.configure(
                groupIdentifier: Self.storageGroup,
                projectId: projectId,
                socketFactory: WCSocketFactory()
            )
        } else {
            LogStore.shared.info("walletconnect", "using self-hosted relay \(host)")
            Networking.configure(
                relayHost: host,
                groupIdentifier: Self.storageGroup,
                projectId: projectId,
                socketFactory: WCSocketFactory()
            )
        }
        let metadata = AppMetadata(
            name: "Maknoon",
            description: "Maknoon post-quantum identity and wallet",
            url: "https://elabify.com",
            icons: [],
            redirect: redirect
        )
        WalletKit.configure(metadata: metadata, crypto: WCCryptoProvider())
        isConfigured = true
        subscribe()
        refreshSessions()
    }

    private func subscribe() {
        WalletKit.instance.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal, _ in
                LogStore.shared.info("walletconnect", "proposal received from \(proposal.proposer.name.isEmpty ? "an app" : proposal.proposer.name)")
                self?.pendingProposal = proposal
            }
            .store(in: &cancellables)

        WalletKit.instance.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request, _ in
                LogStore.shared.info("walletconnect", "request received method=\(request.method)")
                self?.ingest(request: request)
            }
            .store(in: &cancellables)

        WalletKit.instance.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessions = $0 }
            .store(in: &cancellables)

        WalletKit.instance.sessionDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] topic, _ in
                self?.unbindSession(topic: topic)
                self?.refreshSessions()
            }
            .store(in: &cancellables)

        WalletKit.instance.socketConnectionStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                LogStore.shared.info("walletconnect", "relay socket status: \(String(describing: status))")
                self?.relayConnected = (status == .connected)
            }
            .store(in: &cancellables)
    }

    func refreshSessions() { sessions = WalletKit.instance.getSessions() }

    // MARK: Pairing

    func pair(uriString: String) async {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        LogStore.shared.info("walletconnect", "pair: scanned len=\(trimmed.count) prefix=\(trimmed.prefix(10))")
        guard let uri = WalletConnectURI(string: trimmed) else {
            LogStore.shared.warn("walletconnect", "pair: not a valid wc: URI")
            lastError = "That is not a valid WalletConnect link."
            return
        }
        do {
            try await WalletKit.instance.pair(uri: uri)
            LogStore.shared.info("walletconnect", "pair: paired, awaiting proposal (topic=\(uri.topic.prefix(8)))")
        } catch {
            LogStore.shared.warn("walletconnect", "pair: failed \(error.localizedDescription)")
            lastError = "Could not connect: \(error.localizedDescription)"
        }
    }

    // MARK: Session proposal

    func approveProposal() async {
        guard let proposal = pendingProposal else { return }
        defer { pendingProposal = nil }
        let addresses = evmAddressesProvider?() ?? []
        guard !addresses.isEmpty else {
            lastError = "Add an Ethereum wallet before connecting."
            try? await WalletKit.instance.rejectSession(proposalId: proposal.id, reason: .userRejected)
            return
        }
        // Capture which wallet is being connected so signing later routes to it
        // specifically, even if another wallet shares the same address.
        let boundWalletId = connectingWalletId?()
        let chains = supportedChainIds.compactMap { Blockchain("eip155:\($0)") }
        var accounts: [Account] = []
        for chain in chains {
            for addr in addresses {
                if let account = Account(blockchain: chain, address: addr) { accounts.append(account) }
            }
        }
        do {
            let namespaces = try AutoNamespaces.build(
                sessionProposal: proposal,
                chains: chains,
                methods: supportedMethods,
                events: supportedEvents,
                accounts: accounts
            )
            let session = try await WalletKit.instance.approve(proposalId: proposal.id, namespaces: namespaces)
            bindSession(topic: session.topic, walletId: boundWalletId)
            LogStore.shared.info("walletconnect", "approved session topic=\(session.topic) boundWalletId=\(boundWalletId ?? "nil")")
            refreshSessions()
        } catch {
            lastError = "Could not approve the connection: \(error.localizedDescription)"
            try? await WalletKit.instance.rejectSession(proposalId: proposal.id, reason: .userRejected)
        }
    }

    func rejectProposal() async {
        guard let proposal = pendingProposal else { return }
        pendingProposal = nil
        try? await WalletKit.instance.rejectSession(proposalId: proposal.id, reason: .userRejected)
    }

    // MARK: Requests

    private func ingest(request: Request) {
        switch request.method {
        case "personal_sign", "eth_sign":
            guard let params = try? request.params.get([String].self), params.count >= 2 else {
                respondError(request, code: -32602, message: "Bad sign params")
                return
            }
            // personal_sign: [message, address]; eth_sign: [address, message].
            let (msg, address) = request.method == "personal_sign"
                ? (params[0], params[1]) : (params[1], params[0])
            let boundId = sessionWalletId[request.topic]
            let ctx = signerContext?(address, boundId)
            pendingRequest = PendingRequest(
                id: request.id.string,
                request: request,
                methodLabel: "Sign message",
                preview: decodePreview(msg),
                address: address,
                action: .sign,
                walletId: boundId,
                walletLabel: ctx?.label,
                hardwareDevice: ctx?.device,
                requiresHostPassphrase: walletRequiresHostPassphrase?(address, boundId) ?? false
            )
        case "eth_signTypedData", "eth_signTypedData_v4", "eth_signTypedData_v3":
            guard let (address, json) = Self.extractTypedData(request) else {
                respondError(request, code: -32602, message: "Bad typed-data params")
                return
            }
            let boundId = sessionWalletId[request.topic]
            let ctx = signerContext?(address, boundId)
            pendingRequest = PendingRequest(
                id: request.id.string,
                request: request,
                methodLabel: "Sign typed data",
                preview: Self.typedDataPreview(json),
                address: address,
                action: .signTypedData,
                walletId: boundId,
                walletLabel: ctx?.label,
                hardwareDevice: ctx?.device,
                requiresHostPassphrase: walletRequiresHostPassphrase?(address, boundId) ?? false
            )
        case "eth_sendTransaction", "eth_signTransaction":
            guard let txs = try? request.params.get([WCEthTx].self), let tx = txs.first,
                  let from = tx.from else {
                respondError(request, code: -32602, message: "Bad transaction params")
                return
            }
            let boundId = sessionWalletId[request.topic]
            let ctx = signerContext?(from, boundId)
            let isSend = request.method == "eth_sendTransaction"
            pendingRequest = PendingRequest(
                id: request.id.string,
                request: request,
                methodLabel: isSend ? "Approve transaction" : "Sign transaction",
                preview: Self.txPreview(tx, chain: request.chainId),
                address: from,
                action: isSend ? .sendTransaction : .signTransaction,
                walletId: boundId,
                walletLabel: ctx?.label,
                hardwareDevice: ctx?.device,
                requiresHostPassphrase: walletRequiresHostPassphrase?(from, boundId) ?? false
            )
        case "wallet_switchEthereumChain", "wallet_addEthereumChain":
            // Not a signing op: answer directly, no approval sheet. EIP-3326/3085:
            // null result on success, 4902 if the chain isn't configured here. We
            // never silently add a custom network, so "add" succeeds only if it is
            // already configured (otherwise the user adds it in settings).
            guard let chainId = Self.requestedChainId(request) else {
                respondError(request, code: -32602, message: "Bad chain params")
                return
            }
            if isChainConfigured?(chainId) ?? false {
                respondNull(request)
                if let blockchain = Blockchain("eip155:\(chainId)") {
                    Task {
                        try? await WalletKit.instance.emit(
                            topic: request.topic,
                            event: Session.Event(name: "chainChanged", data: AnyCodable("0x" + String(chainId, radix: 16))),
                            chainId: blockchain
                        )
                    }
                }
                LogStore.shared.info("walletconnect", "\(request.method) -> chain \(chainId) ok")
            } else {
                respondError(request, code: 4902,
                             message: "No network configured for chain \(chainId). Add it in the Ethereum network settings, then try again.")
                LogStore.shared.info("walletconnect", "\(request.method) -> chain \(chainId) not configured")
            }
        default:
            // Connect succeeds for these methods, but we cannot serve them yet.
            respondError(request, code: 4001,
                         message: "\(request.method) is not supported in this build yet")
        }
    }

    func approvePendingRequest(hostPassphrase: String?) async {
        guard let pending = pendingRequest else { return }
        defer { pendingRequest = nil }
        do {
            let result: String
            switch pending.action {
            case .sign:
                guard let signer = personalSign else { return }
                let original = (try? pending.request.params.get([String].self)) ?? []
                let messageParam = pending.request.method == "personal_sign" ? original.first : original.last
                result = try await signer(messageParam ?? "", pending.address, pending.walletId, hostPassphrase)
            case .signTypedData:
                guard let signer = signTypedData,
                      let (_, json) = Self.extractTypedData(pending.request) else { return }
                result = try await signer(json, pending.address, pending.walletId, hostPassphrase)
            case .sendTransaction, .signTransaction:
                guard let send = sendTransaction else { return }
                result = try await send(
                    pending.request, pending.address, pending.walletId,
                    pending.action == .sendTransaction, hostPassphrase
                )
            }
            try await WalletKit.instance.respond(
                topic: pending.request.topic,
                requestId: pending.request.id,
                response: .response(AnyCodable(result))
            )
            LogStore.shared.info("walletconnect", "responded \(pending.request.method) ok")
        } catch {
            // Surface the real reason both in-app and to the dApp.
            lastError = error.localizedDescription
            LogStore.shared.warn("walletconnect", "\(pending.request.method) failed: \(error.localizedDescription)")
            respondError(pending.request, code: 4001, message: error.localizedDescription)
        }
    }

    func rejectPendingRequest() async {
        guard let pending = pendingRequest else { return }
        pendingRequest = nil
        respondError(pending.request, code: 4001, message: "User rejected")
    }

    private func respondError(_ request: Request, code: Int, message: String) {
        Task {
            try? await WalletKit.instance.respond(
                topic: request.topic,
                requestId: request.id,
                response: .error(JSONRPCError(code: code, message: message))
            )
        }
    }

    /// Respond with a JSON `null` result (EIP-3326 success for switch/add chain).
    private func respondNull(_ request: Request) {
        Task {
            try? await WalletKit.instance.respond(
                topic: request.topic,
                requestId: request.id,
                response: .response(AnyCodable(Optional<String>.none))
            )
        }
    }

    /// chainId (decimal) from a wallet_switchEthereumChain / wallet_addEthereumChain
    /// request: `[{ "chainId": "0x89" }]`.
    static func requestedChainId(_ request: Request) -> UInt64? {
        struct ChainParam: Codable { let chainId: String? }
        guard let params = try? request.params.get([ChainParam].self),
              let hex = params.first?.chainId else { return nil }
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(s, radix: 16)
    }

    // MARK: Sessions

    func disconnect(topic: String) async {
        do {
            try await WalletKit.instance.disconnect(topic: topic)
            unbindSession(topic: topic)
            refreshSessions()
        } catch {
            lastError = "Could not disconnect: \(error.localizedDescription)"
        }
    }

    /// Wipe ALL WalletConnect state: disconnect every session and clear the
    /// SDK's persisted pairings/sessions/relay records. Use this to recover from
    /// stale sessions (e.g. a session whose accounts were negotiated before a
    /// wallet-selection change) or a wedged relay. The user must re-scan a fresh
    /// QR afterwards; nothing here touches keys or wallets.
    func resetAllConnections() async {
        for session in WalletKit.instance.getSessions() {
            try? await WalletKit.instance.disconnect(topic: session.topic)
        }
        do {
            try await WalletKit.instance.cleanup()
            LogStore.shared.info("walletconnect", "reset: cleared all sessions and persisted state")
        } catch {
            LogStore.shared.warn("walletconnect", "reset cleanup failed: \(error.localizedDescription)")
        }
        UserDefaults.standard.removeObject(forKey: sessionBindingKey)
        refreshSessions()
    }

    // Render a human-readable preview of a personal_sign payload (often hex of
    // UTF-8 text, e.g. a Sign-In-With-Ethereum statement).
    private func decodePreview(_ message: String) -> String {
        let hex = message.hasPrefix("0x") ? String(message.dropFirst(2)) : message
        if let data = Data(hexString: hex), let text = String(data: data, encoding: .utf8),
           text.allSatisfy({ !$0.isNewline || $0 == "\n" }) {
            return text
        }
        return message
    }

    /// One-glance summary of an eth_sendTransaction/eth_signTransaction for the
    /// approval sheet. The hardware device screen remains the authoritative
    /// confirmation; this is just so the user knows what they are approving.
    static func txPreview(_ tx: WCEthTx, chain: Blockchain) -> String {
        var lines: [String] = ["Network: \(chain.absoluteString)"]
        if let to = tx.to, !to.isEmpty {
            lines.append("To: \(to)")
        } else {
            lines.append("To: (contract creation)")
        }
        lines.append("Value: \(ethDisplay(fromHexWei: tx.value))")
        let dataBytes = tx.data.map { hexByteCount($0) } ?? 0
        lines.append(dataBytes > 0 ? "Data: \(dataBytes) bytes (contract call)" : "Data: none")
        return lines.joined(separator: "\n")
    }

    private static func hexByteCount(_ hex: String) -> Int {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return s.count / 2
    }

    /// Pull (address, typed-data-JSON) out of an eth_signTypedData* request.
    /// dApps send `[address, jsonString]`; some send the typed data as a JSON
    /// object instead of a string, which we re-serialize. Address position is
    /// detected (not assumed) so legacy orderings also work.
    static func extractTypedData(_ request: Request) -> (address: String, json: String)? {
        func isAddr(_ s: String) -> Bool {
            let h = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
            return h.count == 40 && h.allSatisfy { $0.isHexDigit }
        }
        // Common case: both elements are strings ([address, jsonString]).
        if let parts = try? request.params.get([String].self), parts.count >= 2 {
            if isAddr(parts[0]) { return (parts[0], parts[1]) }
            if isAddr(parts[1]) { return (parts[1], parts[0]) }
            return (parts[0], parts[1])
        }
        // Fallback: heterogeneous array where the typed data is a JSON object.
        if let parts = try? request.params.get([AnyCodable].self), parts.count >= 2 {
            let strings = parts.map { try? $0.get(String.self) }
            guard let addrIndex = strings.firstIndex(where: { $0.map(isAddr) ?? false }),
                  let address = strings[addrIndex] else { return nil }
            let otherIndex = addrIndex == 0 ? 1 : 0
            if let s = strings[otherIndex] { return (address, s) }
            if let data = try? JSONEncoder().encode(parts[otherIndex]),
               let json = String(data: data, encoding: .utf8) {
                return (address, json)
            }
        }
        return nil
    }

    /// Human summary of EIP-712 typed data for the approval sheet: the domain
    /// name + the primary type + the top-level message fields. The device screen
    /// (or the full signature) remains authoritative.
    static func typedDataPreview(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return json
        }
        var lines: [String] = []
        if let domain = obj["domain"] as? [String: Any] {
            if let name = domain["name"] as? String { lines.append("Domain: \(name)") }
            if let chain = domain["chainId"] { lines.append("Chain: \(chain)") }
            if let vc = domain["verifyingContract"] as? String { lines.append("Contract: \(vc)") }
        }
        if let primary = obj["primaryType"] as? String { lines.append("Type: \(primary)") }
        if let message = obj["message"] as? [String: Any] {
            lines.append("")
            for key in message.keys.sorted() {
                let v = message[key]
                let value: String
                if let s = v as? String { value = s }
                else if let n = v as? NSNumber { value = n.stringValue }
                else { value = "…" }
                lines.append("\(key): \(value)")
            }
        }
        return lines.isEmpty ? json : lines.joined(separator: "\n")
    }

    /// Best-effort wei→ETH for the preview. Values above UInt64 (rare for a
    /// `value` field) fall back to "see device" rather than mislead.
    private static func ethDisplay(fromHexWei hex: String?) -> String {
        let raw = hex ?? "0"
        let s = raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
        if s.isEmpty || s.allSatisfy({ $0 == "0" }) { return "0 ETH" }
        guard let wei = UInt64(s, radix: 16) else { return "see device" }
        return String(format: "%.6f ETH", Double(wei) / 1e18)
    }
}

/// The transaction object a dApp passes to eth_sendTransaction /
/// eth_signTransaction (EIP-1193). All quantities are 0x hex strings; every
/// field is optional because dApps omit whatever the wallet should fill in
/// (nonce, gas, fees). Unknown keys are ignored by the synthesized decoder.
struct WCEthTx: Codable {
    let from: String?
    let to: String?
    let data: String?
    let value: String?
    let gas: String?
    let gasLimit: String?
    let gasPrice: String?
    let maxFeePerGas: String?
    let maxPriorityFeePerGas: String?
    let nonce: String?
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self = Data(bytes)
    }
}
