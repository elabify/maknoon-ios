// Single-confirm "Verify & Pay" (ADR-0031). The payer scans the merchant's
// short URL (from Identity -> Scan verifier), and this one sheet shows: the
// merchant (a Point of Sale), the requested identity fields + the matching VC,
// the amount/asset/network, and a proposal of the payer's wallets with balances
// that can pay. One Confirm discloses the identity AND signs + broadcasts the
// payment, then posts the response for the merchant to poll.
//
// P1: EVM software wallets are payable. Ledger (hardware) and non-EVM wallets
// are shown but flagged "not yet payable on this device".

import SwiftUI

struct CommercePaySheet: View {
    let store: HolderStore
    let request: CommerceRequest
    /// Origin of the scanned request_uri; the response is posted here.
    let responseBaseURL: URL
    let onClose: () -> Void

    @State private var matched: Credential?
    @State private var candidates: [Candidate] = []
    @State private var selectedId: UUID?
    @State private var phase: Phase = .loading
    @State private var error: String?
    @State private var trustLabel: String?
    @State private var trustTier: CommerceRequestValidator.Tier = .unknown
    /// Non-nil when the request fails authentication — blocks confirm.
    @State private var blockedReason: String?
    /// Non-nil while the pre-tap "ready your hardware device" sheet is showing.
    @State private var pendingReadyOp: PendingHardwareOperation?

    enum Phase: Equatable { case loading, ready, working, done(String) }

    struct Candidate: Identifiable {
        let id = UUID()
        let descriptor: EthereumWalletDescriptor
        let rail: PaymentRail
        let network: EthereumNetwork
        let asset: CommerceEVMPayment.Asset
        var balanceText: String = "…"
        var sufficient: Bool = false
        var payable: Bool = false   // EVM software only for now
        var note: String?
    }

    private var terms: PaymentTerms { request.paymentTerms }
    private var requiredClaims: [String] { request.verifierRequest.filter.requiredClaims }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.merchantName ?? "Merchant").font(.headline)
                    if let trustLabel {
                        Label(trustLabel, systemImage: Self.trustIcon(tier: trustTier, blocked: blockedReason != nil))
                            .font(.caption)
                            .foregroundStyle(Self.trustColor(tier: trustTier, blocked: blockedReason != nil))
                    }
                    if let blockedReason {
                        Text(blockedReason).font(.caption).foregroundStyle(.red)
                    }
                } header: { Text("Requested by") }

                Section { paymentRows } header: { Text("Payment") }

                Section { identityRows } header: { Text("You will share") } footer: {
                    Text("One confirmation shares the attributes above and pays from the selected wallet. Your keys never leave this device.")
                        .font(.caption)
                }

                Section { walletRows } header: { Text("Pay from") }

                if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
                if case .done(let tx) = phase {
                    Section { Label("Paid · \(tx.prefix(14))…", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Verify & Pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onClose() } }
                ToolbarItem(placement: .confirmationAction) {
                    if case .done = phase {
                        Button("Done") { onClose() }
                    } else {
                        Button(action: confirm) {
                            if phase == .working { ProgressView() } else { Text("Confirm & Pay") }
                        }
                        .disabled(!canConfirm)
                    }
                }
            }
            .task { await load() }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    onContinue: { pay() },
                    onCancel: {})
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder private var paymentRows: some View {
        // The merchant fully specifies the crypto amount on each rail, so show
        // that (the selected rail, else the first offered) as the primary amount
        // regardless of wallet selection. Fiat is shown only when the merchant
        // provided a non-zero notional (testnets have no fiat rate).
        let rail = candidates.first(where: { $0.id == selectedId })?.rail ?? terms.acceptedRails.first
        if let rail, let amt = rail.amount {
            HStack { Text("Amount").foregroundStyle(.secondary); Spacer()
                Text("\(amt) \(rail.asset)").font(.callout.weight(.semibold)) }
            HStack { Text("Network").foregroundStyle(.secondary); Spacer()
                Text(rail.displayNetwork).font(.callout).foregroundStyle(.secondary) }
        }
        if terms.hasFiatValue {
            HStack { Text("Fiat value").foregroundStyle(.secondary); Spacer()
                Text("\(terms.fiatAmount) \(terms.fiatCode)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var identityRows: some View {
        if matched == nil {
            Text("You don't have a verified credential matching this request.")
                .font(.callout).foregroundStyle(.red)
        } else if requiredClaims.isEmpty {
            Text("No personal attributes — payment only.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(requiredClaims, id: \.self) { key in
                HStack(alignment: .top) {
                    Text(key).font(.callout.weight(.medium))
                    Spacer(minLength: 12)
                    Text(Self.attrValue(matched, key)).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder private var walletRows: some View {
        if phase == .loading {
            HStack { ProgressView(); Text("Finding wallets…").foregroundStyle(.secondary) }
        } else if candidates.isEmpty {
            Text("No wallet of yours can pay the requested asset/network.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(candidates) { c in
                Button { if c.payable && c.sufficient { selectedId = c.id } } label: {
                    HStack {
                        Image(systemName: selectedId == c.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(c.payable && c.sufficient ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.descriptor.label).font(.callout.weight(.medium))
                            Text("\(c.balanceText) \(c.asset.symbol) · \(c.network.rawValue)")
                                .font(.caption).foregroundStyle(c.sufficient ? Color.secondary : Color.red)
                            if let note = c.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!(c.payable && c.sufficient))
            }
        }
    }

    private var canConfirm: Bool {
        phase == .ready && matched != nil && blockedReason == nil
            && candidates.first(where: { $0.id == selectedId })?.payable == true
            && candidates.first(where: { $0.id == selectedId })?.sufficient == true
    }

    // MARK: - Load (match VC + enumerate wallets + balances)

    @MainActor private func load() async {
        // Authenticate the request + the merchant's signature over the payment
        // terms (incl. the responseKey we'll seal to) BEFORE trusting anything.
        let v = await CommerceRequestValidator.validate(request, registryHost: HolderStore.elabifyDropHost)
        trustLabel = v.tierLabel
        trustTier = v.tier
        if !v.ok { blockedReason = v.reason }

        matched = MatchingEngine.match(credentials: store.credentials, filter: request.verifierRequest.filter).first
        // Build candidates: each accepted EVM rail x each EVM wallet with an address.
        var built: [Candidate] = []
        for rail in terms.acceptedRails {
            guard rail.chain == "ethereum", let net = EthereumNetwork(rawValue: rail.network ?? "") else { continue }
            let asset = CommerceEVMPayment.Asset(symbol: rail.asset, contract: rail.assetContract,
                                                 decimals: rail.assetDecimals ?? 18)
            for desc in store.ethereumWalletStore.wallets where desc.address != nil {
                // Both software and hardware (Ledger/Trezor) wallets can pay: the
                // hardware leg signs on-device over BLE (see confirm()/signOnHardware).
                var note: String?
                if case .hardware(let deviceId, _, _) = desc.kind {
                    note = store.devices.find(id: deviceId).map { "Signs on your \($0.kind.displayName)" }
                }
                built.append(Candidate(descriptor: desc, rail: rail, network: net, asset: asset,
                                       payable: true, note: note))
            }
        }
        candidates = built
        phase = .ready
        await fetchBalances()
        // Auto-select the first payable wallet with sufficient funds.
        selectedId = candidates.first(where: { $0.payable && $0.sufficient })?.id
    }

    @MainActor private func fetchBalances() async {
        for idx in candidates.indices {
            let c = candidates[idx]
            let rpc = store.ethereumSettings.rpcURL(for: c.network)
            let wallet = EthereumWallet(descriptor: c.descriptor)
            do {
                let bal: EthereumWeiValue
                if let contract = c.asset.contract {
                    let token = EthereumToken(network: c.network, contractAddress: contract,
                                              symbol: c.asset.symbol, name: c.asset.symbol,
                                              decimals: c.asset.decimals, curated: false)
                    bal = try await wallet.tokenBalance(token: token, rpcURL: rpc)
                } else {
                    bal = try await wallet.balance(rpcURL: rpc)
                }
                candidates[idx].balanceText = bal.displayUnits(ticker: c.asset.symbol, decimals: c.asset.decimals, maxDecimals: 6)
                if let amount = c.rail.amount, let need = EthereumWeiValue.fromUnits(amount, decimals: c.asset.decimals) {
                    candidates[idx].sufficient = !(bal < need)
                }
            } catch {
                candidates[idx].balanceText = "—"
                candidates[idx].sufficient = false
            }
        }
    }

    // MARK: - Confirm (disclose + sign + broadcast + post)

    /// Confirm tap. For a hardware wallet, first show the "ready your device"
    /// sheet (so the user can wake + unlock the Ledger and open the Ethereum app
    /// before BLE opens); on Continue it runs `pay()`. Software pays immediately.
    private func confirm() {
        guard let cand = candidates.first(where: { $0.id == selectedId }) else {
            error = "Select a wallet to pay from."
            return
        }
        if case .hardware(let deviceId, _, _) = cand.descriptor.kind,
           let dev = store.devices.find(id: deviceId) {
            pendingReadyOp = PendingHardwareOperation(device: dev, purpose: .ethereumSign)
        } else {
            pay()
        }
    }

    /// Disclose the identity, sign the payment (software or hardware), broadcast,
    /// then seal + post the response for the merchant to poll.
    private func pay() {
        guard let matched, let cand = candidates.first(where: { $0.id == selectedId }),
              let from = cand.descriptor.address, let amount = cand.rail.amount else {
            error = "Couldn't prepare the payment."
            return
        }
        phase = .working
        error = nil
        Task {
            do {
                // The identity disclosure always uses the holder's consumer
                // identity sandwich, even when the PAYMENT wallet is hardware.
                let presentation = try await PresentationFactory.build(
                    credential: matched,
                    selectedClaims: Set(requiredClaims),
                    challenge: request.verifierRequest.challenge,
                    verifierDid: request.verifierRequest.verifierDid,
                    pendingRequest: request.verifierRequest,
                    store: store)
                let rpc = store.ethereumSettings.rpcURL(for: cand.network)
                let raw = try await signedRawTransfer(cand: cand, from: from, amount: amount, rpcURLString: rpc)
                let txHash = try await CommerceEVMPayment.broadcast(raw, rpcURLString: rpc)
                let requestId = request.verifierRequest.requestId
                let serverResponse = CommerceServerResponse(
                    requestId: requestId, presentation: presentation,
                    payment: .init(rail: cand.rail, txHash: txHash))
                // Seal to the merchant's published key so the relay stays blind.
                guard let pub = request.paymentTerms.responseKey else {
                    throw CommerceTransportError.decode("merchant did not provide an encryption key")
                }
                let sealed = try CommerceSeal.seal(serverResponse, toPublicKeyBase64: pub, requestId: requestId)
                try await CommerceTransport.postResponse(baseURL: responseBaseURL, sealed)
                phase = .done(txHash)
            } catch {
                self.error = "\(error.localizedDescription)"
                phase = .ready
            }
        }
    }

    /// Route the payment signing on the wallet kind, returning the raw signed
    /// EIP-1559 transaction hex for broadcast.
    private func signedRawTransfer(cand: Candidate, from: String, amount: String, rpcURLString: String) async throws -> String {
        let reason = "Authorize \(amount) \(cand.asset.symbol) payment"
        switch cand.descriptor.kind {
        case .software(let account):
            guard let sandwich = store.sandwich else { throw CommercePayError("Unlock your identity to pay.") }
            return try await CommerceEVMPayment.buildSignedTransfer(
                sandwich: sandwich, account: account, from: from, rpcURLString: rpcURLString,
                recipient: cand.rail.address, amount: amount, asset: cand.asset, biometricReason: reason)
        case .hardware(let deviceId, let account, _):
            return try await signOnHardware(deviceId: deviceId, account: account, from: from,
                                            recipient: cand.rail.address, amount: amount,
                                            asset: cand.asset, rpcURLString: rpcURLString)
        }
    }

    /// Sign on a Ledger/Trezor over BLE: build the unsigned envelope, get V/R/S
    /// from the device (clear-signing ERC-20 when a token descriptor is bundled),
    /// then reassemble the signed envelope. Mirrors EthereumSendView.signOnHardware.
    private func signOnHardware(deviceId: UUID, account: UInt32, from: String,
                                recipient: String, amount: String,
                                asset: CommerceEVMPayment.Asset, rpcURLString: String) async throws -> String {
        guard let dev = store.devices.find(id: deviceId) else {
            throw CommercePayError("Hardware device record is missing. Re-register it in Settings → Devices.")
        }
        let plan = try await CommerceEVMPayment.buildPlan(
            from: from, rpcURLString: rpcURLString, recipient: recipient, amount: amount, asset: asset)
        let hardware = HardwareWalletFactory.make(kind: dev.kind == .ledger ? .ledger : .trezor)
        let connected = try await hardware.identifyDevice()
        guard connected == dev.serial else {
            throw IdentityWrapError.deviceSerialMismatch(expected: dev.serial, actual: connected)
        }
        let unsigned = EthereumTxEncoder.unsignedEnvelope(plan: plan)
        let erc20Descriptor: Data?
        if case .erc20 = plan.payload {
            erc20Descriptor = LedgerERC20Descriptors.descriptor(chainId: plan.chainId, contract: plan.toAddress)
        } else {
            erc20Descriptor = nil
        }
        let (v, r, s) = try await hardware.signEthereumTransaction(
            envelope: unsigned, account: account, erc20Descriptor: erc20Descriptor)
        let signed = EthereumTxEncoder.signedEnvelope(plan: plan, v: v, r: r, s: s)
        return "0x" + signed.map { String(format: "%02x", $0) }.joined()
    }

    // Green only for a registry-verified merchant; orange for self-signed (the
    // signature is valid but the identity is unvouched); red when blocked.
    private static func trustColor(tier: CommerceRequestValidator.Tier, blocked: Bool) -> Color {
        if blocked { return .red }
        return tier == .registered ? .green : .orange
    }

    private static func trustIcon(tier: CommerceRequestValidator.Tier, blocked: Bool) -> String {
        if blocked { return "xmark.shield.fill" }
        return tier == .registered ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private static func attrValue(_ c: Credential?, _ key: String) -> String {
        guard let c else { return "—" }
        if key == "sdnScreen", let obj = c.claims[key]?.anyValue as? [String: Any] {
            let result = (obj["result"] as? String) ?? "?"
            let when = (obj["screenedAt"] as? String).map { String($0.prefix(10)) } ?? ""
            return when.isEmpty ? "Sanctions: \(result)" : "Sanctions: \(result) (screened \(when))"
        }
        return c.claims[key]?.displayText ?? "—"
    }
}

/// Lightweight error for payment-preparation failures surfaced in the sheet.
private struct CommercePayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
