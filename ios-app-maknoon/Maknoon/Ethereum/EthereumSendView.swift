// Ethereum send sheet. Native-token transfer only in Phase 2 (no
// ERC-20 yet). Mirrors BitcoinSendView's shape: pay-to with paste +
// QR scan, amount in native ticker, three-tier gas picker, review
// section showing total cost + max fee, single Send button that
// runs nonce / estimate / sign / broadcast under one biometric
// prompt.
//
// Hardware wallets surface the disabled hardware-not-implemented
// path. Phase 2.1 will add Ledger SIGN_TRANSACTION over BLE.

import SwiftUI

struct EthereumSendView: View {
    let wallet: EthereumWallet
    /// nil = native ETH (or chain ticker) transfer. Non-nil = the
    /// caller pre-bound the sheet to a specific ERC-20 token; the
    /// amount field uses the token's decimals + symbol, the balance
    /// row queries the token contract, and the broadcast path
    /// routes through the ERC-20 transfer payload.
    /// The asset being sent: nil = native ETH (or chain ticker); non-nil = an
    /// ERC-20. Seeded from the init param and then USER-SWITCHABLE via the asset
    /// dropdown (ADR-0033 Phase 2b round-2). All asset-dependent reads (ticker,
    /// decimals, balance, CoinGecko id, native-vs-ERC20 branch) key off this.
    @State private var token: EthereumToken?
    let onBroadcast: (String) -> Void

    init(wallet: EthereumWallet, token: EthereumToken? = nil, onBroadcast: @escaping (String) -> Void) {
        self.wallet = wallet
        self._token = State(initialValue: token)
        self.onBroadcast = onBroadcast
    }

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var recipient: String = ""
    @State private var amountStr: String = ""
    /// Currently-selected denomination for the amount field. Either
    /// the asset's native ticker (ETH / USDC / …) or the user's
    /// preferred fiat ISO code (USD / AED / …). Initialized in
    /// `.onAppear` because @State can't reach `ticker` at init.
    @State private var amountDenomination: String = ""
    @State private var selectedTier: EthereumGasEstimator.Tier = .standard
    @State private var estimates: [EthereumGasEstimator.Tier: EthereumGasEstimator.Estimate] = [:]
    @State private var gasUnits: UInt64?
    @State private var nativeBalance: EthereumWeiValue?
    @State private var tokenBalance: EthereumWeiValue?
    @State private var loadingFees: Bool = true
    @State private var submitting: Bool = false
    /// Re-typed each signing for a host-entry hidden wallet; never stored.
    @State private var signingPassphrase: String = ""
    /// Hardware path only: raw signed tx returned by the device,
    /// held until the user taps Broadcast. Mirrors the BTC / SOL /
    /// TRX flow so the user gets one explicit "I'm about to put
    /// this on chain" moment after the device signs. Cleared on
    /// failure / cancel / successful broadcast.
    @State private var signedRawTx: String?
    @State private var lastError: String?
    /// Populated when the user taps Send on a hardware-backed wallet,
    /// before Maknoon opens BLE. Drives the pre-tap readiness sheet.
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var status: String?
    @State private var showScanner: Bool = false
    @State private var showContacts: Bool = false
    @State private var showEditAddressBook: Bool = false
    @State private var broadcastedTxHash: String?

    /// Result of resolving the recipient field as an ENS name.
    /// When the user types `vitalik.eth` we fire off a lookup; the
    /// resolved 0x address lives here and is what the Send button
    /// actually uses. Cleared when the input changes.
    @State private var resolvedENSAddress: String?
    @State private var ensResolving: Bool = false
    @State private var ensError: String?

    /// Effective balance for the amount-vs-balance check. Tokens
    /// have their own balanceOf; native sends use the wallet's wei
    /// balance from eth_getBalance.
    private var balance: EthereumWeiValue? {
        token == nil ? nativeBalance : tokenBalance
    }

    private var activeDescriptor: EthereumWalletDescriptor? {
        store.ethereumWalletStore.activeWallet
    }

    private var isHardwareBacked: Bool {
        guard let w = activeDescriptor else { return false }
        if case .hardware = w.kind { return true }
        return false
    }

    private var ticker: String {
        token?.symbol ?? activeNetwork.ticker
    }

    private var fiatCode: String { store.fiatPreferences.code }
    private var fiatCodeUpper: String { fiatCode.uppercased() }

    /// Whether to offer fiat input on the amount field. Gated on
    /// the user's preference + the active asset having a CoinGecko
    /// price. Mirrors the Solana / Tron pattern so all three chains
    /// behave the same when the user toggles "Show fiat references"
    /// or switches to a brand-new contract with no known price.
    private var hasFiatRef: Bool {
        store.fiatPreferences.showReferencePrices && amountAssetId != nil
    }

    /// Whether the user is currently typing in fiat (vs native).
    private var isFiatDenomination: Bool {
        !amountDenomination.isEmpty && amountDenomination == fiatCodeUpper
    }

    private var sendLabel: String {
        "Send"
    }

    private var sendLabelInProgress: String {
        isHardwareBacked ? "Waiting for device…" : "Broadcasting…"
    }

    /// Decimal places for the amount field. ETH and most native
    /// coins are 18; ERC-20s vary (USDC = 6, DAI = 18, …).
    private var decimals: Int {
        token?.decimals ?? 18
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                networkChipSection
                assetSection
                payToSection
                amountSection
                feeSection
                reviewSection
                if let lastError {
                    Section { Text(lastError).foregroundStyle(.red).font(.callout) }
                }
                if let status {
                    Section { Text(status).foregroundStyle(.green).font(.callout) }
                }
                sendSection
                    .id("send-primary-action")
            }
            .navigationTitle("Send \(ticker)")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: submitting) { _, isSubmitting in
                // Once broadcast() starts (sheet has dismissed, the
                // Send button has flipped to "Waiting for device…"),
                // scroll the action section into view so the user
                // does not have to hunt for it past the form.
                if isSubmitting {
                    dismissSendViewKeyboard()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("send-primary-action", anchor: .center)
                    }
                }
            }
            .onChange(of: broadcastedTxHash) { _, hash in
                if hash != nil {
                    dismissSendViewKeyboard()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("send-primary-action", anchor: .center)
                    }
                }
            }
            .onChange(of: signedRawTx) { _, signed in
                // When the device returns the signed raw tx, the
                // primary button swaps from "Send" to "Broadcast".
                // Scroll the new button into view so the user sees
                // the explicit broadcast step without scrolling.
                if signed != nil {
                    dismissSendViewKeyboard()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("send-primary-action", anchor: .center)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: token?.id) { await loadOnAppear() }
            .sheet(isPresented: $showScanner) {
                ChainScanSheet { scanned in
                    showScanner = false
                    let stripped = stripEthereumPrefix(scanned)
                    if isValidAddress(stripped) || ENSResolver.looksLikeName(stripped) {
                        recipient = stripped
                    } else if let frame = try? JSONDecoder().decode(LocalFrameEnvelope.self, from: Data(scanned.utf8)),
                              frame.v == LocalFrameEnvelope.version {
                        // A Verify & Pay request, not a send target.
                        ensError = "That's a Verify & Pay code. Use Wallet → Verify & Pay, not Send."
                    } else {
                        ensError = "That QR isn't an Ethereum address."
                    }
                }
            }
            .sheet(isPresented: $showContacts) {
                AddressBookPickerSheet(
                    network: .ethereum,
                    onPick: { entry in recipient = entry.address },
                    onEdit: { showEditAddressBook = true }
                )
                .environment(store)
            }
            .sheet(isPresented: $showEditAddressBook) {
                NavigationStack {
                    AddressBookView().environment(store)
                }
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    requiresPassphrase: activeDescriptor?.hidden?.needsHostPassphrase == true,
                    onContinue: {
                        dismissSendViewKeyboard()
                        Task { await broadcast() }
                    },
                    onCancel: {},
                    onPassphrase: { signingPassphrase = $0 }
                )
            }
            } // ScrollViewReader
        }
    }

    // MARK: -- sections

    /// Wallet name + device sublabel + network chip at the top of
    /// the form. Same shape as Bitcoin's headerSection so the user
    /// can always confirm WHICH wallet is sending before signing.
    private var networkChipSection: some View {
        Section {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(walletLabel)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let sub = walletSublabel {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                NetworkChipLabel(text: activeNetwork.displayName, tint: .indigo)
            }
        }
    }

    private var walletLabel: String {
        activeDescriptor?.label ?? "Ethereum wallet"
    }

    /// Device kind label (e.g. "Ledger Nano X") for hardware-backed
    /// wallets so the user can confirm both wallet AND device.
    private var walletSublabel: String? {
        guard let kind = activeDescriptor?.kind,
              case .hardware(let deviceId, _, _) = kind,
              let device = store.devices.find(id: deviceId)
        else { return nil }
        return device.kind.displayName
    }

    private var payToSection: some View {
        Section("Pay to") {
            HStack {
                TextField("0x… or vitalik.eth", text: $recipient, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...4)
                Button {
                    if let s = UIPasteboard.general.string { recipient = stripEthereumPrefix(s) }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .buttonStyle(.borderless)
                Button {
                    showContacts = true
                } label: {
                    Image(systemName: "person.text.rectangle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pick from contacts")
            }
            .onChange(of: recipient) { _, _ in
                handleRecipientChanged()
            }
            if ensResolving {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(recipient)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let resolved = resolvedENSAddress {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(shortAddress(resolved))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else if let ensError {
                Text(ensError).font(.caption).foregroundStyle(.red)
            } else if !recipient.isEmpty && !isValidAddress(recipient) && !ENSResolver.looksLikeName(recipient) {
                Text("Address must be 0x followed by 40 hex characters, or an ENS name like vitalik.eth.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func shortAddress(_ s: String) -> String {
        if s.count <= 24 { return s }
        return "\(s.prefix(10))…\(s.suffix(8))"
    }

    /// Called whenever the recipient text changes. Decides whether
    /// to fire an ENS lookup against the configured gateway.
    private func handleRecipientChanged() {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedENSAddress = nil
        ensError = nil
        guard ENSResolver.looksLikeName(trimmed) else {
            ensResolving = false
            return
        }
        let url = store.ethereumSettings.effectiveENSRPCURL()
        guard let resolver = ENSResolver(rpcURLString: url) else {
            ensError = "ENS gateway URL is invalid. Fix it in Settings → Networks → Ethereum."
            return
        }
        ensResolving = true
        let snapshot = trimmed
        Task {
            do {
                let address = try await resolver.resolve(snapshot)
                await MainActor.run {
                    // Only apply if the input hasn't changed since
                    // we fired the request.
                    guard recipient.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot else { return }
                    resolvedENSAddress = address
                    ensResolving = false
                }
            } catch {
                await MainActor.run {
                    guard recipient.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot else { return }
                    ensError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    ensResolving = false
                }
            }
        }
    }

    /// 0x address the transaction will actually be built against,
    /// whether the user typed an address or an ENS name.
    private var effectiveRecipient: String {
        if let resolved = resolvedENSAddress { return resolved }
        return recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asset dropdown: native (chain ticker) first, then the configured ERC-20s
    /// alphabetically by symbol. Switching re-keys the balance/estimate load and
    /// every asset-dependent computation (ADR-0033 Phase 2b round-2).
    private var assetSection: some View {
        let tokens = store.ethereumTokenStore.tokens(on: activeNetwork, walletId: wallet.descriptor.id)
            .sorted { $0.symbol.lowercased() < $1.symbol.lowercased() }
        let currentLabel = token.map { "\($0.symbol) · \($0.name)" } ?? "\(activeNetwork.ticker) (native)"
        return Section("Asset") {
            Menu {
                Button {
                    token = nil
                } label: {
                    if token == nil {
                        Label("\(activeNetwork.ticker) (native)", systemImage: "checkmark")
                    } else {
                        Text("\(activeNetwork.ticker) (native)")
                    }
                }
                ForEach(tokens) { t in
                    Button {
                        token = t
                    } label: {
                        if token?.id == t.id {
                            Label("\(t.symbol) · \(t.name)", systemImage: "checkmark")
                        } else {
                            Text("\(t.symbol) · \(t.name)")
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Asset")
                    Spacer()
                    Text(currentLabel).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField("0.00", text: $amountStr)
                    .keyboardType(.decimalPad)
                if hasFiatRef {
                    Picker("", selection: $amountDenomination) {
                        Text(ticker).tag(ticker)
                        Text(fiatCodeUpper).tag(fiatCodeUpper)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 100)
                } else {
                    Text(ticker).foregroundStyle(.secondary)
                }
                Button("Max") {
                    if let bal = balance {
                        // Subtract max fee cap so the user can spend
                        // close to the wallet's balance without
                        // tipping into insufficient-balance. Tokens
                        // pay fees in the native coin, so a token
                        // send's max-spendable IS the whole balance.
                        amountStr = maxSpendableAmount(balance: bal)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(balance == nil)
            }
            if let counterCaption = amountCounterCaption {
                HStack {
                    Spacer()
                    Text(counterCaption).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            if let bal = balance {
                HStack {
                    Text("Available: \(bal.displayUnits(ticker: ticker, decimals: decimals, maxDecimals: 6))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .onAppear {
            // Defer init so we can read `ticker` (computed off
            // token / activeNetwork). Re-initialises on token /
            // network change below.
            if amountDenomination.isEmpty { amountDenomination = ticker }
        }
        .onChange(of: ticker) { _, newTicker in
            // Switching tokens (USDC -> DAI) or network (mainnet ->
            // Sepolia) resets to native; preserves fiat when the
            // user had explicitly picked it AND the new asset has
            // a price.
            if isFiatDenomination, hasFiatRef { return }
            amountDenomination = newTicker
        }
        .onChange(of: hasFiatRef) { _, available in
            // If fiat references get disabled or the active asset
            // loses its price source, snap back to native.
            if !available, isFiatDenomination { amountDenomination = ticker }
        }
    }

    /// Caption rendered below the amount field showing the inverse
    /// denomination: when the user typed native, this is the fiat
    /// equivalent; when they typed fiat, this is the native amount
    /// the network will actually move. nil when the value is empty
    /// or no price is available.
    private var amountCounterCaption: String? {
        if isFiatDenomination {
            // Show the native equivalent of the typed fiat amount.
            guard let amt = parsedAmount, amt > .zero else { return nil }
            return amt.displayUnits(ticker: ticker, decimals: decimals, maxDecimals: 8)
        }
        return typedAmountFiatCaption
    }

    /// CoinGecko asset id for the currently-active denomination.
    /// For ERC-20 sends the token's own id; for native sends the
    /// network's native asset id. nil when the asset is not in
    /// CoinGecko (testnet / custom contracts).
    private var amountAssetId: String? {
        if let token { return token.coinGeckoId }
        return activeNetwork.coinGeckoAssetId
    }

    /// Format a wei-denominated amount as a fiat caption ("≈ $3.21
    /// USD"). Used by both the typed amount preview and the review
    /// section. Returns nil when fiat refs are off, the asset has
    /// no CoinGecko id, or no price is cached.
    private func fiatCaption(amount: EthereumWeiValue, decimals: Int, assetId: String?) -> String? {
        guard let asset = assetId else { return nil }
        let divisor = pow(Decimal(10), decimals)
        guard divisor > 0 else { return nil }
        let scaled = amount.decimal / divisor
        return store.assetPrices.fiatCaption(
            amount: scaled,
            asset: asset,
            fiat: store.fiatPreferences.code
        )
    }

    /// Live fiat preview of the typed amount. nil when the user
    /// disabled fiat references, the network has no coin id
    /// (testnet / custom), or no price is cached yet. For ERC-20
    /// sends we look up the token's CoinGecko id; native sends use
    /// the network's native asset id.
    private var typedAmountFiatCaption: String? {
        guard let typed = Decimal(string: amountStr), typed > 0 else { return nil }
        let assetId: String?
        if let token { assetId = token.coinGeckoId }
        else { assetId = activeNetwork.coinGeckoAssetId }
        guard let asset = assetId else { return nil }
        return store.assetPrices.fiatCaption(
            amount: typed,
            asset: asset,
            fiat: store.fiatPreferences.code
        )
    }

    private var feeSection: some View {
        Section("Network fee") {
            Picker("Gas tier", selection: $selectedTier) {
                ForEach(EthereumGasEstimator.Tier.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if loadingFees {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fetching current gas prices…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let est = estimates[selectedTier] {
                feeBreakdown(est: est)
            } else {
                Text("Gas estimates unavailable. Switch RPC under Settings → Networks → Ethereum, or try Standard.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func feeBreakdown(est: EthereumGasEstimator.Estimate) -> some View {
        let gas = gasUnits ?? defaultGasUnits
        let gasWei = EthereumWeiValue(uint64: gas)
        let maxFee = est.maxFeePerGas * gasWei
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Base fee").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(est.baseFeePerGas.displayGwei()) gwei").font(.caption.monospaced())
            }
            HStack {
                Text("Priority tip").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(est.maxPriorityFeePerGas.displayGwei()) gwei").font(.caption.monospaced())
            }
            HStack {
                Text("Max fee per gas").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(est.maxFeePerGas.displayGwei()) gwei").font(.caption.monospaced())
            }
            HStack {
                Text("Gas units").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(gas)").font(.caption.monospaced())
            }
            Divider()
            HStack {
                Text("Max network fee").font(.caption.weight(.semibold))
                Spacer()
                // Fees are always paid in the chain's native coin,
                // even for ERC-20 transfers. Never use the token's
                // ticker here.
                Text(maxFee.display(ticker: activeNetwork.ticker, maxDecimals: 6))
                    .font(.caption.monospaced().weight(.semibold))
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            if let amt = parsedAmount, let est = estimates[selectedTier] {
                let gas = gasUnits ?? defaultGasUnits
                let maxFee = est.maxFeePerGas * EthereumWeiValue(uint64: gas)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("You send").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(amt.displayUnits(ticker: ticker, decimals: decimals, maxDecimals: 8))
                            .font(.caption.monospaced())
                    }
                    if let cap = fiatCaption(amount: amt, decimals: decimals, assetId: amountAssetId) {
                        HStack {
                            Spacer()
                            Text(cap)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Text("Max network fee").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(maxFee.display(ticker: activeNetwork.ticker, maxDecimals: 8))
                        .font(.caption.monospaced())
                }
                if token == nil {
                    // Native send: amount + fee compete for the same
                    // balance, so a single "worst-case total" line
                    // tells the user whether they're over-spending.
                    let totalCost = amt + maxFee
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Worst-case total").font(.caption.weight(.semibold))
                            Spacer()
                            Text(totalCost.display(ticker: ticker, maxDecimals: 8))
                                .font(.caption.monospaced().weight(.semibold))
                        }
                        if let cap = fiatCaption(amount: totalCost, decimals: 18, assetId: activeNetwork.coinGeckoAssetId) {
                            HStack {
                                Spacer()
                                Text(cap)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let bal = nativeBalance, totalCost > bal {
                        Text("Worst-case total exceeds balance. Lower the amount or wait for cheaper gas.")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else {
                    // Token send: amount and fee come from different
                    // balances, so we surface both insufficient cases
                    // independently.
                    if let bal = tokenBalance, amt > bal {
                        Text("Amount exceeds your \(ticker) balance.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if let nat = nativeBalance, maxFee > nat {
                        Text("Not enough \(activeNetwork.ticker) to cover the network fee. Top up the wallet's native balance.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            } else {
                Text("Enter recipient and amount to review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Gas units to use before `eth_estimateGas` returns. Native
    /// EOA-to-EOA is always 21000; ERC-20 transfers are 50-70k
    /// depending on the contract.
    private var defaultGasUnits: UInt64 {
        token == nil ? 21000 : 65000
    }

    private var sendSection: some View {
        Section {
            if signedRawTx != nil && broadcastedTxHash == nil {
                // Hardware sign succeeded; user needs to tap Broadcast
                // to actually put the signed tx on chain. Matches the
                // BTC / SOL / TRX two-step flow.
                PulseBroadcastButton(title: "Broadcast transaction") {
                    Task { await broadcastSigned() }
                }
                .disabled(submitting)
                Button(role: .destructive) {
                    signedRawTx = nil
                    status = nil
                } label: {
                    Label("Discard signed transaction", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(submitting)
            } else {
                Button {
                    if isHardwareBacked,
                       case .hardware(let deviceId, _, _) = activeDescriptor?.kind,
                       let dev = store.devices.find(id: deviceId),
                       HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                        pendingReadyOp = PendingHardwareOperation(
                            device: dev,
                            purpose: .ethereumSign
                        )
                    } else {
                        Task { await broadcast() }
                    }
                } label: {
                    HStack {
                        if submitting { ProgressView().controlSize(.small) }
                        Text(submitting ? sendLabelInProgress : sendLabel)
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSubmit || submitting)
            }
        } footer: {
            if isHardwareBacked {
                Text("Confirm the transaction on your hardware device when prompted. The device verifies the recipient, value, and gas cap on-screen before signing.")
                    .font(.caption)
            } else if let hash = broadcastedTxHash {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Broadcast: \(hash.prefix(10))…\(hash.suffix(6))")
                        .font(.caption.monospaced())
                    if let url = explorerTxURL(hash: hash) {
                        Link("Open in explorer", destination: url).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: -- compute

    private var parsedAmount: EthereumWeiValue? {
        // Native input: parse units directly.
        if !isFiatDenomination {
            return EthereumWeiValue.fromUnits(amountStr, decimals: decimals)
        }
        // Fiat input: convert via the cached spot price into native
        // units, then encode as wei. Returns nil if the price is
        // missing (caller treats nil as "can't submit").
        let trimmed = amountStr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let fiatValue = Decimal(string: trimmed),
              fiatValue > 0,
              let asset = amountAssetId,
              let price = store.assetPrices.price(asset: asset, fiat: fiatCode),
              price > 0
        else { return nil }
        let priceDecimal = Decimal(price)
        let nativeUnits = fiatValue / priceDecimal
        return EthereumWeiValue.fromUnits(nativeUnits.description, decimals: decimals)
    }

    private var canSubmit: Bool {
        guard let amt = parsedAmount, amt > .zero else { return false }
        guard isValidAddress(effectiveRecipient) else { return false }
        guard estimates[selectedTier] != nil else { return false }
        return true
    }

    private func isValidAddress(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("0x"), trimmed.count == 42 else { return false }
        let hex = trimmed.dropFirst(2)
        return hex.allSatisfy { $0.isHexDigit }
    }

    private func maxSpendableAmount(balance: EthereumWeiValue) -> String {
        // ERC-20: token balance is independent of gas (gas burns in
        // the native coin), so max-spendable is the whole balance.
        let spendableWei: EthereumWeiValue
        if token != nil {
            spendableWei = balance
        } else {
            let reserve: EthereumWeiValue
            if let est = estimates[selectedTier] {
                let gas = gasUnits ?? 21000
                reserve = est.maxFeePerGas * EthereumWeiValue(uint64: gas)
            } else {
                // No live gas yet; reserve a conservative 0.001 ether.
                reserve = EthereumWeiValue.fromEther("0.001") ?? .zero
            }
            let diff = balance.decimal - reserve.decimal
            let clamped: Decimal = diff > Decimal(0) ? diff : Decimal(0)
            spendableWei = EthereumWeiValue(decimal: clamped)
        }
        // Native denomination: format as units of the asset.
        if !isFiatDenomination {
            return formatAsUnits(spendableWei, decimals: decimals)
        }
        // Fiat denomination: convert sat-equivalent units to fiat,
        // then FLOOR to 2dp so the round-trip back to native via
        // parsedAmount can't exceed the available balance (same
        // mitigation Bitcoin uses for its USD/AED Max button).
        guard let asset = amountAssetId,
              let price = store.assetPrices.price(asset: asset, fiat: fiatCode),
              price > 0
        else {
            return formatAsUnits(spendableWei, decimals: decimals)
        }
        let nativeUnits = spendableWei.units(decimals: decimals)
        let fiatValue = (nativeUnits as NSDecimalNumber).doubleValue * price
        let floored = floor(fiatValue * 100) / 100
        return String(format: "%.2f", floored)
    }

    private func formatAsUnits(_ w: EthereumWeiValue, decimals: Int) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = decimals
        return f.string(from: NSDecimalNumber(decimal: w.units(decimals: decimals))) ?? "0"
    }

    private func explorerTxURL(hash: String) -> URL? {
        let base = activeNetwork.explorerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/tx/\(hash)")
    }

    private func stripEthereumPrefix(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // EIP-681: ethereum:0x… or with chain hint
        if out.lowercased().hasPrefix("ethereum:") {
            out = String(out.dropFirst("ethereum:".count))
        }
        if let q = out.firstIndex(of: "?") { out = String(out[..<q]) }
        if let at = out.firstIndex(of: "@") { out = String(out[..<at]) }
        return out
    }

    /// Hardware signing: build the unsigned EIP-1559 envelope, ship
    /// it to the device via the per-vendor BLE transport at the
    /// wallet's BIP44 account index, get V/R/S back, reassemble
    /// the signed envelope.
    @MainActor
    private func signOnHardware(
        plan: EthereumTxPlan,
        deviceId: UUID,
        account: UInt32,
        hidden: HardwarePassphraseRef? = nil,
        derivationPath: String? = nil,
        hostEntered: String? = nil
    ) async throws -> String {
        guard let dev = store.devices.find(id: deviceId) else {
            throw EthereumWallet.WalletError.rpcFailure("Hardware device record \(deviceId) is missing. Re-register the device in Settings → Devices.")
        }
        return try await EthereumHardwareTx.sign(
            plan: plan,
            device: dev,
            account: account,
            hidden: hidden,
            derivationPath: derivationPath,
            hostEntered: hostEntered
        )
    }

    // MARK: -- data flow

    /// Currently-selected network for the active wallet. Pulled from
    /// the wallet store so the dropdown in EthereumWalletView is the
    /// single source of truth for which chain the send targets.
    private var activeNetwork: ResolvedNetwork {
        store.ethereumWalletStore.activeNetwork(
            customs: store.ethereumCustomNetworks,
            settings: store.ethereumSettings
        )
    }

    @MainActor
    private func loadOnAppear() async {
        guard activeDescriptor != nil else { return }
        let rpcURL = activeNetwork.rpcURL
        loadingFees = true
        do {
            nativeBalance = try await wallet.balance(rpcURL: rpcURL)
        } catch {
            // Non-fatal: user can still send if they know the
            // balance covers the amount.
        }
        if let token {
            do {
                tokenBalance = try await wallet.tokenBalance(token: token, rpcURL: rpcURL)
            } catch {
                // Non-fatal; the send path will re-check at submit.
            }
        }
        do {
            let tiers = try await EthereumGasEstimator.estimate(rpcURL: rpcURL)
            estimates = Dictionary(uniqueKeysWithValues: tiers.map { ($0.tier, $0) })
        } catch {
            lastError = "Gas estimation failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        loadingFees = false
    }

    @MainActor
    private func broadcast() async {
        guard let descriptor = activeDescriptor else { return }
        guard let amt = parsedAmount, let est = estimates[selectedTier] else { return }

        let network = activeNetwork
        let rpcURL = network.rpcURL
        submitting = true
        lastError = nil
        status = nil
        // Fresh attempt: drop any tx retained from a previous broadcast failure
        // so a stale signed tx can never be re-pushed for new inputs.
        signedRawTx = nil
        do {
            // Native ETH: estimate against the EOA recipient.
            // ERC-20: estimate against the token contract with the
            // ABI-encoded transfer(to, amount) as call data.
            let estimateTo: String
            let estimateValue: EthereumWeiValue
            let estimateData: Data?
            if let token {
                estimateTo = token.contractAddress
                estimateValue = .zero
                estimateData = EthereumABI.transferData(to: effectiveRecipient, amount: amt)
            } else {
                estimateTo = effectiveRecipient
                estimateValue = amt
                estimateData = nil
            }
            let gas = try await wallet.estimateGasUnits(
                to: estimateTo,
                value: estimateValue,
                data: estimateData,
                rpcURL: rpcURL
            )
            gasUnits = gas

            // Pre-flight: amount-vs-balance + fee-vs-native.
            let fee = est.maxFeePerGas * EthereumWeiValue(uint64: gas)
            if token != nil {
                let tBal = tokenBalance ?? .zero
                if amt > tBal {
                    throw EthereumWallet.WalletError.insufficientBalance(have: tBal, need: amt)
                }
                let nBal = nativeBalance ?? .zero
                if fee > nBal {
                    throw EthereumWallet.WalletError.insufficientBalance(have: nBal, need: fee)
                }
            } else {
                let totalCost = amt + fee
                let currentBalance = nativeBalance ?? .zero
                if totalCost > currentBalance {
                    throw EthereumWallet.WalletError.insufficientBalance(have: currentBalance, need: totalCost)
                }
            }

            // Pending nonce.
            let nonce = try await wallet.pendingNonce(rpcURL: rpcURL)

            // Build the plan.
            let plan = EthereumTxPlan(
                chainId: network.chainId,
                nonce: nonce,
                toAddress: token?.contractAddress ?? effectiveRecipient,
                value: amt,
                gasLimit: gas,
                maxFeePerGas: est.maxFeePerGas,
                maxPriorityFeePerGas: est.maxPriorityFeePerGas,
                payload: token == nil ? .native : .erc20(recipient: effectiveRecipient)
            )

            // Sign: software (TWC) or hardware (Ledger BLE),
            // depending on the wallet kind.
            switch descriptor.kind {
            case .software(let account):
                guard let sandwich = store.sandwich else {
                    throw EthereumWallet.WalletError.sandwichRequired
                }
                let promptVerb = token == nil ? "send" : "transfer \(token!.symbol)"
                // Fresh biometric / passcode before signing (ADR-0045
                // Authorization invariant); refreshes the cache so the sign call
                // below does not prompt again.
                _ = try await sandwich.recoveryMaterialFresh(
                    localizedReason: "Authorize \(network.displayName) \(promptVerb)"
                )
                let rawTx = try EthereumDescriptors.signTransactionFromSandwich(
                    sandwich: sandwich,
                    account: account,
                    plan: plan,
                    biometricReason: "Authorize \(network.displayName) \(promptVerb)",
                    expectedAddress: descriptor.address
                )
                // Software path: broadcast inline. The biometric
                // prompt + the existing review section have already
                // given the user a confirmation step; no second tap
                // adds safety here. Stash the signed tx FIRST so that if
                // the broadcast RPC fails, it is retained for a re-push
                // without re-signing (the Broadcast button reappears).
                signedRawTx = rawTx
                try await finalizeBroadcast(
                    rawTx: rawTx,
                    descriptor: descriptor,
                    amount: amt,
                    network: network,
                    rpcURL: rpcURL
                )
            case .hardware(let deviceId, let account, _):
                let rawTx = try await signOnHardware(
                    plan: plan, deviceId: deviceId, account: account,
                    hidden: descriptor.hidden,
                    derivationPath: descriptor.derivationPath,
                    hostEntered: signingPassphrase
                )
                // Hardware path: stash the signed tx and let the
                // user tap Broadcast. Same pattern as BTC / SOL /
                // TRX. The Broadcast button appears in `sendSection`.
                signedRawTx = rawTx
                status = "Signed. Tap Broadcast to send on chain."
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Send failed: \(error)"
            // Leave signedRawTx as-is: if signing succeeded and only the
            // broadcast failed (software path), it stays populated so the
            // Broadcast button reappears for a re-push without re-signing. A
            // sign-time failure never set it (cleared at the top), so the
            // primary button correctly returns to Send / re-sign.
        }
        submitting = false
    }

    /// Phase 2 of the hardware path: take the device-signed raw tx
    /// stashed in `signedRawTx` and push it to the RPC. Stays a
    /// no-op (nothing to broadcast) on the software path because
    /// that broadcasts inline inside `broadcast()`.
    @MainActor
    private func broadcastSigned() async {
        guard let rawTx = signedRawTx else { return }
        guard let descriptor = activeDescriptor, let amt = parsedAmount else { return }
        let network = activeNetwork
        let rpcURL = network.rpcURL
        submitting = true
        lastError = nil
        do {
            try await finalizeBroadcast(
                rawTx: rawTx,
                descriptor: descriptor,
                amount: amt,
                network: network,
                rpcURL: rpcURL
            )
            // Clear the pending-signed marker so the button cycle
            // resets if the user keeps the view open.
            signedRawTx = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Broadcast failed: \(error)"
        }
        submitting = false
    }

    /// Shared tail of the broadcast flow. Pushes `rawTx` to the RPC
    /// and applies the optimistic pending row used by the wallet
    /// dashboard. Throws if the broadcast itself fails so the
    /// caller can leave `signedRawTx` populated for a retry without
    /// re-summoning the device.
    @MainActor
    private func finalizeBroadcast(
        rawTx: String,
        descriptor: EthereumWalletDescriptor,
        amount amt: EthereumWeiValue,
        network: ResolvedNetwork,
        rpcURL: String
    ) async throws {
        let hash = try await wallet.broadcast(rawTx: rawTx, rpcURL: rpcURL)
        LogStore.shared.info("eth.send",
            "broadcast on \(network.displayName) (chain \(network.chainId)) tx=\(hash)")
        broadcastedTxHash = hash
        status = "Broadcast. tx \(hash.prefix(10))…\(hash.suffix(6))"
        let senderAddr = descriptor.address ?? ""
        store.ethereumWalletStore.markPendingOutbound(
            senderWalletId: descriptor.id,
            txHash: hash,
            senderAddress: senderAddr,
            recipientAddress: effectiveRecipient,
            weiValue: token == nil ? amt.decimal.description : "0",
            tokenContract: token?.contractAddress,
            tokenSymbol: token?.symbol,
            tokenDecimals: token.map { UInt8($0.decimals) }
        )
        onBroadcast(hash)
        // Auto-dismiss back to the wallet view so the user lands on
        // the optimistic Pending row immediately, matching Bitcoin's
        // behaviour. Solana / Tron follow the same shape now.
        dismiss()
    }
}

// QR scanner wrapper. EIP-681 stripping happens in the parent view
// when the code arrives, so this just forwards the raw text.
private struct ScanEthereumAddressSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onCode: onScan)
                .ignoresSafeArea()
            .navigationTitle("Scan address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
