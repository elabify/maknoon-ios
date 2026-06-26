// Sparrow-style Send screen. Pay-to address (with paste + QR scan),
// label, amount in BTC, fee selector (auto from mempool.space or
// manual sats/vB), coin control toggle (M2 will list per-UTXO
// checkboxes), RBF toggle.
//
// On confirm the BDK software signer signs the PSBT and the wallet
// broadcasts via Electrum. Hardware-wallet signing for M4 changes
// the confirm-button label and routes the PSBT to LedgerBLE.signPSBT.

import SwiftUI
import BitcoinDevKit

struct BitcoinSendView: View {
    let wallet: BitcoinWallet
    let onBroadcast: (String) -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum FeeMode: String, CaseIterable, Identifiable {
        case fastest = "Fastest"
        case halfHour = "30 min"
        case hour = "1 hour"
        case economy = "Economy"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @State private var address: String = ""
    @State private var label: String = ""
    @State private var amountInput: String = ""
    @State private var balance: Balance?
    @State private var selectedUtxosTotalSat: UInt64 = 0
    /// BDK-driven max-drain preview in satoshis. Refreshed whenever
    /// balance / fee / coin-control selection changes; consulted by
    /// the Max button so the value reflects what BDK would actually
    /// produce at send time (mirrors the live UTXO set + true vbytes
    /// instead of a 1-input estimate).
    @State private var maxDrainSat: UInt64 = 0
    /// Either "BTC", "sats", or the user's preferred fiat ISO code
    /// uppercased (e.g. "USD", "AED"). Initial value resolved in
    /// `.onAppear` because @State can't reach `store.fiatPreferences`
    /// at struct-init time.
    @State private var amountDenomination: String = "BTC"
    @State private var feeMode: FeeMode = .halfHour
    @State private var customSatsPerVb: String = "5"
    @State private var feeRecommended: FeeRecommended?
    @State private var rbf: Bool = true
    @State private var coinControl: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var status: String?
    @State private var showScanner: Bool = false
    @State private var showContacts: Bool = false
    @State private var showEditAddressBook: Bool = false
    @State private var showOfflineSheet: Bool = false

    // Send state machine. Each user-initiated action moves us
    // through the chain; failures land in `.failed` with both a
    // human message and a debug code (status word, error kind)
    // surfaced to the UI so the user can include it in a bug
    // report.
    enum SendState {
        case idle
        case signing
        case signed(signedPSBTBase64: String, unsignedPSBTBase64: String)
        case broadcasting
        case done(txid: String)
        case failed(message: String, debugCode: String?, recoverable: Bool)
    }
    @State private var sendState: SendState = .idle
    /// The signed PSBT retained across a broadcast-only failure so Retry can
    /// re-push the SAME bytes without re-signing (no second hardware prompt).
    /// Set only when broadcast fails after a successful sign; cleared at the
    /// start of a new sign. nil => a retry must re-sign from scratch.
    @State private var retainedSignedPSBT: (signed: String, unsigned: String)?
    /// Re-typed each signing for a host-entry hidden wallet; never stored.
    @State private var signingPassphrase: String = ""
    @State private var pendingReadyOp: PendingHardwareOperation?

    // Coin-control selection. Empty unless the user opened the
    // picker and ticked at least one row.
    @State private var selectedUtxos: Set<UTXOPickerView.UTXOKey> = []
    @State private var showUTXOPicker: Bool = false

    /// The hardware-wallet device backing the active wallet (if
    /// any). Drives the per-vendor reminder copy and the device
    /// name in the Sign button.
    private var boundDevice: RegisteredDevice? {
        guard let w = store.bitcoinWalletStore.activeWallet else { return nil }
        if case let .hardware(deviceId, _, _) = w.kind {
            return store.devices.find(id: deviceId)
        }
        return nil
    }

    /// Signing flow for the active wallet. Software wallets sign in
    /// the app, BLE-capable devices (Ledger, Trezor) sign over BLE,
    /// air-gapped devices (SeedSigner) use the offline-PSBT QR
    /// round-trip. Drives the Send button label and routing.
    private var signingMechanism: BitcoinSigningMechanism {
        guard let w = store.bitcoinWalletStore.activeWallet else { return .software }
        switch w.kind {
        case .software:
            return .software
        case .hardware(let deviceId, _, _):
            guard let device = store.devices.find(id: deviceId) else {
                // Device was registered but is no longer in the
                // registry. Fall back to the safest path so the user
                // can still get a signed transaction off this phone.
                return .airgappedPSBT
            }
            return device.kind.bitcoinSigningMechanism
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                headerSection
                payToSection
                amountSection
                feeSection
                advancedSection
                reviewSection

                if case let .failed(message, debugCode, _) = sendState {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message).foregroundStyle(.red).font(.callout)
                            if let debugCode {
                                Text("Debug code: \(debugCode)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let status {
                    Section { Text(status).foregroundStyle(.green).font(.callout) }
                }

                Section {
                    primaryActionButtons
                        .id("send-primary-action")
                    if case .failed = sendState {
                        Button(role: .destructive) { sendState = .idle } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // Air-gapped escape hatch for software / hardware
                    // wallets that want to take the PSBT to a different
                    // device. Always available unless we've already
                    // moved past idle.
                    if case .idle = sendState, signingMechanism != .airgappedPSBT {
                        Button {
                            showOfflineSheet = true
                        } label: {
                            Label(signingMechanism == .software
                                  ? "Sign on another device…"
                                  : "Or sign offline (PSBT QR)…",
                                  systemImage: "square.and.arrow.up.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!canSubmit)
                    } else if case .airgappedPSBT = signingMechanism {
                        Button {
                            showOfflineSheet = true
                        } label: {
                            Label("Generate PSBT for offline signing", systemImage: "square.and.arrow.up.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!canSubmit)
                    }
                } footer: {
                    switch signingMechanism {
                    case .software, .hardwareBLE:
                        // The device-ready sheet that runs on tap
                        // already tells the user to open the right
                        // app and unlock; no extra Bluetooth blurb
                        // needed here.
                        EmptyView()
                    case .airgappedPSBT:
                        Text("This wallet is air-gapped. Maknoon builds the unsigned PSBT (BIP174); you sign it on the device by scanning the QR; the signed PSBT comes back via the device's QR and Maknoon broadcasts.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await loadFees()
                await loadBalance()
            }
            .onChange(of: selectedUtxos) { _, _ in
                Task {
                    await refreshSelectedUtxosTotal()
                    await refreshMaxDrain()
                }
            }
            .onChange(of: effectiveSatsPerVb) { _, _ in
                Task { await refreshMaxDrain() }
            }
            .onChange(of: coinControl) { _, _ in
                Task { await refreshMaxDrain() }
            }
            .onChange(of: sendStateAsScrollKey) { _, newKey in
                // Every non-idle transition swaps the primary button
                // (Signing on <device>, Broadcast, Retry, Done…), so
                // scroll the action area into view. iOS may also try
                // to re-focus the amount TextField after the
                // confirmation sheet dismisses; dismiss the keyboard
                // explicitly here so the view does not get yanked
                // back to the field as we scroll.
                guard newKey != "idle" else { return }
                dismissSendViewKeyboard()
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("send-primary-action", anchor: .center)
                }
            }
            .sheet(isPresented: $showScanner) {
                ScanAddressSheet { scanned in
                    address = stripBitcoinPrefix(scanned)
                    showScanner = false
                }
            }
            .sheet(isPresented: $showContacts) {
                AddressBookPickerSheet(
                    network: .bitcoin,
                    onPick: { entry in address = entry.address },
                    onEdit: { showEditAddressBook = true }
                )
                .environment(store)
            }
            .sheet(isPresented: $showEditAddressBook) {
                NavigationStack {
                    AddressBookView().environment(store)
                }
            }
            .sheet(isPresented: $showUTXOPicker) {
                if let descriptor = store.bitcoinWalletStore.activeWallet {
                    UTXOPickerView(
                        wallet: wallet,
                        network: descriptor.network,
                        amountNeededSat: amountSats,
                        selection: $selectedUtxos
                    )
                    .environment(store)
                }
            }
            .sheet(item: $pendingReadyOp) { op in
                DeviceReadyConfirmationSheet(
                    device: op.device,
                    purpose: op.purpose,
                    requiresPassphrase: store.bitcoinWalletStore.activeWallet?.hidden?.needsHostPassphrase == true,
                    onContinue: {
                        dismissSendViewKeyboard()
                        Task { await signOnly() }
                    },
                    onCancel: {},
                    onPassphrase: { signingPassphrase = $0 }
                )
            }
            .sheet(isPresented: $showOfflineSheet) {
                if amountSats > 0 {
                    BitcoinOfflinePSBTSheet(
                        wallet: wallet,
                        recipient: address,
                        amountSat: amountSats,
                        feeRateSatsPerVb: effectiveSatsPerVb,
                        enableRbf: rbf,
                        onBroadcast: { txid in
                            status = "Broadcast. txid \(txid.prefix(12))…"
                            onBroadcast(txid)
                            showOfflineSheet = false
                            dismiss()
                        }
                    )
                    .environment(store)
                }
            }
            } // ScrollViewReader
        }
    }

    /// Tiny string key used for `.onChange(of:)` to fire the scroll
    /// animation when the primary action area changes shape (idle →
    /// signed/failed). Reduces the SendState enum to its
    /// scroll-relevant projection.
    private var sendStateAsScrollKey: String {
        switch sendState {
        case .idle:         return "idle"
        case .signing:      return "signing"
        case .signed:       return "signed"
        case .broadcasting: return "broadcasting"
        case .done:         return "done"
        case .failed:       return "failed"
        }
    }

    // MARK: -- sections

    /// Wallet name + network chip at the top of the form. Both are
    /// load-bearing for safety: a misclicked wallet selector that
    /// would otherwise send mainnet BTC to a signet test address is
    /// caught here, before signing.
    private var headerSection: some View {
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
                NetworkChipLabel(text: activeNetwork.displayName, tint: .orange)
            }
        }
    }

    private var activeNetwork: BitcoinNetwork {
        store.bitcoinWalletStore.activeWallet?.network ?? .mainnet
    }

    private var walletLabel: String {
        store.bitcoinWalletStore.activeWallet?.label ?? "Bitcoin wallet"
    }

    /// Secondary line under the wallet name: hardware-vendor name
    /// when this is a device-backed wallet, otherwise nil.
    private var walletSublabel: String? {
        guard let kind = store.bitcoinWalletStore.activeWallet?.kind,
              case .hardware = kind,
              let device = boundDevice
        else { return nil }
        return device.kind.displayName
    }

    private var payToSection: some View {
        Section("Pay to") {
            HStack {
                TextField("bc1q… (Bech32 address)", text: $address, axis: .vertical)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...4)
                Button {
                    if let s = UIPasteboard.general.string { address = stripBitcoinPrefix(s) }
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
            TextField("Label (optional)", text: $label)
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField(amountPlaceholder, text: $amountInput)
                    .keyboardType(amountKeyboard)
                Picker("", selection: $amountDenomination) {
                    ForEach(denominationOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button("Max") { applyMaxAmount() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(maxSpendableSat == 0)
            }
            HStack {
                Text(availableBalanceCaption)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(captionLines, id: \.self) { line in
                HStack {
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// "Available: 0.00123456 BTC (12,345 sats)" line below the
    /// amount field. When coin-control is on with a non-empty
    /// selection, this shows the sum of selected UTXOs (matching
    /// what Max will spend); otherwise it shows the wallet's full
    /// balance. Reflects the BDK balance view, which excludes
    /// untrusted-pending outputs so the Max button never
    /// over-spends.
    private var availableBalanceCaption: String {
        if coinControl, !selectedUtxos.isEmpty {
            let sats = selectedUtxosTotalSat
            let count = selectedUtxos.count
            return "Available: \(formatBTC(sats)) BTC (\(sats.formatted()) sats) from \(count) selected UTXO\(count == 1 ? "" : "s")"
        }
        guard let b = balance else { return "Available: loading…" }
        let total = b.total.toSat()
        return "Available: \(formatBTC(total)) BTC (\(total.formatted()) sats)"
    }

    /// Max amount the user can spend right now, sourced from a BDK
    /// `drainWallet` preview that runs whenever the inputs change.
    /// Reflects the real UTXO set and the real vbytes BDK would emit
    /// for the send, so the resulting amount never trips an
    /// "Insufficient funds" error at submit time. 0 until the first
    /// preview completes (button stays disabled).
    private var maxSpendableSat: UInt64 { maxDrainSat }

    /// Refresh the cached sum of user-selected UTXOs. BitcoinWallet
    /// is an actor, so we hop off the main thread to read the UTXO
    /// list. Triggered on `selectedUtxos` change.
    @MainActor
    private func refreshSelectedUtxosTotal() async {
        let utxos = await wallet.listUnspent()
        let sum: UInt64 = utxos.reduce(0) { acc, u in
            let key = UTXOPickerView.UTXOKey(
                txid: String(describing: u.outpoint.txid),
                vout: u.outpoint.vout
            )
            return selectedUtxos.contains(key) ? acc + u.txout.value.toSat() : acc
        }
        selectedUtxosTotalSat = sum
    }

    private func applyMaxAmount() {
        let sats = maxSpendableSat
        guard sats > 0 else { return }
        switch amountDenomination {
        case "sats":
            amountInput = "\(sats)"
        case "BTC":
            let btc = Double(sats) / 100_000_000.0
            amountInput = String(format: "%.8f", btc)
        default:
            // Fiat denomination: convert sats -> BTC -> fiat, then
            // FLOOR to 2dp before display. `String(format: "%.2f")`
            // rounds half-to-even, which can round UP (e.g. $499.295
            // -> "$499.30"). The send view then converts the
            // displayed fiat back to sats, lands above the original
            // max, and trips the "total exceeds available balance"
            // check. Flooring keeps the round-trip ≤ max.
            guard let price = store.assetPrices.price(
                asset: "bitcoin",
                fiat: amountDenomination.lowercased()
            ), price > 0 else { return }
            let btc = Double(sats) / 100_000_000.0
            let fiat = btc * price
            let flooredCents = floor(fiat * 100) / 100
            amountInput = String(format: "%.2f", flooredCents)
        }
    }

    /// Picker options. Always offers BTC and sats; appends the
    /// user's preferred fiat code (uppercased) as a third option,
    /// unless that code is already "BTC" / "SATS" (it isn't, but
    /// guard anyway).
    private var denominationOptions: [String] {
        var out: [String] = ["BTC", "sats"]
        let user = store.fiatPreferences.code.uppercased()
        if !user.isEmpty, user != "BTC", user != "SATS" {
            out.append(user)
        }
        return out
    }

    private var amountKeyboard: UIKeyboardType {
        amountDenomination == "sats" ? .numberPad : .decimalPad
    }

    private var amountPlaceholder: String {
        amountDenomination == "sats" ? "0" : "0.00"
    }

    /// Captions below the amount field. User asked for: always
    /// show BTC and USD references if they aren't the selected
    /// input unit, so a typo in any unit gets a sanity check
    /// in the canonical reference unit (BTC) and a sanity check
    /// against the dollar amount.
    private var captionLines: [String] {
        let sats = amountSats
        guard sats > 0 else { return [] }
        var out: [String] = []
        let btc = Decimal(sats) / Decimal(100_000_000)
        if amountDenomination != "BTC" {
            out.append("\(formatBTC(sats)) BTC")
        }
        if amountDenomination != "sats" {
            out.append("\(sats) sats")
        }
        if amountDenomination.uppercased() != "USD" {
            if let cap = store.assetPrices.fiatCaption(amount: btc, asset: "bitcoin", fiat: "usd") {
                out.append(cap)
            }
        }
        return out
    }

    private func formatBTC(_ sats: UInt64) -> String {
        let btc = Double(sats) / 100_000_000.0
        return String(format: "%.8f", btc)
    }

    /// The input parsed into satoshis, regardless of which
    /// denomination the user selected. Returns 0 on parse failure
    /// (which also means the Send button stays disabled).
    private var amountSats: UInt64 {
        let trimmed = amountInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        switch amountDenomination {
        case "BTC":
            guard let v = Double(trimmed), v > 0 else { return 0 }
            return UInt64((v * 100_000_000).rounded())
        case "sats":
            return UInt64(trimmed) ?? 0
        default:
            guard let v = Double(trimmed), v > 0,
                  let btcPrice = store.assetPrices.price(asset: "bitcoin", fiat: amountDenomination.lowercased()),
                  btcPrice > 0 else { return 0 }
            let btc = v / btcPrice
            return UInt64((btc * 100_000_000).rounded())
        }
    }

    private var feeSection: some View {
        Section("Fee") {
            Picker("Fee target", selection: $feeMode) {
                ForEach(FeeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if feeMode == .custom {
                HStack {
                    TextField("sats/vB", text: $customSatsPerVb)
                        .keyboardType(.numberPad)
                    Text("sats/vB").foregroundStyle(.secondary)
                }
            } else if let rec = feeRecommended {
                Text("\(rec.satsPerVb(for: feeMode)) sats/vB")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading recommended fees…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Pre-sign review block: network, recipient, amount, max fee,
    /// and worst-case total (amount + max fee) with a fiat caption.
    /// Identical shape to the per-chain review sections in Solana /
    /// Tron / Ethereum send views.
    private var reviewSection: some View {
        Section("Review") {
            ReviewRow(
                label: "Network",
                value: activeNetwork.displayName,
                highlightTint: .orange
            )
            ReviewRow(
                label: "Pay to",
                value: address.isEmpty ? "-" : shortAddress(address)
            )
            ReviewRow(
                label: "Amount",
                value: amountSats > 0 ? "\(formatBTC(amountSats)) BTC" : "-",
                subValue: amountFiatCaption
            )
            ReviewRow(
                label: "Max fee",
                value: estimatedFeeSat.map { "\(formatBTC($0)) BTC (\($0.formatted()) sats)" } ?? "-"
            )
            ReviewRow(
                label: "Total",
                value: totalCostSat.map { "\(formatBTC($0)) BTC" } ?? "-",
                subValue: totalFiatCaption
            )
            if let totalCostSat,
               let balance,
               totalCostSat > balance.total.toSat() {
                Text("Total exceeds available balance.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func shortAddress(_ s: String) -> String {
        if s.count <= 24 { return s }
        return "\(s.prefix(10))…\(s.suffix(8))"
    }

    /// Conservative vbytes estimate used by both the Max button and
    /// the review section's fee preview. Mirrors `maxSpendableSat`
    /// math (1 input or N selected, 2 outputs) so the user does not
    /// see two different "fee" numbers.
    private var estimatedTxVbytes: UInt64 {
        let inputCount: UInt64
        if coinControl, !selectedUtxos.isEmpty {
            inputCount = UInt64(selectedUtxos.count)
        } else {
            inputCount = 1
        }
        return 11 + inputCount * 68 + 31 * 2
    }

    private var estimatedFeeSat: UInt64? {
        let rate = effectiveSatsPerVb
        guard rate > 0 else { return nil }
        return estimatedTxVbytes * rate
    }

    private var totalCostSat: UInt64? {
        guard amountSats > 0, let fee = estimatedFeeSat else { return nil }
        return amountSats + fee
    }

    private var amountFiatCaption: String? {
        guard amountSats > 0 else { return nil }
        let btc = Decimal(amountSats) / Decimal(100_000_000)
        return store.assetPrices.fiatCaption(
            amount: btc,
            asset: "bitcoin",
            fiat: store.fiatPreferences.code
        )
    }

    private var totalFiatCaption: String? {
        guard let total = totalCostSat else { return nil }
        let btc = Decimal(total) / Decimal(100_000_000)
        return store.assetPrices.fiatCaption(
            amount: btc,
            asset: "bitcoin",
            fiat: store.fiatPreferences.code
        )
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Signal RBF (replace-by-fee)", isOn: $rbf)
                    Text("Lets you bump the fee later if the transaction gets stuck in the mempool. Industry default is ON; disable only if your recipient has explicitly asked for a non-RBF transaction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Coin control (manual UTXO select)", isOn: $coinControl)
                if coinControl {
                    Button {
                        showUTXOPicker = true
                    } label: {
                        if selectedUtxos.isEmpty {
                            Label("Select UTXOs…", systemImage: "checklist")
                        } else {
                            Label("\(selectedUtxos.count) UTXO\(selectedUtxos.count == 1 ? "" : "s") selected", systemImage: "checklist.checked")
                        }
                    }
                }
            } label: {
                Text("Advanced")
            }
        }
    }

    // MARK: -- state-machine action buttons

    @ViewBuilder
    private var primaryActionButtons: some View {
        switch sendState {
        case .idle:
            Button {
                switch signingMechanism {
                case .software:
                    Task { await signOnly() }
                case .hardwareBLE:
                    if let op = makeHardwareReadyOp() {
                        pendingReadyOp = op
                    } else {
                        Task { await signOnly() }
                    }
                case .airgappedPSBT:
                    showOfflineSheet = true
                }
            } label: {
                Text(idleButtonLabel)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canSubmit)
        case .signing:
            HStack {
                ProgressView().controlSize(.small)
                Text(inProgressButtonLabel)
                    .frame(maxWidth: .infinity)
            }
        case .signed:
            Button {
                Task { await broadcastSignedOnly() }
            } label: {
                Label("Broadcast transaction", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
                    .bold()
            }
            .buttonStyle(.borderedProminent)
        case .broadcasting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Broadcasting…").frame(maxWidth: .infinity)
            }
        case .done:
            EmptyView()
        case .failed(_, _, let recoverable):
            if recoverable {
                Button {
                    Task { await retryCurrentPhase() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .bold()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var idleButtonLabel: String {
        switch signingMechanism {
        case .software:    return "Sign"
        case .airgappedPSBT: return "Generate PSBT for offline signing"
        case .hardwareBLE:
            let name = boundDevice?.label ?? "device"
            return "Sign using Hardware Wallet, \(name)"
        }
    }

    private var inProgressButtonLabel: String {
        switch signingMechanism {
        case .software:    return "Signing locally…"
        case .airgappedPSBT: return "Building PSBT…"
        case .hardwareBLE:
            let name = boundDevice?.label ?? "device"
            return "Signing on \(name)…"
        }
    }

    /// Build the PendingHardwareOperation that drives the shared
    /// `DeviceReadyConfirmationSheet` for Bitcoin signing. Returns
    /// nil when there's no paired device (the caller falls back to
    /// the airgapped sheet in that case).
    private func makeHardwareReadyOp() -> PendingHardwareOperation? {
        guard let device = boundDevice,
              let descriptor = store.bitcoinWalletStore.activeWallet
        else { return nil }
        return PendingHardwareOperation(
            device: device,
            purpose: .bitcoinWallet(network: descriptor.network)
        )
    }

    // MARK: -- compute / submit

    private var canSubmit: Bool {
        !address.isEmpty
            && amountSats > 0
            && effectiveSatsPerVb > 0
    }

    private var effectiveSatsPerVb: UInt64 {
        switch feeMode {
        case .custom:  return UInt64(customSatsPerVb) ?? 0
        default:       return feeRecommended?.satsPerVb(for: feeMode) ?? 0
        }
    }

    /// Phase 1 of send: build the unsigned PSBT, sign it (software
    /// biometric / hardware BLE), and stash the signed PSBT in
    /// state. Broadcast happens later, when the user explicitly
    /// taps the (now-enabled) Broadcast button.
    @MainActor
    private func signOnly() async {
        let sats = amountSats
        guard sats > 0 else { return }
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        sendState = .signing
        status = nil
        // New signature: drop any PSBT retained from a previous broadcast
        // failure so a later Retry cannot re-push stale bytes.
        retainedSignedPSBT = nil
        do {
            let outpoints = coinControl ? selectedOutpoints() : nil
            let unsignedB64 = try await wallet.buildUnsignedPSBT(
                toAddressString: address,
                amountSat: sats,
                feeRateSatsPerVb: effectiveSatsPerVb,
                enableRbf: rbf,
                selectedUtxoOutpoints: outpoints
            )
            let signedB64: String
            switch (signingMechanism, descriptor.kind) {
            case (.software, .software(let account)):
                guard let sandwich = store.sandwich else {
                    throw BitcoinWallet.WalletError.sandwichRequired
                }
                // Fresh biometric / passcode before signing (ADR-0045
                // Authorization invariant); refreshes the cache so signSoftware
                // below does not prompt again.
                _ = try await sandwich.recoveryMaterialFresh(localizedReason: "Authorize Bitcoin send")
                signedB64 = try BitcoinSigningHelpers.signSoftware(
                    unsignedBase64: unsignedB64,
                    sandwich: sandwich,
                    account: account,
                    network: descriptor.network
                )
            case (.hardwareBLE, .hardware(let deviceId, let fingerprintHex, let xpub)):
                guard let device = store.devices.find(id: deviceId) else {
                    throw BitcoinWallet.WalletError.sendFailed("Paired device for this wallet is no longer registered")
                }
                signedB64 = try await BitcoinSigningHelpers.signOverBLE(
                    unsignedBase64: unsignedB64,
                    device: device,
                    fingerprintHex: fingerprintHex,
                    accountXpub: xpub,
                    network: descriptor.network,
                    hidden: descriptor.hidden,
                    derivationPath: descriptor.derivationPath,
                    hostEntered: signingPassphrase
                )
            case (.hardwareBLE, _):
                throw BitcoinWallet.WalletError.bleSigningNotYetImplemented
            default:
                throw BitcoinWallet.WalletError.hardwareSigningNotImplemented
            }
            sendState = .signed(signedPSBTBase64: signedB64, unsignedPSBTBase64: unsignedB64)
        } catch {
            sendState = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Sign failed: \(error)",
                debugCode: BitcoinSigningHelpers.extractDebugCode(error),
                recoverable: true
            )
        }
    }

    /// Phase 2 of send: take the signed PSBT we already have and
    /// finalise + broadcast it. Splitting this from sign means a
    /// flaky network at broadcast time doesn't lose the user's
    /// signature; they can hit Retry against the SAME signed PSBT
    /// without re-summoning the hardware wallet.
    @MainActor
    private func broadcastSignedOnly() async {
        guard case let .signed(signedB64, unsignedB64) = sendState else { return }
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        let url = store.bitcoinSettings.electrumURL(for: descriptor.network)
        sendState = .broadcasting
        do {
            let txid = try await wallet.importSignedPSBTAndBroadcast(
                signedPSBTBase64: signedB64,
                originalUnsignedBase64: unsignedB64,
                electrumURL: url
            )
            // Persist the user's label, if they entered one, against
            // both the recipient address (so future txs to / from
            // the same address pre-fill) and the new txid (so the
            // tx-list row shows it immediately).
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLabel.isEmpty {
                store.bitcoinLabels.setLabel(trimmedLabel, forAddress: address)
                store.bitcoinLabels.setLabel(trimmedLabel, forOutput: txid, vout: 0)
            }
            sendState = .done(txid: txid)
            status = "Broadcast. txid \(txid.prefix(12))…"
            onBroadcast(txid)
            // Dismiss back to the wallet view so the user sees the
            // freshly-Unconfirmed transaction in the list.
            dismiss()
        } catch {
            // Broadcast-only failure: the signing already succeeded, so retain
            // the signed PSBT for a re-push without re-signing (no second
            // hardware prompt). retryCurrentPhase recovers it via lastSignedState.
            retainedSignedPSBT = (signed: signedB64, unsigned: unsignedB64)
            sendState = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Broadcast failed: \(error)",
                debugCode: BitcoinSigningHelpers.extractDebugCode(error),
                recoverable: true
            )
        }
    }

    /// Retry behaviour depends on which phase last failed. When a signed
    /// PSBT was retained (broadcast-only failure) we re-push the SAME bytes
    /// without re-signing; otherwise we restart the sign phase from scratch.
    @MainActor
    private func retryCurrentPhase() async {
        // If a signed PSBT survives in state, retry broadcast.
        // Otherwise restart the sign phase from scratch. Reset
        // state through .idle first so the UI flips out of the
        // failure indication.
        let prior = sendState
        sendState = .idle
        if case .failed = prior,
           case let .signed(b64, unsigned) = lastSignedState {
            sendState = .signed(signedPSBTBase64: b64, unsignedPSBTBase64: unsigned)
            await broadcastSignedOnly()
        } else if signingMechanism == .hardwareBLE, let op = makeHardwareReadyOp() {
            pendingReadyOp = op
        } else {
            await signOnly()
        }
    }

    /// The signed PSBT preserved across a broadcast-only failure, surfaced as
    /// a `.signed` state so retryCurrentPhase can re-broadcast without re-signing.
    /// `.idle` when nothing is retained (a sign-time failure), forcing a re-sign.
    private var lastSignedState: SendState {
        if let r = retainedSignedPSBT {
            return .signed(signedPSBTBase64: r.signed, unsignedPSBTBase64: r.unsigned)
        }
        return .idle
    }

    /// Map the picker's typed key set into BDK's `[OutPoint]`.
    /// We construct OutPoints from the txid string + vout. BDK's
    /// `Txid` initializer parses canonical hex.
    private func selectedOutpoints() -> [OutPoint] {
        selectedUtxos.compactMap { key in
            guard let txid = try? Txid.fromString(hex: key.txid) else { return nil }
            return OutPoint(txid: txid, vout: key.vout)
        }
    }

    // Software / hardware-BLE signing helpers extracted to
    // BitcoinSigningHelpers so BumpFeeSheet can reuse them.

    @MainActor
    private func loadBalance() async {
        balance = await wallet.balance()
        await refreshMaxDrain()
    }

    /// Build a BDK `drainWallet + drainTo` draft PSBT under the
    /// current fee rate + coin-control selection and stash the
    /// resulting recipient-output value in `maxDrainSat`. Falls
    /// back to 0 (Max disabled) if BDK can't build a draft (e.g.
    /// pool too small to cover the fee).
    @MainActor
    private func refreshMaxDrain() async {
        let rate = effectiveSatsPerVb
        guard rate > 0 else {
            maxDrainSat = 0
            return
        }
        // Use the wallet's own next-unused receive address as the
        // drain target so we have a known-valid script. Doesn't
        // mutate keychain state (peek, not reveal).
        let placeholder = await wallet.nextUnusedReceiveAddress().address.description
        let outpoints: [OutPoint]? = (coinControl && !selectedUtxos.isEmpty)
            ? selectedOutpoints()
            : nil
        do {
            maxDrainSat = try await wallet.previewMaxDrainSat(
                toAddressString: placeholder,
                feeRateSatsPerVb: rate,
                selectedUtxoOutpoints: outpoints
            )
        } catch {
            // BDK throws when the candidate UTXOs can't cover the
            // fee at the chosen rate. Surface as a disabled Max
            // button rather than an error sheet.
            maxDrainSat = 0
        }
    }

    @MainActor
    private func loadFees() async {
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        let base = store.bitcoinSettings.mempoolURL(for: descriptor.network)
        // Fall back to a sensible static recommendation if mempool.space
        // is unreachable (regtest, captive portal, transient blip). Without
        // a fee, effectiveSatsPerVb is 0 and the Send button stays
        // permanently disabled, which is what was making "Send via
        // device" look greyed-out-by-design when it was really just
        // waiting on a fee number.
        if let live = try? await BitcoinFeeEstimator.fetch(baseURL: base) {
            feeRecommended = live
        } else {
            feeRecommended = BitcoinFeeEstimator.fallback
        }
    }

    private func stripBitcoinPrefix(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.lowercased().hasPrefix("bitcoin:") {
            out = String(out.dropFirst("bitcoin:".count))
        }
        // Strip query params if a bitcoin: URI was pasted
        if let q = out.firstIndex(of: "?") {
            out = String(out[..<q])
        }
        return out
    }
}

// Minimal QR scanner wrapper for the Send view. Reuses the existing
// QRScannerView component used by the Receive credential flow.
private struct ScanAddressSheet: View {
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
