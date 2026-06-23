// Tron send view. Splits the hardware path into Sign → Broadcast
// so the user gets an explicit "I have a signature, ready to send"
// moment before the tx hits the network. Software path is one-tap.
//
// Common layout shared with the other chains:
//
//   On: [network chip]
//   Recipient: text + paste + QR scan + contacts
//   Amount: TRX / fiat denomination picker + fiat caption
//   Advanced: fee limit
//   Review: Network · Pay to · Amount(+fiat) · Network fee
//   Primary action: Send (software) / Sign using <device> (hardware)
//
// State machine:
//   idle → (hardware → device-ready sheet → continue →) signing →
//     hardware: signed(json) → user-tap broadcast → broadcasting → done
//     software: broadcasting → done
//   failed at any step shows a recoverable error.

import SwiftUI
import UIKit
import WalletCore

struct TronSendView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let walletId: UUID
    /// When opened from a token's detail view, the token id to
    /// pre-select so the user lands straight on a TRC-20 send.
    /// nil for the generic "Send" entry (native TRX, picker shown).
    var preselectTokenId: String? = nil

    // Input
    @State private var recipient: String = ""
    @State private var amount: String = ""
    @State private var amountDenomination: String = "TRX"
    @State private var feeLimitTRX: String = "1"
    @State private var showAdvanced: Bool = false

    // Live native TRX balance in sun, plus the selected TRC-20's
    // raw balance (on-chain integer as a base-10 string) when a
    // token is picked.
    @State private var nativeSun: Int64?
    @State private var tokenRawBalance: String?

    // State machine
    @State private var state: SendState = .idle
    @State private var lastError: String?
    /// Re-typed each signing for a host-entry hidden wallet; never stored.
    @State private var signingPassphrase: String = ""

    // Sheets / overlays
    @State private var selectedToken: TronTRC20Token? = nil
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var showContacts: Bool = false
    @State private var showEditAddressBook: Bool = false
    @State private var showScanner: Bool = false

    enum SendState {
        case idle
        /// Sandwich-biometric prompt or hardware sign in flight.
        case signing
        /// Hardware only: signature returned, waiting for the user
        /// to tap Broadcast. The envelope + Ledger signature are
        /// held here so the broadcast call doesn't re-derive
        /// anything (and the user can review before sending).
        case signed(unsignedAndSig: TronDescriptors.TronUnsignedAndSignature, expiresAt: Date)
        case broadcasting
        case done(txid: String)
        case failed(message: String)
    }

    private var descriptor: TronWalletDescriptor? {
        store.tronWalletStore.wallets.first(where: { $0.id == walletId })
    }

    private var activeNetwork: TronNetwork {
        store.tronWalletStore.activeNetwork(for: walletId)
    }

    private var availableTokens: [TronTRC20Token] {
        store.tronTRC20TokenStore.tokens(on: activeNetwork)
    }

    private var isHardware: Bool {
        guard let descriptor else { return false }
        if case .hardware = descriptor.kind { return true }
        return false
    }

    private var fiatCode: String { store.fiatPreferences.code }
    private var fiatCodeUpper: String { fiatCode.uppercased() }

    /// Active asset's CoinGecko id: the selected TRC-20 token's
    /// id when one is picked, otherwise the network's native asset
    /// id. nil for tokens without a price feed.
    private var activeAssetId: String? {
        if let token = selectedToken { return token.coinGeckoId }
        return activeNetwork.coinGeckoAssetId
    }

    /// Whether to offer the fiat denomination picker. Honours both
    /// native and token sends; collapses to native-only when the
    /// active asset has no CoinGecko id.
    private var hasFiatRef: Bool {
        store.fiatPreferences.showReferencePrices && activeAssetId != nil
    }

    private var nativeDenomTag: String {
        selectedToken?.symbol ?? "TRX"
    }

    private var isFiatDenomination: Bool {
        amountDenomination == fiatCodeUpper
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                networkSection
                tokenPickerSection
                recipientSection
                amountSection
                advancedSection
                reviewSection
                primaryActionSection
                    .id("send-primary-action")
                errorSection
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    requiresPassphrase: descriptor?.hidden?.needsHostPassphrase == true,
                    onContinue: {
                        dismissSendViewKeyboard()
                        Task { await signNow() }
                    },
                    onCancel: {},
                    onPassphrase: { signingPassphrase = $0 }
                )
            }
            .sheet(isPresented: $showContacts) {
                AddressBookPickerSheet(
                    network: .tron,
                    onPick: { entry in recipient = entry.address },
                    onEdit: { showEditAddressBook = true }
                )
                .environment(store)
            }
            .sheet(isPresented: $showEditAddressBook) {
                NavigationStack { AddressBookView().environment(store) }
            }
            .sheet(isPresented: $showScanner) {
                ChainScanSheet { scanned in
                    recipient = stripTronPrefix(scanned)
                    showScanner = false
                }
            }
            .task {
                // Pre-select the token the user tapped into, before
                // the first balance load so Available / Max reflect
                // the right asset.
                if selectedToken == nil, let id = preselectTokenId {
                    selectedToken = availableTokens.first { $0.id == id }
                }
                await loadBalance()
            }
            .onChange(of: stateScrollKey) { _, newKey in
                guard newKey != "idle" else { return }
                dismissSendViewKeyboard()
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("send-primary-action", anchor: .center)
                }
            }
        }
    }

    private var stateScrollKey: String {
        switch state {
        case .idle:         return "idle"
        case .signing:      return "signing"
        case .signed:       return "signed"
        case .broadcasting: return "broadcasting"
        case .done:         return "done"
        case .failed:       return "failed"
        }
    }

    /// Refresh the native TRX balance (and the selected TRC-20's
    /// balance, if any) so Available + Max reflect what's actually
    /// spendable.
    @MainActor
    private func loadBalance() async {
        guard let descriptor else { return }
        let net = activeNetwork
        let rpcURL = store.tronSettings.rpcURL(for: net)
        let wallet = TronWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        do {
            let sender = try await wallet.address(
                biometricReason: "Read \(descriptor.label) balance"
            )
            nativeSun = try await wallet.refreshBalance(
                biometricReason: "Read \(descriptor.label) balance"
            )
            if let token = selectedToken {
                tokenRawBalance = try? await TronTRC20TransferBuilder.balance(
                    holderBase58: sender,
                    contractBase58: token.contract,
                    rpcURL: rpcURL
                )
            } else {
                tokenRawBalance = nil
            }
        } catch {
            // Non-fatal; the send path itself surfaces the RPC error.
        }
    }

    // MARK: -- sections

    @ViewBuilder
    private var networkSection: some View {
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
                NetworkChipLabel(text: activeNetwork.displayName, tint: .red)
            }
        }
    }

    private var walletLabel: String {
        descriptor?.label ?? "Tron wallet"
    }

    private var walletSublabel: String? {
        guard let kind = descriptor?.kind,
              case .hardware(let deviceId, _, _) = kind,
              let device = store.devices.find(id: deviceId)
        else { return nil }
        return device.kind.displayName
    }

    @ViewBuilder
    private var tokenPickerSection: some View {
        if !availableTokens.isEmpty {
            Section("Token") {
                Picker("Send", selection: Binding(
                    get: { selectedToken?.id ?? "trx" },
                    set: { newId in
                        selectedToken = availableTokens.first { $0.id == newId }
                    }
                )) {
                    Text("TRX (native)").tag("trx")
                    // Native first, then tokens alphabetically by symbol (ADR-0033 Phase 2b round-2).
                    ForEach(availableTokens.sorted { $0.symbol.lowercased() < $1.symbol.lowercased() }) { token in
                        Text("\(token.symbol) - \(token.name)").tag(token.id)
                    }
                }
            }
        }
    }

    private var recipientSection: some View {
        Section("Recipient") {
            HStack {
                TextField("T-prefixed address", text: $recipient)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Button {
                    if let s = UIPasteboard.general.string {
                        recipient = stripTronPrefix(s)
                    }
                } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                Button {
                    showScanner = true
                } label: { Image(systemName: "qrcode.viewfinder") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Scan QR")
                Button {
                    showContacts = true
                } label: { Image(systemName: "person.text.rectangle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pick from contacts")
            }
            if !recipient.isEmpty, TronDescriptors.parseAddress(recipient) == nil {
                Text("Not a valid Tron base58check address.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField("0.00", text: $amount)
                    .keyboardType(.decimalPad)
                if hasFiatRef {
                    Picker("", selection: $amountDenomination) {
                        Text(nativeDenomTag).tag(nativeDenomTag)
                        Text(fiatCodeUpper).tag(fiatCodeUpper)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 100)
                } else {
                    Text(nativeDenomTag).foregroundStyle(.secondary)
                }
                Button("Max") { applyMaxAmount() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(maxSpendableDisplayString == nil)
            }
            if let avail = availableBalanceCaption {
                HStack {
                    Text(avail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if hasFiatRef, let captionLine = amountConversionCaption {
                Text(captionLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedToken?.id) { _, _ in
            if !(isFiatDenomination && hasFiatRef) {
                amountDenomination = nativeDenomTag
            }
            // Re-read the balance for the newly-selected asset.
            Task { await loadBalance() }
        }
        .onChange(of: hasFiatRef) { _, available in
            if !available, isFiatDenomination { amountDenomination = nativeDenomTag }
        }
    }

    /// "Available: 0.123456 TRX" / "Available: 42 USDT" caption under
    /// the amount field. Token balances come from a `balanceOf`
    /// probe via the shared TronTRC20TransferBuilder helper.
    private var availableBalanceCaption: String? {
        if let token = selectedToken {
            guard let raw = tokenRawBalance else { return nil }
            return "Available: \(token.format(rawAmountDecimal: raw)) \(token.symbol)"
        }
        guard let sun = nativeSun else { return nil }
        let trx = Double(sun) / 1_000_000.0
        return String(format: "Available: %.6f TRX", trx)
    }

    /// Token balance scaled to human units as a Double. nil when no
    /// balance is loaded. Used by the token Max path.
    private var tokenBalanceUnits: Double? {
        guard let token = selectedToken, let raw = tokenRawBalance,
              let rawDecimal = Decimal(string: raw)
        else { return nil }
        let scale = pow(Decimal(10), Int(token.decimals))
        let units = rawDecimal / scale
        return (units as NSDecimalNumber).doubleValue
    }

    /// Max display formatted per the current denomination.
    /// - TRC-20: the full token balance (network fee is paid in TRX,
    ///   not the token, so the whole balance is spendable).
    /// - Native: (balance - fee_limit).
    /// Fiat mode floors to 2dp to avoid round-trip overflow.
    private var maxSpendableDisplayString: String? {
        if let token = selectedToken {
            guard let units = tokenBalanceUnits, units > 0 else { return nil }
            if isFiatDenomination,
               let asset = activeAssetId,
               let price = store.assetPrices.price(asset: asset, fiat: fiatCode),
               price > 0
            {
                let floored = floor(units * price * 100) / 100
                return String(format: "%.2f", floored)
            }
            return String(format: "%.\(token.decimals)f", units)
        }
        guard let sun = nativeSun, sun > 0 else { return nil }
        let feeLimitSun: Int64 = Int64((Double(feeLimitTRX) ?? 1.0) * 1_000_000)
        guard sun > feeLimitSun else { return nil }
        let spendable = sun - feeLimitSun
        let trx = Double(spendable) / 1_000_000.0
        if isFiatDenomination,
           let asset = activeAssetId,
           let price = store.assetPrices.price(asset: asset, fiat: fiatCode),
           price > 0
        {
            let fiat = trx * price
            let floored = floor(fiat * 100) / 100
            return String(format: "%.2f", floored)
        }
        return String(format: "%.6f", trx)
    }

    private func applyMaxAmount() {
        guard let value = maxSpendableDisplayString else { return }
        amount = value
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fee limit (TRX)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("1", text: $feeLimitTRX).keyboardType(.decimalPad)
                Text("Maximum TRX you're willing to burn as energy / bandwidth. 1 TRX is generous for a simple transfer; TRC-20 transfers can need 10 to 100.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            ReviewRow(
                label: "Network",
                value: activeNetwork.displayName,
                highlightTint: .red
            )
            ReviewRow(label: "Pay to", value: shortAddress(recipient.isEmpty ? "-" : recipient))
            ReviewRow(
                label: "Amount",
                value: reviewAmountLine,
                subValue: reviewAmountFiatCaption
            )
            ReviewRow(
                label: "Network fee",
                value: "≤ \(feeLimitTRX) TRX"
            )
        }
    }

    @ViewBuilder
    private var primaryActionSection: some View {
        Section {
            switch state {
            case .idle, .failed:
                primaryButton
            case .signing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(isHardware ? "Waiting for signature on \(deviceName)…" : "Signing…")
                }
            case .signed:
                broadcastButton
            case .broadcasting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Broadcasting…")
                }
            case .done(let txid):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Broadcast", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(txid)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    if let url = explorerURL(for: txid) {
                        Link("View on explorer", destination: url)
                    }
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            // Hardware: show the device-ready sheet first; software:
            // run directly. After the sheet's Continue, we go to
            // signNow() which transitions state to .signing.
            if let descriptor,
               case .hardware(let deviceId, _, _) = descriptor.kind,
               let dev = store.devices.find(id: deviceId),
               HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .tronSign
                )
            } else {
                Task { await signNow() }
            }
        } label: {
            Text(primaryButtonLabel).frame(maxWidth: .infinity)
        }
        .disabled(!canSubmit)
    }

    private var broadcastButton: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Signed. Tap Broadcast to send.")
                    .font(.callout.weight(.medium))
            }
            PulseBroadcastButton(title: "Broadcast") {
                Task { await broadcastNow() }
            }
            Text(broadcastExpiryHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var errorSection: some View {
        Group {
            if let lastError {
                Section {
                    Text(lastError).foregroundStyle(.red).font(.callout)
                }
            }
        }
    }

    // MARK: -- derived strings

    private var deviceName: String {
        guard case .hardware(let deviceId, _, _) = descriptor?.kind,
              let dev = store.devices.find(id: deviceId)
        else { return "device" }
        return dev.label
    }

    private var primaryButtonLabel: String {
        guard let descriptor else { return "Send" }
        switch descriptor.kind {
        case .software: return "Send"
        case .hardware: return "Sign using \(deviceName)"
        }
    }

    /// "1.234 TRX" or "≈ 1.234 TRX" when the user typed in fiat.
    /// Used by the Review section's Amount row.
    private var reviewAmountLine: String {
        guard let token = selectedToken else {
            return "\(formattedNativeAmount) TRX"
        }
        return "\(formattedNativeAmount) \(token.symbol)"
    }

    /// Fiat caption next to the review's Amount line. Honours both
    /// native and TRC-20 sends now that the picker is token-aware.
    private var reviewAmountFiatCaption: String? {
        guard hasFiatRef, let assetId = activeAssetId else { return nil }
        guard let native = parsedNativeUnits, native > 0 else { return nil }
        return store.assetPrices.fiatCaption(
            amount: Decimal(native),
            asset: assetId,
            fiat: fiatCode
        )
    }

    /// Inverse caption shown under the amount field. When the user
    /// typed native, shows "≈ $1.23 USD"; when they typed fiat,
    /// shows "= 1.234 <SYMBOL>".
    private var amountConversionCaption: String? {
        guard hasFiatRef, let assetId = activeAssetId else { return nil }
        if isFiatDenomination {
            guard let native = parsedNativeUnits, native > 0 else { return nil }
            let f = NumberFormatter()
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = selectedToken.map { Int($0.decimals) } ?? 6
            let nativeStr = f.string(from: NSDecimalNumber(value: native)) ?? String(native)
            return "= \(nativeStr) \(nativeDenomTag)"
        }
        guard let native = parsedNativeUnits, native > 0 else { return nil }
        return store.assetPrices.fiatCaption(
            amount: Decimal(native),
            asset: assetId,
            fiat: fiatCode
        )
    }

    private var formattedNativeAmount: String {
        guard let native = parsedNativeUnits, native > 0 else { return "0" }
        let maxDecimals = selectedToken.map { Int($0.decimals) } ?? 6
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxDecimals
        return f.string(from: NSDecimalNumber(value: native)) ?? String(native)
    }

    private var broadcastExpiryHint: String {
        if case .signed(_, let expiresAt) = state {
            let seconds = max(0, Int(expiresAt.timeIntervalSinceNow))
            return "Tron transactions expire ~60s after signing. Broadcast within \(seconds)s."
        }
        return ""
    }

    // MARK: -- amount parsing

    /// Amount the user typed, normalised to native units of the
    /// currently-active asset (TRX or the selected TRC-20). Branches
    /// on the current denomination: native input is trusted as-is;
    /// fiat input goes through the cached spot price.
    private var parsedNativeUnits: Double? {
        guard let entered = Double(amount), entered > 0 else { return nil }
        if isFiatDenomination {
            guard let assetId = activeAssetId,
                  let price = store.assetPrices.price(asset: assetId, fiat: fiatCode),
                  price > 0
            else { return nil }
            return entered / price
        }
        return entered
    }

    /// TRX-only convenience wrapper. nil when sending a TRC-20.
    private var parsedTRXAmount: Double? {
        guard selectedToken == nil else { return nil }
        return parsedNativeUnits
    }

    /// TRC-20 send: amount in token units; convert to raw via decimals.
    private func parsedTokenRawAmount(_ token: TronTRC20Token) -> String? {
        guard let native = parsedNativeUnits, native > 0 else { return nil }
        let scaled = native * pow(10.0, Double(token.decimals))
        return String(format: "%.0f", scaled.rounded())
    }

    private var canSubmit: Bool {
        guard TronDescriptors.parseAddress(recipient) != nil else { return false }
        if let token = selectedToken {
            return parsedTokenRawAmount(token) != nil
        }
        return parsedTRXAmount != nil
    }

    private func shortAddress(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    private func stripTronPrefix(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.lowercased().hasPrefix("tron:") {
            out = String(out.dropFirst("tron:".count))
        }
        if let q = out.firstIndex(of: "?") { out = String(out[..<q]) }
        return out
    }

    private func explorerURL(for txid: String) -> URL? {
        let base = store.tronSettings.explorerURL(for: activeNetwork)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/#/transaction/\(txid)")
    }

    // MARK: -- state transitions

    /// Hardware path: sign the tx and stash the JSON in .signed
    /// until the user taps Broadcast. Software path: sign +
    /// broadcast in one go for backward-compat with the existing
    /// single-tap software UX.
    @MainActor
    private func signNow() async {
        guard let descriptor else {
            lastError = "Wallet not found."
            return
        }
        if !isHardware, store.sandwich == nil {
            lastError = "Maknoon is locked. Unlock from the Identity tab and retry."
            return
        }
        lastError = nil
        state = .signing

        let net = activeNetwork
        let rpcURL = store.tronSettings.rpcURL(for: net)
        let wallet = TronWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        let feeLimitSun = Int64((Double(feeLimitTRX) ?? 1) * 1_000_000)

        do {
            if let token = selectedToken {
                guard let rawAmount = parsedTokenRawAmount(token) else {
                    throw TronDescriptorError.signingFailed("Couldn't parse token amount.")
                }
                if case .hardware(let deviceId, let account, let senderBase58) = descriptor.kind {
                    guard let dev = store.devices.find(id: deviceId) else {
                        throw TronDescriptorError.signingFailed(
                            "Hardware device record missing. Re-register the device in Settings → Devices."
                        )
                    }
                    let hwKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
                    let ledger = HardwareWalletFactory.make(kind: hwKind)
                    // A Trezor hidden wallet must re-open its passphrase
                    // session. Ledger / mock clients ignore this.
                    if let trezor = ledger as? TrezorBLE {
                        trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(descriptor.hidden, hostEntered: signingPassphrase))
                    }
                    ledger.setDerivationPathOverride(descriptor.derivationPath)
                    ledger.beginSession()
                    defer { ledger.endSession() }
                    let identified = try await ledger.identifyDevice()
                    guard identified == dev.serial else {
                        throw HardwareWalletError.transport(
                            "Connected device serial \(identified) does not match registered \(dev.serial)"
                        )
                    }
                    let signed = try await wallet.prepareHardwareTRC20(
                        contractAddress: token.contract,
                        recipient: recipient,
                        rawAmount: rawAmount,
                        feeLimitSun: max(feeLimitSun, 10_000_000),
                        ledger: ledger,
                        senderBase58: senderBase58,
                        account: account
                    )
                    state = .signed(
                        unsignedAndSig: signed,
                        expiresAt: Date().addingTimeInterval(55)
                    )
                    return
                }
                // Software path stays one-shot.
                state = .broadcasting
                let txid = try await wallet.sendTRC20(
                    contractAddress: token.contract,
                    decimals: token.decimals,
                    rawAmount: rawAmount,
                    recipient: recipient,
                    feeLimitSun: max(feeLimitSun, 10_000_000),
                    biometricReason: "Authorize \(token.symbol) send"
                )
                markPending(
                    txid: txid,
                    recipient: recipient,
                    rawTokenAmountString: rawAmount,
                    token: token
                )
                state = .done(txid: txid)
                dismiss()
                return
            }

            guard let trx = parsedTRXAmount, trx > 0 else {
                throw TronDescriptorError.signingFailed("Enter a positive amount.")
            }
            let sunAmount = Int64((trx * 1_000_000).rounded())

            if case .hardware(let deviceId, let account, let senderBase58) = descriptor.kind {
                guard let dev = store.devices.find(id: deviceId) else {
                    throw TronDescriptorError.signingFailed(
                        "Hardware device record missing. Re-register the device in Settings → Devices."
                    )
                }
                let hwKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
                let ledger = HardwareWalletFactory.make(kind: hwKind)
                // A Trezor hidden wallet must re-open its passphrase
                // session. Ledger / mock clients ignore this.
                if let trezor = ledger as? TrezorBLE {
                    trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(descriptor.hidden, hostEntered: signingPassphrase))
                }
                ledger.setDerivationPathOverride(descriptor.derivationPath)
                ledger.beginSession()
                defer { ledger.endSession() }
                let identified = try await ledger.identifyDevice()
                guard identified == dev.serial else {
                    throw HardwareWalletError.transport(
                        "Connected device serial \(identified) does not match registered \(dev.serial)"
                    )
                }
                let signed = try await wallet.prepareHardwareNative(
                    recipient: recipient,
                    sunAmount: sunAmount,
                    feeLimitSun: feeLimitSun,
                    ledger: ledger,
                    senderBase58: senderBase58,
                    account: account
                )
                // Tron expiration window is ~60s past block timestamp.
                // Conservative client-side hint so the user broadcasts
                // before the network rejects.
                state = .signed(
                    unsignedAndSig: signed,
                    expiresAt: Date().addingTimeInterval(55)
                )
            } else {
                let signedJSON = try await wallet.prepareSoftwareNative(
                    recipient: recipient,
                    sunAmount: sunAmount,
                    feeLimitSun: feeLimitSun,
                    biometricReason: "Authorize Tron send"
                )
                // Software path: auto-broadcast in the same call to
                // preserve the one-tap UX.
                state = .broadcasting
                let txid = try await wallet.broadcastSignedJSON(signedJSON)
                markPending(
                    txid: txid,
                    recipient: recipient,
                    sunAmount: sunAmount,
                    senderAddress: try? await wallet.resolvedAddress(
                        biometricReason: "Mark sent tx as pending"
                    )
                )
                state = .done(txid: txid)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = msg
            state = .failed(message: msg)
        }
    }

    @MainActor
    private func broadcastNow() async {
        guard case .signed(let signed, let expiresAt) = state else { return }
        guard let descriptor else { return }
        let net = activeNetwork
        let rpcURL = store.tronSettings.rpcURL(for: net)
        let wallet = TronWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        state = .broadcasting
        do {
            let txid = try await wallet.broadcastHardwareSignature(signed)
            // Pull the sender address off the hardware descriptor.
            let senderAddress: String? = {
                if case .hardware(_, _, let addr) = descriptor.kind { return addr }
                return nil
            }()
            // TRC-20 vs native pending entry: route by selectedToken.
            if let token = selectedToken,
               let rawAmount = parsedTokenRawAmount(token) {
                markPending(
                    txid: txid,
                    recipient: recipient,
                    rawTokenAmountString: rawAmount,
                    token: token
                )
            } else {
                let sunAmount: Int64 = {
                    guard let trx = parsedTRXAmount else { return 0 }
                    return Int64((trx * 1_000_000).rounded())
                }()
                markPending(
                    txid: txid,
                    recipient: recipient,
                    sunAmount: sunAmount,
                    senderAddress: senderAddress
                )
            }
            state = .done(txid: txid)
            dismiss()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = msg
            // Stay in .signed so the user can retry the broadcast
            // (TronGrid sometimes flakes; the signed JSON is still
            // valid as long as the expiration hasn't passed).
            state = .signed(unsignedAndSig: signed, expiresAt: expiresAt)
        }
    }

    /// Optimistically register the broadcast tx as pending so the
    /// wallet view shows a "Pending" row before TronGrid returns it
    /// as confirmed. The store auto-mirrors a pending inbound on any
    /// other hardware wallet on this device whose address matches
    /// `recipient`.
    @MainActor
    private func markPending(
        txid: String,
        recipient: String,
        sunAmount: Int64,
        senderAddress: String?
    ) {
        guard let walletId = descriptor?.id else { return }
        store.tronWalletStore.markPendingOutbound(
            senderWalletId: walletId,
            txID: txid,
            senderAddress: senderAddress ?? "",
            recipientAddress: recipient,
            sunAmount: sunAmount
        )
    }

    /// TRC-20 variant. `rawTokenAmountString` is the integer string
    /// of raw token units (already scaled by decimals). We reuse
    /// `sunAmount` on PendingTronTx to carry it so the display row
    /// formats correctly via `tokenDecimals`.
    @MainActor
    private func markPending(
        txid: String,
        recipient: String,
        rawTokenAmountString: String,
        token: TronTRC20Token
    ) {
        guard let walletId = descriptor?.id else { return }
        let raw = Int64(rawTokenAmountString) ?? 0
        store.tronWalletStore.markPendingOutbound(
            senderWalletId: walletId,
            txID: txid,
            senderAddress: "",
            recipientAddress: recipient,
            sunAmount: raw,
            tokenContract: token.contract,
            tokenSymbol: token.symbol,
            tokenDecimals: token.decimals
        )
    }
}

// Shared `NetworkChipLabel`, `ReviewRow`, `PulseBroadcastButton`,
// `ChainScanSheet` live in `Maknoon/UI/SendViewKit.swift`, adopted
// here, in Solana/SolanaSendView.swift, and in
// Ethereum/EthereumSendView.swift.
