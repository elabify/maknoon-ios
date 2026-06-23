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
import WalletCore

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
    /// Non-nil when the request fails authentication, blocks confirm.
    @State private var blockedReason: String?
    /// Non-nil while the pre-tap "ready your hardware device" sheet is showing.
    @State private var pendingReadyOp: PendingHardwareOperation?
    /// Re-typed each signing for a host-entry hidden wallet; never stored.
    @State private var signingPassphrase: String = ""
    /// Set once the payment is signed (and the presentation built) but
    /// not yet sent. Hardware shows a Broadcast button on it; software
    /// broadcasts straight through. Holds everything `runBroadcast` needs.
    @State private var pendingBroadcast: PendingBroadcast?
    /// Chain key of the settled payment, for the "View in wallet" deep-link.
    @State private var paidChain: String?

    private var selectedHidden: HardwarePassphraseRef? {
        candidates.first(where: { $0.id == selectedId })?.hidden
    }

    /// A signed-but-unsent payment: the identity disclosure plus the
    /// signed raw tx and its (deterministic, pre-broadcast) hash, so the
    /// merchant can be sent the identity BEFORE any money moves on-chain.
    struct PendingBroadcast {
        let presentation: Presentation
        let rawTx: String
        let txHash: String
        let rail: PaymentRail
        let rpcURLString: String
        let requestId: String
        /// Lightning-only: the holder account that pays the BOLT11 in
        /// runBroadcast (Lightning has no local "sign"; the pay is an
        /// authenticated LNDHub call AFTER the identity post).
        var lightningAccount: LightningAccount? = nil
        /// Bitcoin hardware only: the original unsigned PSBT, needed to finalize
        /// the partially-signed PSBT the device returns (software already
        /// finalizes, so nil there).
        var bitcoinUnsigned: String? = nil
    }

    enum Phase: Equatable { case loading, ready, working, signed, broadcasting, done(String) }

    /// A payer wallet, tagged by chain. EVM carries its Ethereum descriptor +
    /// network + asset; Solana carries its Solana descriptor + network + mint.
    enum PayWallet {
        case ethereum(EthereumWalletDescriptor)
        case solana(SolanaWalletDescriptor)
        case tron(TronWalletDescriptor)
        case bitcoin(BitcoinWalletDescriptor)
        case lightning(LightningAccount)
    }

    struct Candidate: Identifiable {
        let id = UUID()
        let wallet: PayWallet
        let rail: PaymentRail
        let label: String
        /// false => also show a separate gas line (paying a token).
        let assetIsNative: Bool
        // EVM-only (nil for Solana)
        let ethNetwork: EthereumNetwork?
        let ethAsset: CommerceEVMPayment.Asset?
        // Solana-only (nil for EVM)
        let solNetwork: SolanaNetwork?
        let solMint: String?       // nil => native SOL
        let solDecimals: Int
        // Tron-only (nil for EVM/Solana)
        let tronNetwork: TronNetwork?
        let tronTokenContract: String?   // nil => native TRX
        let tronDecimals: Int
        // Bitcoin-only (nil for the others); native BTC, no token field.
        let btcNetwork: BitcoinNetwork?
        var balanceText: String = "…"
        /// Native-coin (gas) balance, always shown so the payer can see they can
        /// cover fees even when paying a token.
        var gasBalanceText: String = "…"
        var sufficient: Bool = false
        var payable: Bool = false
        var note: String?

        /// Trezor host-passphrase ref for the selected hardware wallet (EVM +
        /// Bitcoin; Solana/Tron/Lightning commerce are software-only).
        var hidden: HardwarePassphraseRef? {
            if case .ethereum(let d) = wallet { return d.hidden }
            if case .bitcoin(let d) = wallet { return d.hidden }
            if case .solana(let d) = wallet { return d.hidden }
            if case .tron(let d) = wallet { return d.hidden }
            return nil
        }
        var ethDescriptor: EthereumWalletDescriptor? {
            if case .ethereum(let d) = wallet { return d }
            return nil
        }
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

                if phase == .signed {
                    Section {
                        Label("Signed. Tap Broadcast to send.", systemImage: "checkmark.seal")
                            .font(.callout)
                    } footer: {
                        Text("Broadcast sends your identity to the merchant first; the payment is only sent on-chain once the merchant has received it.")
                            .font(.caption)
                    }
                }
                if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
                if case .done(let tx) = phase {
                    Section { Label("Paid · \(tx.prefix(14))…", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                }
                actionSection
            }
            .navigationTitle("Verify & Pay")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    requiresPassphrase: selectedHidden?.needsHostPassphrase == true,
                    onContinue: { prepare() },
                    onCancel: {},
                    onPassphrase: { signingPassphrase = $0 })
            }
        }
    }

    // MARK: - Actions (all at the bottom of the form, no toolbar buttons)

    /// The one action area, pinned at the bottom of the form. The primary
    /// button advances with the phase: Confirm & Pay -> Broadcast -> Close.
    /// Cancel sits beneath it until the payment is done (then Close is the
    /// only action).
    @ViewBuilder private var actionSection: some View {
        Section {
            switch phase {
            case .working:
                HStack { ProgressView(); Text("Preparing…").foregroundStyle(.secondary) }
            case .broadcasting:
                HStack { ProgressView(); Text("Sending identity, then payment…").foregroundStyle(.secondary) }
            case .signed:
                Button(action: broadcastNow) {
                    Text("Broadcast").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { onClose() }.frame(maxWidth: .infinity)
            case .done:
                // Take the payer to the wallet they paid from so they can watch
                // the tx confirm; falls back to a plain close if the chain is
                // unknown.
                Button(action: {
                    if let key = paidChain, let chain = WalletChain(chainKey: key) {
                        store.selectedTab = .wallet
                        store.walletNavigationPath.append(chain)
                    }
                    onClose()
                }) {
                    Text("View in wallet").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            default:   // .loading, .ready
                Button(action: confirm) {
                    Text("Confirm & Pay").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
                Button("Cancel") { onClose() }.frame(maxWidth: .infinity)
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
            Text("No personal attributes, payment only.").font(.callout).foregroundStyle(.secondary)
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
                // Any wallet is selectable so the payer can inspect each one's
                // balance; canConfirm is what gates on payable + sufficient.
                Button { selectedId = c.id } label: {
                    HStack {
                        Image(systemName: selectedId == c.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedId == c.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.label).font(.callout.weight(.medium))
                            // balanceText already includes the asset ticker.
                            Text("\(c.balanceText) · \(c.rail.displayNetwork)")
                                .font(.caption).foregroundStyle(c.sufficient ? Color.secondary : Color.red)
                            if !c.assetIsNative {
                                Text("Gas: \(c.gasBalanceText)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let note = c.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
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
            if rail.chain == "ethereum", let net = EthereumNetwork(rawValue: rail.network ?? "") {
                let asset = CommerceEVMPayment.Asset(symbol: rail.asset, contract: rail.assetContract,
                                                     decimals: rail.assetDecimals ?? 18)
                for desc in store.ethereumWalletStore.wallets where desc.address != nil {
                    // Both software and hardware (Ledger/Trezor) wallets can pay: the
                    // hardware leg signs on-device over BLE (see confirm()/signOnHardware).
                    var note: String?
                    if case .hardware(let deviceId, _, _) = desc.kind {
                        note = store.devices.find(id: deviceId).map { "Signs on your \($0.kind.displayName)" }
                    }
                    built.append(Candidate(wallet: .ethereum(desc), rail: rail, label: desc.label,
                                           assetIsNative: asset.isNative, ethNetwork: net, ethAsset: asset,
                                           solNetwork: nil, solMint: nil, solDecimals: 0,
                                           tronNetwork: nil, tronTokenContract: nil, tronDecimals: 6,
                                           btcNetwork: nil,
                                           payable: true, note: note))
                }
            } else if rail.chain == "solana", let net = SolanaNetwork(rawValue: rail.network ?? "") {
                // P1: Solana commerce is software-only. Hardware Solana wallets are
                // listed but flagged not-yet-payable.
                let decimals = rail.assetDecimals ?? (rail.assetContract == nil ? 9 : 6)
                for desc in store.solanaWalletStore.wallets {
                    // Software + hardware (Ledger/Trezor) both pay: hardware signs
                    // on-device over BLE (see prepare()).
                    var note: String?
                    if case .hardware(let deviceId, _, _) = desc.kind {
                        note = store.devices.find(id: deviceId).map { "Signs on your \($0.kind.displayName)" }
                    }
                    built.append(Candidate(wallet: .solana(desc), rail: rail, label: desc.label,
                                           assetIsNative: rail.assetContract == nil, ethNetwork: nil, ethAsset: nil,
                                           solNetwork: net, solMint: rail.assetContract, solDecimals: decimals,
                                           tronNetwork: nil, tronTokenContract: nil, tronDecimals: 6,
                                           btcNetwork: nil,
                                           payable: true, note: note))
                }
            } else if rail.chain == "tron", let net = TronNetwork(rawValue: rail.network ?? "") {
                // P1: Tron commerce is software-only. Hardware Tron wallets are
                // listed but flagged not-yet-payable.
                let decimals = rail.assetDecimals ?? 6
                for desc in store.tronWalletStore.wallets {
                    // Software + hardware (Ledger/Trezor) both pay: hardware signs
                    // raw_data on-device over BLE (see prepare()).
                    var note: String?
                    if case .hardware(let deviceId, _, _) = desc.kind {
                        note = store.devices.find(id: deviceId).map { "Signs on your \($0.kind.displayName)" }
                    }
                    built.append(Candidate(wallet: .tron(desc), rail: rail, label: desc.label,
                                           assetIsNative: rail.assetContract == nil, ethNetwork: nil, ethAsset: nil,
                                           solNetwork: nil, solMint: nil, solDecimals: 0,
                                           tronNetwork: net, tronTokenContract: rail.assetContract, tronDecimals: decimals,
                                           btcNetwork: nil,
                                           payable: true, note: note))
                }
            } else if rail.chain == "bitcoin", let net = BitcoinNetwork(rawValue: rail.network ?? "") {
                // P1: Bitcoin commerce is software-only. Hardware Bitcoin wallets
                // are listed but flagged not-yet-payable. Only wallets on the
                // rail's network can pay.
                for desc in store.bitcoinWalletStore.wallets where desc.network == net {
                    // Software + hardware (Ledger/Trezor) both pay: hardware signs
                    // the PSBT on-device over BLE (see prepare()/signOverBLE).
                    var note: String?
                    if case .hardware(let deviceId, _, _) = desc.kind {
                        note = store.devices.find(id: deviceId).map { "Signs on your \($0.kind.displayName)" }
                    }
                    built.append(Candidate(wallet: .bitcoin(desc), rail: rail, label: desc.label,
                                           assetIsNative: true, ethNetwork: nil, ethAsset: nil,
                                           solNetwork: nil, solMint: nil, solDecimals: 0,
                                           tronNetwork: nil, tronTokenContract: nil, tronDecimals: 6,
                                           btcNetwork: net,
                                           payable: true, note: note))
                }
            } else if rail.chain == "lightning" {
                // Custodial LNDHub: any of the holder's Lightning accounts can pay
                // the merchant-minted BOLT11 carried in rail.address.
                for acct in store.lightningAccountStore.accounts {
                    built.append(Candidate(wallet: .lightning(acct), rail: rail, label: acct.label,
                                           assetIsNative: true, ethNetwork: nil, ethAsset: nil,
                                           solNetwork: nil, solMint: nil, solDecimals: 0,
                                           tronNetwork: nil, tronTokenContract: nil, tronDecimals: 6,
                                           btcNetwork: nil,
                                           payable: true, note: nil))
                }
            } else { continue }
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
            do {
                switch c.wallet {
                case .ethereum(let desc):
                    guard let net = c.ethNetwork, let asset = c.ethAsset else { continue }
                    let rpc = store.ethereumSettings.rpcURL(for: net)
                    let wallet = EthereumWallet(descriptor: desc)
                    // Native (gas) balance always read so the payer can see they
                    // can cover fees, even when paying an ERC-20.
                    let native = try await wallet.balance(rpcURL: rpc)
                    candidates[idx].gasBalanceText = native.displayUnits(ticker: net.ticker, decimals: 18, maxDecimals: 6)
                    let bal: EthereumWeiValue
                    if let contract = asset.contract {
                        let token = EthereumToken(network: net, contractAddress: contract,
                                                  symbol: asset.symbol, name: asset.symbol,
                                                  decimals: asset.decimals, curated: false)
                        bal = try await wallet.tokenBalance(token: token, rpcURL: rpc)
                    } else {
                        bal = native
                    }
                    candidates[idx].balanceText = bal.displayUnits(ticker: asset.symbol, decimals: asset.decimals, maxDecimals: 6)
                    if let amount = c.rail.amount, let need = EthereumWeiValue.fromUnits(amount, decimals: asset.decimals) {
                        candidates[idx].sufficient = !(bal < need)
                    }
                case .solana(let desc):
                    guard let net = c.solNetwork else { continue }
                    let rpc = store.solanaSettings.rpcURL(for: net)
                    let wallet = SolanaWallet(descriptor: desc, network: net, rpcURL: rpc, sandwich: store.sandwich)
                    let lamports = try await wallet.refreshBalance(biometricReason: "Show balance")
                    candidates[idx].gasBalanceText = Self.fmtAmount(Double(lamports) / 1_000_000_000, "SOL")
                    if let mint = c.solMint {
                        let accounts = try await wallet.tokenAccounts(biometricReason: "Show balance")
                        let raw = accounts.first(where: { $0.mint == mint })?.amount ?? 0
                        candidates[idx].balanceText = Self.fmtAmount(Double(raw) / pow(10, Double(c.solDecimals)), c.rail.asset)
                        if let amount = c.rail.amount, let need = try? CommerceSolanaPayment.baseUnits(amount, decimals: c.solDecimals) {
                            candidates[idx].sufficient = raw >= need
                        }
                    } else {
                        candidates[idx].balanceText = Self.fmtAmount(Double(lamports) / 1_000_000_000, "SOL")
                        if let amount = c.rail.amount, let need = try? CommerceSolanaPayment.baseUnits(amount, decimals: 9) {
                            candidates[idx].sufficient = lamports >= need
                        }
                    }
                case .tron(let desc):
                    guard let net = c.tronNetwork else { continue }
                    let rpc = store.tronSettings.rpcURL(for: net)
                    let wallet = TronWallet(descriptor: desc, network: net, rpcURL: rpc, sandwich: store.sandwich)
                    let sun = try await wallet.refreshBalance(biometricReason: "Show balance")
                    candidates[idx].gasBalanceText = Self.fmtAmount(Double(sun) / 1_000_000, "TRX")
                    if let contract = c.tronTokenContract {
                        let holder = try await wallet.resolvedAddress(biometricReason: "Show balance")
                        let rawStr = try await TronTRC20TransferBuilder.balance(
                            holderBase58: holder, contractBase58: contract, rpcURL: rpc)
                        let raw = Decimal(string: rawStr) ?? 0
                        let units = (raw as NSDecimalNumber).doubleValue / pow(10, Double(c.tronDecimals))
                        candidates[idx].balanceText = Self.fmtAmount(units, c.rail.asset)
                        if let amount = c.rail.amount,
                           let needStr = try? CommerceTronPayment.baseUnits(amount, decimals: c.tronDecimals),
                           let need = Decimal(string: needStr) {
                            candidates[idx].sufficient = raw >= need
                        }
                    } else {
                        candidates[idx].balanceText = Self.fmtAmount(Double(sun) / 1_000_000, "TRX")
                        if let amount = c.rail.amount, let need = try? CommerceTronPayment.baseUnitsInt64(amount, decimals: 6) {
                            candidates[idx].sufficient = sun >= need
                        }
                    }
                case .bitcoin(let desc):
                    guard let net = c.btcNetwork else { continue }
                    let url = store.bitcoinSettings.electrumURL(for: net)
                    let wallet = try BitcoinWallet.open(descriptor: desc, sandwich: store.sandwich)
                    try await wallet.sync(electrumURL: url)
                    let sats = await wallet.balance().total.toSat()
                    candidates[idx].balanceText = Self.fmtAmount(Double(sats) / 100_000_000, "BTC")
                    candidates[idx].gasBalanceText = candidates[idx].balanceText
                    if let amount = c.rail.amount, let need = try? CommerceBitcoinPayment.satsFromBTC(amount) {
                        candidates[idx].sufficient = sats >= need
                    }
                case .lightning(let acct):
                    guard let pw = (try? store.lightningAccountStore.password(for: acct.id)) ?? nil else {
                        candidates[idx].balanceText = "Re-import account"
                        candidates[idx].payable = false
                        continue
                    }
                    let client = LNDHubClient(account: acct, password: pw)
                    let sats = try await client.balanceSat()
                    candidates[idx].balanceText = "\(sats) sats"
                    candidates[idx].gasBalanceText = candidates[idx].balanceText
                    // The merchant-minted BOLT11 carries the amount; sufficiency
                    // compares the holder's sat balance to the ask (Lightning rail
                    // amounts are in satoshis, not BTC).
                    if let amount = c.rail.amount, let need = Double(amount), need > 0 {
                        candidates[idx].sufficient = Double(sats) >= need
                    } else {
                        candidates[idx].sufficient = true
                    }
                }
            } catch {
                candidates[idx].balanceText = "-"
                candidates[idx].gasBalanceText = "-"
                candidates[idx].sufficient = false
            }
        }
    }

    /// Trim a decimal amount to ≤6 places + ticker (Solana display; EVM uses
    /// EthereumWeiValue.displayUnits).
    private static func fmtAmount(_ x: Double, _ ticker: String) -> String {
        var s = String(format: "%.6f", x)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return "\(s) \(ticker)"
    }

    // MARK: - Confirm (disclose + sign), then Broadcast (send identity, then pay)

    /// Confirm tap. For a hardware wallet, first show the "ready your device"
    /// sheet (so the user can wake + unlock the device); on Continue it runs
    /// `prepare()`. Software prepares immediately.
    private func confirm() {
        guard let cand = candidates.first(where: { $0.id == selectedId }) else {
            error = "Select a wallet to pay from."
            return
        }
        if case .ethereum(let desc) = cand.wallet,
           case .hardware(let deviceId, _, _) = desc.kind,
           let dev = store.devices.find(id: deviceId) {
            pendingReadyOp = PendingHardwareOperation(device: dev, purpose: .ethereumSign)
        } else if case .bitcoin(let desc) = cand.wallet,
                  case .hardware(let deviceId, _, _) = desc.kind,
                  let dev = store.devices.find(id: deviceId) {
            // Show the "ready your device / open the Bitcoin app" prompt (and the
            // Trezor passphrase field for a hidden wallet) before signing.
            pendingReadyOp = PendingHardwareOperation(device: dev, purpose: .bitcoinWallet(network: desc.network))
        } else if case .solana(let desc) = cand.wallet,
                  case .hardware(let deviceId, _, _) = desc.kind,
                  let dev = store.devices.find(id: deviceId) {
            // "Open the Solana app" prompt (+ Trezor passphrase for a hidden wallet).
            pendingReadyOp = PendingHardwareOperation(device: dev, purpose: .solanaSign)
        } else if case .tron(let desc) = cand.wallet,
                  case .hardware(let deviceId, _, _) = desc.kind,
                  let dev = store.devices.find(id: deviceId) {
            // "Open the Tron app" prompt (+ Trezor passphrase for a hidden wallet).
            pendingReadyOp = PendingHardwareOperation(device: dev, purpose: .tronSign)
        } else {
            prepare()
        }
    }

    /// Phase 1: disclose the identity + sign the payment (no money moves
    /// yet). The signed tx and its deterministic pre-broadcast hash are
    /// stashed in `pendingBroadcast`. A hardware wallet then waits for the
    /// user to tap Broadcast; a software wallet (signed inline) runs the
    /// broadcast straight through.
    private func prepare() {
        guard let matched, let cand = candidates.first(where: { $0.id == selectedId }),
              let amount = cand.rail.amount else {
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
                // Sign WITHOUT broadcasting; capture the pre-broadcast settlement
                // ref (EVM: keccak txHash; Solana: first signature) so the
                // merchant gets identity + ref before any money moves.
                let pending: PendingBroadcast
                var isSoftware = true
                switch cand.wallet {
                case .ethereum(let desc):
                    guard let from = desc.address, let net = cand.ethNetwork else {
                        throw CommercePayError("This wallet has no resolved address.")
                    }
                    if case .hardware = desc.kind { isSoftware = false }
                    let rpc = store.ethereumSettings.rpcURL(for: net)
                    let raw = try await signedRawTransfer(cand: cand, from: from, amount: amount, rpcURLString: rpc)
                    pending = PendingBroadcast(presentation: presentation, rawTx: raw,
                                               txHash: Self.ethTxHash(rawHex: raw), rail: cand.rail,
                                               rpcURLString: rpc, requestId: request.verifierRequest.requestId)
                case .solana(let desc):
                    guard let net = cand.solNetwork else {
                        throw CommercePayError("Unlock your identity to pay.")
                    }
                    let rpc = store.solanaSettings.rpcURL(for: net)
                    switch desc.kind {
                    case .software(let account):
                        guard let sandwich = store.sandwich else {
                            throw CommercePayError("Unlock your identity to pay.")
                        }
                        let signed = try await CommerceSolanaPayment.buildSignedTransfer(
                            sandwich: sandwich, account: account, rpcURLString: rpc,
                            recipient: cand.rail.address, amount: amount, mint: cand.solMint,
                            decimals: cand.solDecimals, biometricReason: "Authorize \(amount) \(cand.rail.asset) payment")
                        pending = PendingBroadcast(presentation: presentation, rawTx: signed.signed,
                                                   txHash: signed.signature, rail: cand.rail,
                                                   rpcURLString: rpc, requestId: request.verifierRequest.requestId)
                    case .hardware(let deviceId, let account, let pubkeyBase58):
                        isSoftware = false
                        guard let dev = store.devices.find(id: deviceId) else {
                            throw CommercePayError("Hardware device record is missing. Re-register it in Settings → Devices.")
                        }
                        guard let pubkeyBytes = WalletCore.Base58.decodeNoCheck(string: pubkeyBase58), pubkeyBytes.count == 32 else {
                            throw CommercePayError("Stored signer public key did not decode as 32 bytes.")
                        }
                        // Connect the device (serial guard + Trezor passphrase +
                        // derivation override), then sign on-device over BLE.
                        let hardware = HardwareWalletFactory.make(kind: dev.kind == .ledger ? .ledger : .trezor)
                        if let trezor = hardware as? TrezorBLE {
                            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(desc.hidden, hostEntered: signingPassphrase))
                        }
                        hardware.setDerivationPathOverride(desc.derivationPath)
                        hardware.beginSession()
                        defer { hardware.endSession() }
                        let connected = try await hardware.identifyDevice()
                        guard connected == dev.serial else {
                            throw IdentityWrapError.deviceSerialMismatch(expected: dev.serial, actual: connected)
                        }
                        let wallet = SolanaWallet(descriptor: desc, network: net, rpcURL: rpc, sandwich: store.sandwich)
                        let signedB64: String
                        if let mint = cand.solMint {
                            let raw = try CommerceSolanaPayment.baseUnits(amount, decimals: cand.solDecimals)
                            signedB64 = try await wallet.prepareHardwareSPLToken(
                                mint: mint, decimals: UInt8(cand.solDecimals), rawAmount: raw,
                                recipient: cand.rail.address, priorityFeeMicroLamports: 0,
                                ledger: hardware, signerBase58: pubkeyBase58,
                                signerPublicKey: pubkeyBytes, account: account)
                        } else {
                            let lamports = try CommerceSolanaPayment.baseUnits(amount, decimals: 9)
                            signedB64 = try await wallet.prepareHardwareNative(
                                recipient: cand.rail.address, lamports: lamports, priorityFeeMicroLamports: 0,
                                ledger: hardware, signerBase58: pubkeyBase58,
                                signerPublicKey: pubkeyBytes, account: account)
                        }
                        guard let ref = CommerceSolanaPayment.transactionSignature(signedBase64: signedB64) else {
                            throw CommercePayError("Could not read the transaction signature.")
                        }
                        pending = PendingBroadcast(presentation: presentation, rawTx: signedB64,
                                                   txHash: ref, rail: cand.rail,
                                                   rpcURLString: rpc, requestId: request.verifierRequest.requestId)
                    }
                case .tron(let desc):
                    guard let net = cand.tronNetwork else {
                        throw CommercePayError("Unlock your identity to pay.")
                    }
                    let rpc = store.tronSettings.rpcURL(for: net)
                    let wallet = TronWallet(descriptor: desc, network: net, rpcURL: rpc, sandwich: store.sandwich)
                    let reason = "Authorize \(amount) \(cand.rail.asset) payment"
                    switch desc.kind {
                    case .software:
                        let signedJSON: String
                        if let contract = cand.tronTokenContract {
                            let raw = try CommerceTronPayment.baseUnits(amount, decimals: cand.tronDecimals)
                            signedJSON = try await wallet.prepareSoftwareTRC20(
                                contractAddress: contract, rawAmount: raw,
                                recipient: cand.rail.address, biometricReason: reason)
                        } else {
                            let sun = try CommerceTronPayment.baseUnitsInt64(amount, decimals: 6)
                            signedJSON = try await wallet.prepareSoftwareNative(
                                recipient: cand.rail.address, sunAmount: sun,
                                feeLimitSun: 1_000_000, biometricReason: reason)
                        }
                        let txID = try CommerceTronPayment.txID(fromSignedJSON: signedJSON)
                        pending = PendingBroadcast(presentation: presentation, rawTx: signedJSON,
                                                   txHash: txID, rail: cand.rail,
                                                   rpcURLString: rpc, requestId: request.verifierRequest.requestId)
                    case .hardware(let deviceId, let account, let senderBase58):
                        isSoftware = false
                        guard let dev = store.devices.find(id: deviceId) else {
                            throw CommercePayError("Hardware device record is missing. Re-register it in Settings → Devices.")
                        }
                        // Connect the device (serial guard + Trezor passphrase +
                        // derivation override), then sign raw_data on-device (Ledger
                        // OR Trezor) and assemble the signed wire JSON.
                        let hardware = HardwareWalletFactory.make(kind: dev.kind == .ledger ? .ledger : .trezor)
                        if let trezor = hardware as? TrezorBLE {
                            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(desc.hidden, hostEntered: signingPassphrase))
                        }
                        hardware.setDerivationPathOverride(desc.derivationPath)
                        hardware.beginSession()
                        defer { hardware.endSession() }
                        let connected = try await hardware.identifyDevice()
                        guard connected == dev.serial else {
                            throw IdentityWrapError.deviceSerialMismatch(expected: dev.serial, actual: connected)
                        }
                        let signedAndSig: TronDescriptors.TronUnsignedAndSignature
                        if let contract = cand.tronTokenContract {
                            let raw = try CommerceTronPayment.baseUnits(amount, decimals: cand.tronDecimals)
                            signedAndSig = try await wallet.prepareHardwareTRC20(
                                contractAddress: contract, recipient: cand.rail.address,
                                rawAmount: raw, feeLimitSun: 100_000_000,
                                ledger: hardware, senderBase58: senderBase58, account: account)
                        } else {
                            let sun = try CommerceTronPayment.baseUnitsInt64(amount, decimals: 6)
                            signedAndSig = try await wallet.prepareHardwareNative(
                                recipient: cand.rail.address, sunAmount: sun, feeLimitSun: 1_000_000,
                                ledger: hardware, senderBase58: senderBase58, account: account)
                        }
                        let signedJSON = try CommerceTronPayment.assembleSignedJSON(
                            envelopeJSON: signedAndSig.envelopeJSON, signatureRSV: signedAndSig.signatureRSV)
                        let txID = try CommerceTronPayment.txID(fromSignedJSON: signedJSON)
                        pending = PendingBroadcast(presentation: presentation, rawTx: signedJSON,
                                                   txHash: txID, rail: cand.rail,
                                                   rpcURLString: rpc, requestId: request.verifierRequest.requestId)
                    }
                case .bitcoin(let desc):
                    guard let net = cand.btcNetwork else {
                        throw CommercePayError("Unlock your identity to pay.")
                    }
                    let url = store.bitcoinSettings.electrumURL(for: net)
                    let feeBase = store.bitcoinSettings.mempoolURL(for: net)
                    let rec = (try? await BitcoinFeeEstimator.fetch(baseURL: feeBase)) ?? BitcoinFeeEstimator.fallback
                    let feeRate = max(rec.satsPerVb(for: .halfHour), 1)
                    let sats = try CommerceBitcoinPayment.satsFromBTC(amount)
                    switch desc.kind {
                    case .software(let account):
                        guard let sandwich = store.sandwich else {
                            throw CommercePayError("Unlock your identity to pay.")
                        }
                        let signed = try await CommerceBitcoinPayment.buildSignedTransfer(
                            descriptor: desc, sandwich: sandwich, account: account,
                            recipient: cand.rail.address, amountSat: sats, feeRateSatsPerVb: feeRate, electrumURL: url)
                        pending = PendingBroadcast(presentation: presentation, rawTx: signed.signed,
                                                   txHash: signed.txid, rail: cand.rail,
                                                   rpcURLString: url, requestId: request.verifierRequest.requestId)
                    case .hardware(let deviceId, let fingerprint, let xpub):
                        isSoftware = false
                        guard let device = store.devices.find(id: deviceId) else {
                            throw CommercePayError("Hardware device record is missing. Re-register it in Settings → Devices.")
                        }
                        // Build the unsigned PSBT (watch-only), sign it on the
                        // device over BLE, then finalize for the txid + broadcast.
                        let unsigned = try await CommerceBitcoinPayment.buildUnsignedForHardware(
                            descriptor: desc, recipient: cand.rail.address,
                            amountSat: sats, feeRateSatsPerVb: feeRate, electrumURL: url)
                        let signedB64 = try await BitcoinSigningHelpers.signOverBLE(
                            unsignedBase64: unsigned, device: device,
                            fingerprintHex: fingerprint, accountXpub: xpub, network: net,
                            hidden: desc.hidden, derivationPath: desc.derivationPath,
                            hostEntered: signingPassphrase)
                        let txid = try CommerceBitcoinPayment.txid(fromSignedPSBT: signedB64, unsignedPSBT: unsigned)
                        pending = PendingBroadcast(presentation: presentation, rawTx: signedB64,
                                                   txHash: txid, rail: cand.rail,
                                                   rpcURLString: url, requestId: request.verifierRequest.requestId,
                                                   bitcoinUnsigned: unsigned)
                    }
                case .lightning(let acct):
                    // No local signing. The settlement ref is the merchant-minted
                    // BOLT11 (rail.address); the pay is an authenticated LNDHub
                    // call in runBroadcast, AFTER the identity post. The merchant
                    // matches the payment to the invoice it issued.
                    let bolt11 = cand.rail.address
                    guard !bolt11.isEmpty else {
                        throw CommercePayError("Merchant did not provide a Lightning invoice.")
                    }
                    pending = PendingBroadcast(presentation: presentation, rawTx: bolt11,
                                               txHash: bolt11, rail: cand.rail,
                                               rpcURLString: "", requestId: request.verifierRequest.requestId,
                                               lightningAccount: acct)
                }
                pendingBroadcast = pending
                if isSoftware {
                    await runBroadcast(pending)   // one-tap, like other software sends
                } else {
                    phase = .signed               // hardware waits for the Broadcast tap
                }
            } catch {
                self.error = "\(error.localizedDescription)"
                phase = .ready
            }
        }
    }

    /// Broadcast tap (hardware) or straight-through call (software).
    private func broadcastNow() {
        guard let pending = pendingBroadcast else { return }
        Task { await runBroadcast(pending) }
    }

    /// Phase 2: send the identity to the merchant FIRST, then move money
    /// on-chain only if the merchant actually received it. If the identity
    /// post fails we never broadcast, so the payer never pays into a void.
    @MainActor
    private func runBroadcast(_ pending: PendingBroadcast) async {
        phase = .broadcasting
        error = nil
        do {
            // 1. Send the identity. Seal to the merchant's published key so
            //    the relay stays blind.
            guard let pub = request.paymentTerms.responseKey else {
                throw CommerceTransportError.decode("merchant did not provide an encryption key")
            }
            let serverResponse = CommerceServerResponse(
                requestId: pending.requestId, presentation: pending.presentation,
                payment: .init(rail: pending.rail, txHash: pending.txHash))
            let sealed = try CommerceSeal.seal(serverResponse, toPublicKeyBase64: pub, requestId: pending.requestId)
            try await CommerceTransport.postResponse(baseURL: responseBaseURL, sealed)
            // 2. Identity received -> send the payment on-chain (per chain).
            let onChain: String
            if pending.rail.chain == "solana" {
                onChain = try await CommerceSolanaPayment.broadcast(pending.rawTx, rpcURLString: pending.rpcURLString)
            } else if pending.rail.chain == "tron" {
                onChain = try await CommerceTronPayment.broadcast(pending.rawTx, rpcURLString: pending.rpcURLString)
            } else if pending.rail.chain == "bitcoin" {
                onChain = try await CommerceBitcoinPayment.broadcast(
                    pending.rawTx, unsignedB64: pending.bitcoinUnsigned, electrumURL: pending.rpcURLString)
            } else if pending.rail.chain == "lightning" {
                guard let acct = pending.lightningAccount,
                      let pw = (try? store.lightningAccountStore.password(for: acct.id)) ?? nil else {
                    throw CommercePayError("Lightning account is unavailable. Re-import it under Wallet.")
                }
                let client = LNDHubClient(account: acct, password: pw)
                // Pay the merchant's invoice (it carries the amount). NO retry on
                // failure: a re-pay could double-spend if the first attempt
                // actually settled (matches the Lightning send screen).
                let result = try await client.payInvoice(pending.rawTx, amountSat: nil)
                onChain = result.preimage
            } else {
                onChain = try await CommerceEVMPayment.broadcast(pending.rawTx, rpcURLString: pending.rpcURLString)
            }
            paidChain = pending.rail.chain
            phase = .done(onChain)
        } catch {
            self.error = "\(error.localizedDescription)"
            // Keep the signed tx so the user can retry Broadcast; nothing was
            // paid unless the identity post AND the broadcast both succeeded.
            phase = pendingBroadcast != nil ? .signed : .ready
        }
    }

    /// Deterministic EIP-1559 transaction hash = keccak256(signed raw tx).
    /// Computed locally so the merchant can be handed the txHash before the
    /// tx is broadcast.
    private static func ethTxHash(rawHex: String) -> String {
        let hex = rawHex.hasPrefix("0x") ? String(rawHex.dropFirst(2)) : rawHex
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
            i = j
        }
        return "0x" + Hash.keccak256(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Route the payment signing on the wallet kind, returning the raw signed
    /// EIP-1559 transaction hex for broadcast.
    private func signedRawTransfer(cand: Candidate, from: String, amount: String, rpcURLString: String) async throws -> String {
        // EVM-only path (Solana signs in prepare() via CommerceSolanaPayment).
        guard let desc = cand.ethDescriptor, let asset = cand.ethAsset else {
            throw CommercePayError("Unsupported wallet for this rail.")
        }
        let reason = "Authorize \(amount) \(asset.symbol) payment"
        switch desc.kind {
        case .software(let account):
            guard let sandwich = store.sandwich else { throw CommercePayError("Unlock your identity to pay.") }
            return try await CommerceEVMPayment.buildSignedTransfer(
                sandwich: sandwich, account: account, from: from, rpcURLString: rpcURLString,
                recipient: cand.rail.address, amount: amount, asset: asset, biometricReason: reason)
        case .hardware(let deviceId, let account, _):
            return try await signOnHardware(deviceId: deviceId, account: account, from: from,
                                            recipient: cand.rail.address, amount: amount,
                                            asset: asset, rpcURLString: rpcURLString,
                                            hidden: desc.hidden,
                                            derivationPath: desc.derivationPath,
                                            hostEntered: signingPassphrase)
        }
    }

    /// Sign on a Ledger/Trezor over BLE: build the unsigned envelope, get V/R/S
    /// from the device (clear-signing ERC-20 when a token descriptor is bundled),
    /// then reassemble the signed envelope. Mirrors EthereumSendView.signOnHardware.
    private func signOnHardware(deviceId: UUID, account: UInt32, from: String,
                                recipient: String, amount: String,
                                asset: CommerceEVMPayment.Asset, rpcURLString: String,
                                hidden: HardwarePassphraseRef? = nil,
                                derivationPath: String? = nil,
                                hostEntered: String? = nil) async throws -> String {
        guard let dev = store.devices.find(id: deviceId) else {
            throw CommercePayError("Hardware device record is missing. Re-register it in Settings → Devices.")
        }
        let plan = try await CommerceEVMPayment.buildPlan(
            from: from, rpcURLString: rpcURLString, recipient: recipient, amount: amount, asset: asset)
        let hardware = HardwareWalletFactory.make(kind: dev.kind == .ledger ? .ledger : .trezor)
        // A hidden (passphrase) or custom-path wallet must re-derive in
        // its own session before signing; standard wallets resolve to
        // `.standard` / nil. Ledger / mock clients ignore the passphrase.
        if let trezor = hardware as? TrezorBLE {
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
        }
        hardware.setDerivationPathOverride(derivationPath)
        // Pin one BLE/THP session across identify + sign. Without it,
        // identify tears the link down and the sign reconnects
        // immediately (the plan is built before identify, so there is no
        // network round-trip in between), racing the half-closed BLE
        // link so the fresh THP handshake reads a stale frame ("handshake
        // init response has the wrong size"). Pinning keeps the link up.
        hardware.beginSession()
        defer { hardware.endSession() }
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
        guard let c else { return "-" }
        if key == "sdnScreen", let obj = c.claims[key]?.anyValue as? [String: Any] {
            let result = (obj["result"] as? String) ?? "?"
            let when = (obj["screenedAt"] as? String).map { String($0.prefix(10)) } ?? ""
            return when.isEmpty ? "Sanctions: \(result)" : "Sanctions: \(result) (screened \(when))"
        }
        return c.claims[key]?.displayText ?? "-"
    }
}

/// Lightweight error for payment-preparation failures surfaced in the sheet.
private struct CommercePayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
