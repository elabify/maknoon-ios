// Solana send view. Splits the hardware path into Sign → Broadcast
// so the user gets an explicit "I have a signature, ready to send"
// moment before the tx hits the network. Software path is one-tap.
//
// Layout matches the shared Tron pattern (see SendViewKit.swift):
//
//   On: [network chip]
//   Recipient: text + paste + QR scan + contacts
//   Amount: SOL / fiat denomination picker + fiat caption
//   Advanced: priority fee
//   Review: Network · Pay to · Amount(+fiat) · Network fee
//   Primary action: Send (software) / Sign using <device> (hardware)
//
// State machine:
//   idle → (hardware → device-ready sheet → continue →) signing →
//     hardware: signed(base64) → user-tap broadcast → broadcasting → done
//     software: broadcasting → done

import SwiftUI
import UIKit
import WalletCore

/// Decode a Solana base58 string to raw bytes via Trust Wallet Core's
/// Base58 helper. Returns nil on malformed input.
fileprivate func base58Decode(_ s: String) -> Data? {
    WalletCore.Base58.decodeNoCheck(string: s)
}

struct SolanaSendView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let walletId: UUID
    /// When opened from a token's detail view, the token id to
    /// pre-select so the user lands straight on an SPL send. nil for
    /// the generic "Send" entry (native SOL, picker shown).
    var preselectTokenId: String? = nil

    // Input
    @State private var recipient: String = ""
    @State private var amount: String = ""
    @State private var amountDenomination: String = "SOL"
    @State private var priorityMicroLamports: String = "0"
    @State private var showAdvanced: Bool = false

    // Live balance + SPL token balances (lamports / raw token units).
    @State private var nativeLamports: UInt64?
    @State private var splTokenBalances: [String: UInt64] = [:]

    // State machine
    @State private var state: SendState = .idle
    @State private var lastError: String?
    @State private var debugCode: String?

    // Sheets / overlays
    @State private var selectedToken: SolanaSPLToken? = nil
    @State private var pendingReadyOp: PendingHardwareOperation?
    @State private var showContacts: Bool = false
    @State private var showEditAddressBook: Bool = false
    @State private var showScanner: Bool = false

    enum SendState {
        case idle
        case signing
        /// Hardware only: signature returned, awaiting user-tap
        /// Broadcast. Holds the wire-ready signed base64 blob plus
        /// a token marker so the broadcast call knows which kind
        /// (native vs SPL).
        case signed(signedBase64: String, expiresAt: Date)
        case broadcasting
        case confirming(signature: String)
        case done(signature: String)
        case failed(message: String)
    }

    private var descriptor: SolanaWalletDescriptor? {
        store.solanaWalletStore.wallets.first(where: { $0.id == walletId })
    }

    private var activeNetwork: SolanaNetwork {
        store.solanaWalletStore.activeNetwork(for: walletId)
    }

    private var availableTokens: [SolanaSPLToken] {
        store.solanaSPLTokenStore.tokens(on: activeNetwork)
    }

    private var isHardware: Bool {
        guard let descriptor else { return false }
        if case .hardware = descriptor.kind { return true }
        return false
    }

    private var fiatCode: String { store.fiatPreferences.code }
    private var fiatCodeUpper: String { fiatCode.uppercased() }

    /// Active asset's CoinGecko id: the selected SPL token's id
    /// when one is picked, otherwise the cluster's native asset id.
    /// nil when the asset doesn't have a price feed.
    private var activeAssetId: String? {
        if let token = selectedToken { return token.coinGeckoId }
        return activeNetwork.coinGeckoAssetId
    }

    /// Whether to offer the fiat denomination picker. Now also
    /// honours SPL tokens that have a known CoinGecko id (USDC,
    /// USDT, etc.); tokens without a price collapse to a single
    /// symbol label.
    private var hasFiatRef: Bool {
        store.fiatPreferences.showReferencePrices && activeAssetId != nil
    }

    /// Current denomination's display label for the picker.
    private var nativeDenomTag: String {
        selectedToken?.symbol ?? "SOL"
    }

    /// True when the user is currently typing in fiat (not in
    /// SOL or the selected SPL token).
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
                    onContinue: {
                        dismissSendViewKeyboard()
                        Task { await signNow() }
                    },
                    onCancel: {}
                )
            }
            .sheet(isPresented: $showContacts) {
                AddressBookPickerSheet(
                    network: .solana,
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
                    recipient = stripSolanaPrefix(scanned)
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
        case .confirming:   return "confirming"
        case .done:         return "done"
        case .failed:       return "failed"
        }
    }

    /// Pull the latest native SOL balance + SPL token balances from
    /// the current RPC so the Available + Max button reflects what
    /// the user can actually spend.
    @MainActor
    private func loadBalance() async {
        guard let descriptor else { return }
        let net = activeNetwork
        let rpcURL = store.solanaSettings.rpcURL(for: net)
        let wallet = SolanaWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        do {
            let lamports = try await wallet.refreshBalance(
                biometricReason: "Read \(descriptor.label) balance"
            )
            nativeLamports = lamports
            if !availableTokens.isEmpty {
                let holdings = (try? await wallet.tokenAccounts(
                    biometricReason: "Read \(descriptor.label) token balances"
                )) ?? []
                var balances: [String: UInt64] = [:]
                for h in holdings where h.amount > 0 { balances[h.mint] = h.amount }
                splTokenBalances = balances
            }
        } catch {
            // Non-fatal: leave Available blank and let the user
            // proceed; the actual send still surfaces the RPC error.
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
                NetworkChipLabel(text: activeNetwork.displayName, tint: .purple)
            }
        }
    }

    private var walletLabel: String {
        descriptor?.label ?? "Solana wallet"
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
                    get: { selectedToken?.id ?? "sol" },
                    set: { newId in
                        selectedToken = availableTokens.first { $0.id == newId }
                    }
                )) {
                    Text("SOL (native)").tag("sol")
                    ForEach(availableTokens) { token in
                        Text("\(token.symbol) - \(token.name)").tag(token.id)
                    }
                }
            }
        }
    }

    private var recipientSection: some View {
        Section("Recipient") {
            HStack {
                TextField("Solana address", text: $recipient)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Button {
                    if let s = UIPasteboard.general.string {
                        recipient = stripSolanaPrefix(s)
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
            if !recipient.isEmpty, SolanaDescriptors.parseAddress(recipient) == nil {
                Text("Not a valid Solana base58 address.")
                    .font(.caption)
                    .foregroundStyle(.red)
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
            if hasFiatRef, let caption = amountConversionCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedToken?.id) { _, _ in
            // Reset to native when switching token; preserves fiat
            // when the user explicitly picked it AND the new token
            // also has a price.
            if isFiatDenomination, hasFiatRef { return }
            amountDenomination = nativeDenomTag
        }
        .onChange(of: hasFiatRef) { _, available in
            if !available, isFiatDenomination { amountDenomination = nativeDenomTag }
        }
    }

    /// "Available: 0.123456 SOL" line under the amount field.
    /// Reflects native SOL when no SPL token is picked, otherwise
    /// the SPL token's raw balance scaled to its decimals.
    private var availableBalanceCaption: String? {
        if let token = selectedToken {
            guard let raw = splTokenBalances[token.mint] else { return nil }
            let scaled = Double(raw) / pow(10.0, Double(token.decimals))
            return String(format: "Available: %.\(token.decimals)f \(token.symbol)", scaled)
        }
        guard let lamports = nativeLamports else { return nil }
        let sol = Double(lamports) / 1_000_000_000.0
        return String(format: "Available: %.9f SOL", sol)
    }

    /// Native SOL leaves a small reserve (~0.001 SOL = 1M lamports)
    /// for the upcoming tx fee + priority. SPL tokens use the full
    /// raw balance because the network fee is paid in SOL, not the
    /// token, so the user can spend their entire token balance.
    private var maxSpendableDisplayString: String? {
        // Compute spendable in native units (token or SOL) first;
        // then format to either native or fiat per the current
        // denomination.
        let spendableNative: Double
        if let token = selectedToken {
            guard let raw = splTokenBalances[token.mint], raw > 0 else { return nil }
            spendableNative = Double(raw) / pow(10.0, Double(token.decimals))
        } else {
            guard let lamports = nativeLamports else { return nil }
            let reserveLamports: UInt64 = 1_000_000
            guard lamports > reserveLamports else { return nil }
            let spendable = lamports - reserveLamports
            spendableNative = Double(spendable) / 1_000_000_000.0
        }
        if isFiatDenomination,
           let asset = activeAssetId,
           let price = store.assetPrices.price(asset: asset, fiat: fiatCode),
           price > 0
        {
            // Floor to 2dp so the round-trip back to native via
            // `amountConversionCaption` / send path doesn't land
            // above the available balance.
            let fiat = spendableNative * price
            let floored = floor(fiat * 100) / 100
            return String(format: "%.2f", floored)
        }
        if let token = selectedToken {
            return String(format: "%.\(token.decimals)f", spendableNative)
        }
        return String(format: "%.9f", spendableNative)
    }

    private func applyMaxAmount() {
        guard let value = maxSpendableDisplayString else { return }
        amount = value
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Priority fee (micro-lamports per compute unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0", text: $priorityMicroLamports)
                    .keyboardType(.numberPad)
                Text("Bumps transaction priority during congestion. 0 is fine for normal sends. Typical congestion values: 10000 to 100000.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            ReviewRow(
                label: "Network",
                value: activeNetwork.displayName,
                highlightTint: .purple
            )
            ReviewRow(label: "Pay to", value: shortAddress(recipient.isEmpty ? "—" : recipient))
            ReviewRow(
                label: "Amount",
                value: reviewAmountLine,
                subValue: reviewAmountFiatCaption
            )
            ReviewRow(
                label: "Network fee",
                value: priorityFeeReviewValue
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
            case .confirming(let sig):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for confirmation…")
                    }
                    Text(sig)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .done(let sig):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sent", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(sig)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    if descriptor != nil, let url = explorerURL(for: sig) {
                        Link("View on explorer", destination: url)
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            if let descriptor,
               case .hardware(let deviceId, _, _) = descriptor.kind,
               let dev = store.devices.find(id: deviceId),
               HardwareOperationPurpose.shouldPresent(for: dev.kind) {
                pendingReadyOp = PendingHardwareOperation(
                    device: dev,
                    purpose: .solanaSign
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lastError).foregroundStyle(.red).font(.callout)
                        if let debugCode {
                            Text(debugCode)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
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

    private var reviewAmountLine: String {
        guard let token = selectedToken else {
            return "\(formattedNativeAmount) SOL"
        }
        return "\(formattedNativeAmount) \(token.symbol)"
    }

    private var reviewAmountFiatCaption: String? {
        guard hasFiatRef, let assetId = activeAssetId else { return nil }
        guard let native = parsedNativeUnits, native > 0 else { return nil }
        return store.assetPrices.fiatCaption(
            amount: Decimal(native),
            asset: assetId,
            fiat: fiatCode
        )
    }

    /// Inverse caption shown below the amount field. When the user
    /// typed native, this is "≈ $1.23 USD"; when they typed fiat
    /// it's the equivalent native amount. nil when the active
    /// asset has no price.
    private var amountConversionCaption: String? {
        guard hasFiatRef, let assetId = activeAssetId else { return nil }
        if isFiatDenomination {
            guard let nativeUnits = parsedNativeUnits, nativeUnits > 0 else { return nil }
            let f = NumberFormatter()
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = selectedToken.map { Int($0.decimals) } ?? 9
            let nativeStr = f.string(from: NSDecimalNumber(value: nativeUnits)) ?? String(nativeUnits)
            return "= \(nativeStr) \(nativeDenomTag)"
        }
        guard let nativeUnits = parsedNativeUnits, nativeUnits > 0 else { return nil }
        return store.assetPrices.fiatCaption(
            amount: Decimal(nativeUnits),
            asset: assetId,
            fiat: fiatCode
        )
    }

    /// Amount the user typed, in native units (SOL or token).
    /// Branches on the current denomination: native input is
    /// trusted as-is; fiat input goes through the cached spot
    /// price.
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

    private var formattedNativeAmount: String {
        guard let native = parsedNativeUnits, native > 0 else { return "0" }
        let maxDecimals = selectedToken.map { Int($0.decimals) } ?? 9
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = maxDecimals
        return f.string(from: NSDecimalNumber(value: native)) ?? String(native)
    }

    private var priorityFeeReviewValue: String {
        let micro = UInt64(priorityMicroLamports) ?? 0
        if micro == 0 { return "default (no priority)" }
        return "\(micro) µ-lamports / CU"
    }

    private var broadcastExpiryHint: String {
        if case .signed(_, let expiresAt) = state {
            let seconds = max(0, Int(expiresAt.timeIntervalSinceNow))
            return "Solana blockhashes expire ~60s after signing. Broadcast within \(seconds)s."
        }
        return ""
    }

    // MARK: -- amount parsing

    private var parsedSOLAmount: Double? {
        guard selectedToken == nil else { return nil }
        return parsedNativeUnits
    }

    private func parsedTokenRawAmount(_ token: SolanaSPLToken) -> UInt64? {
        guard let native = parsedNativeUnits, native > 0 else { return nil }
        let scale = pow(10.0, Double(token.decimals))
        return UInt64((native * scale).rounded())
    }

    private var canSubmit: Bool {
        guard SolanaDescriptors.parseAddress(recipient) != nil else { return false }
        if let token = selectedToken {
            return parsedTokenRawAmount(token) != nil
        }
        return parsedSOLAmount != nil
    }

    private func shortAddress(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    private func stripSolanaPrefix(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.lowercased().hasPrefix("solana:") {
            out = String(out.dropFirst("solana:".count))
        }
        if let q = out.firstIndex(of: "?") { out = String(out[..<q]) }
        return out
    }

    private func explorerURL(for signature: String) -> URL? {
        let base = store.solanaSettings.explorerURL(for: activeNetwork)
        if base.contains("?") {
            let path = base.replacingOccurrences(of: "?", with: "/tx/\(signature)?")
            return URL(string: path)
        }
        return URL(string: "\(base)/tx/\(signature)")
    }

    // MARK: -- state transitions

    @MainActor
    private func signNow() async {
        guard let descriptor else {
            lastError = "Wallet not found."
            return
        }
        if !isHardware, store.sandwich == nil {
            lastError = "Identity Sandwich is locked. Unlock from the Sandwich tab and retry."
            return
        }
        lastError = nil
        debugCode = nil
        state = .signing

        let net = activeNetwork
        let rpcURL = store.solanaSettings.rpcURL(for: net)
        let wallet = SolanaWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        let priority = UInt64(priorityMicroLamports) ?? 0

        do {
            if let token = selectedToken {
                guard let rawAmount = parsedTokenRawAmount(token) else {
                    throw SolanaDescriptorError.signingFailed("Couldn't parse token amount.")
                }
                if case .hardware(let deviceId, let account, let pubkeyBase58) = descriptor.kind {
                    guard let pubkeyBytes = base58Decode(pubkeyBase58), pubkeyBytes.count == 32 else {
                        throw SolanaDescriptorError.signingFailed(
                            "Stored signer public key did not decode as 32 bytes."
                        )
                    }
                    _ = deviceId
                    let ledger = try await connectedLedger()
                    ledger.beginSession()
                    defer { ledger.endSession() }
                    let signedBase64 = try await wallet.prepareHardwareSPLToken(
                        mint: token.mint,
                        decimals: token.decimals,
                        rawAmount: rawAmount,
                        recipient: recipient,
                        priorityFeeMicroLamports: priority,
                        ledger: ledger,
                        signerBase58: pubkeyBase58,
                        signerPublicKey: pubkeyBytes,
                        account: account
                    )
                    state = .signed(
                        signedBase64: signedBase64,
                        expiresAt: Date().addingTimeInterval(55)
                    )
                } else {
                    state = .broadcasting
                    let sig = try await wallet.sendSPLToken(
                        mint: token.mint,
                        decimals: token.decimals,
                        rawAmount: rawAmount,
                        recipient: recipient,
                        priorityFeeMicroLamports: priority,
                        biometricReason: "Authorize \(token.symbol) send"
                    )
                    await markPendingAndPollForConfirmation(
                        signature: sig,
                        senderAddress: nil,
                        token: token,
                        rawAmount: rawAmount,
                        wallet: wallet
                    )
                }
                return
            }

            guard let sol = parsedSOLAmount, sol > 0 else {
                throw SolanaDescriptorError.signingFailed("Enter a positive amount.")
            }
            let lamports = UInt64((sol * 1_000_000_000).rounded())

            if case .hardware(let deviceId, let account, let pubkeyBase58) = descriptor.kind {
                guard let pubkeyBytes = base58Decode(pubkeyBase58), pubkeyBytes.count == 32 else {
                    throw SolanaDescriptorError.signingFailed(
                        "Stored signer public key did not decode as 32 bytes."
                    )
                }
                _ = deviceId
                let ledger = try await connectedLedger()
                ledger.beginSession()
                defer { ledger.endSession() }
                let signedBase64 = try await wallet.prepareHardwareNative(
                    recipient: recipient,
                    lamports: lamports,
                    priorityFeeMicroLamports: priority,
                    ledger: ledger,
                    signerBase58: pubkeyBase58,
                    signerPublicKey: pubkeyBytes,
                    account: account
                )
                state = .signed(
                    signedBase64: signedBase64,
                    expiresAt: Date().addingTimeInterval(55)
                )
            } else {
                state = .broadcasting
                let sig = try await wallet.sendSoftware(
                    recipient: recipient,
                    lamports: lamports,
                    priorityFeeMicroLamports: priority,
                    biometricReason: "Authorize Solana send"
                )
                let senderAddr = try? await wallet.resolvedAddress(
                    biometricReason: "Mark sent tx as pending"
                )
                await markPendingAndPollForConfirmation(
                    signature: sig,
                    senderAddress: senderAddr,
                    lamports: Int64(lamports),
                    wallet: wallet
                )
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = msg
            state = .failed(message: msg)
        }
    }

    @MainActor
    private func broadcastNow() async {
        guard case .signed(let signedBase64, _) = state else { return }
        guard let descriptor else { return }
        let net = activeNetwork
        let rpcURL = store.solanaSettings.rpcURL(for: net)
        let wallet = SolanaWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: store.sandwich
        )
        state = .broadcasting
        do {
            let sig = try await wallet.broadcastSignedBase64(signedBase64)
            // Hardware sign path: pull senderAddress off the descriptor.
            let senderAddr: String? = {
                if case .hardware(_, _, let pub) = descriptor.kind { return pub }
                return nil
            }()
            let lamports: Int64 = {
                guard let sol = parsedSOLAmount else { return 0 }
                return Int64((sol * 1_000_000_000).rounded())
            }()
            if let token = selectedToken, let raw = parsedTokenRawAmount(token) {
                await markPendingAndPollForConfirmation(
                    signature: sig,
                    senderAddress: senderAddr,
                    token: token,
                    rawAmount: raw,
                    wallet: wallet
                )
            } else {
                await markPendingAndPollForConfirmation(
                    signature: sig,
                    senderAddress: senderAddr,
                    lamports: lamports,
                    wallet: wallet
                )
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = msg
            state = .signed(
                signedBase64: signedBase64,
                expiresAt: Date()
            )
        }
    }

    /// Connect to the registered Ledger for this hardware wallet and
    /// verify the serial matches. Used by both native + SPL hardware
    /// sends so the device-check is in one place.
    private func connectedLedger() async throws -> HardwareWallet {
        guard let descriptor,
              case .hardware(let deviceId, _, _) = descriptor.kind,
              let dev = store.devices.find(id: deviceId)
        else {
            throw SolanaDescriptorError.signingFailed(
                "Hardware device record missing. Re-register the device in Settings → Devices."
            )
        }
        let hwKind: HardwareWalletKind = dev.kind == .ledger ? .ledger : .trezor
        let ledger = HardwareWalletFactory.make(kind: hwKind)
        let identified = try await ledger.identifyDevice()
        guard identified == dev.serial else {
            throw HardwareWalletError.transport(
                "Connected device serial \(identified) does not match registered \(dev.serial)"
            )
        }
        return ledger
    }

    /// Common post-broadcast cleanup: mark pending in the store, then
    /// transition through confirming → done and trigger a wallet-view
    /// refresh once the network sees the tx. Variant for native SOL.
    @MainActor
    private func markPendingAndPollForConfirmation(
        signature sig: String,
        senderAddress: String?,
        lamports: Int64,
        wallet: SolanaWallet
    ) async {
        store.solanaWalletStore.markPendingOutbound(
            senderWalletId: walletId,
            signature: sig,
            senderAddress: senderAddress ?? "",
            recipientAddress: recipient,
            lamports: lamports
        )
        // Auto-dismiss to the wallet view so the user lands on the
        // optimistic Pending row immediately (mirrors Bitcoin's
        // post-broadcast behaviour). The confirmation poll keeps
        // running in the background; its updates are harmless once
        // the view is gone.
        dismiss()
        await waitForConfirmation(signature: sig, wallet: wallet)
    }

    /// Variant for SPL token sends.
    @MainActor
    private func markPendingAndPollForConfirmation(
        signature sig: String,
        senderAddress: String?,
        token: SolanaSPLToken,
        rawAmount: UInt64,
        wallet: SolanaWallet
    ) async {
        store.solanaWalletStore.markPendingOutbound(
            senderWalletId: walletId,
            signature: sig,
            senderAddress: senderAddress ?? "",
            recipientAddress: recipient,
            lamports: Int64(rawAmount),  // SPL: reused as raw token units
            tokenMint: token.mint,
            tokenSymbol: token.symbol,
            tokenDecimals: token.decimals
        )
        // Auto-dismiss to the wallet view so the user lands on the
        // optimistic Pending row immediately (mirrors Bitcoin's
        // post-broadcast behaviour). The confirmation poll keeps
        // running in the background; its updates are harmless once
        // the view is gone.
        dismiss()
        await waitForConfirmation(signature: sig, wallet: wallet)
    }

    @MainActor
    private func waitForConfirmation(signature sig: String, wallet: SolanaWallet) async {
        state = .confirming(signature: sig)
        // Solana confirms in 1-2 seconds typically; poll for up to 30s.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            do {
                if let status = try await wallet.signatureStatus(sig),
                   let conf = status.confirmationStatus,
                   conf == "confirmed" || conf == "finalized"
                {
                    break
                }
            } catch {
                break
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        state = .done(signature: sig)
    }
}
