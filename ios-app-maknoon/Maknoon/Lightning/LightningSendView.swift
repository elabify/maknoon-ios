// Pay a BOLT11 invoice or an LNURL-pay request via the active
// LNDHub account. Auto-detects which input form the user pasted:
//
//   • Strings starting with `lnbc` (or `lightning:lnbc...`) →
//     BOLT11. Sent straight to LNDHub /payinvoice.
//   • Strings starting with `lnurl1` (or `lightning:lnurl...`) →
//     LNURL-pay. Fetched, then the user picks an amount inside
//     the issuer's min/max, then the resolved invoice is paid.
//
// LNURL-withdraw and LNURL-auth are out of scope for this cut.

import SwiftUI

struct LightningSendView: View {
    var onPaid: () -> Void = {}
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case input
        case lnurlReady(LNURL.PayRequest)
        case sending
        case sent(LNDHubClient.PaymentResult)
        case error(String)
    }

    @State private var inputText: String = ""
    @State private var phase: Phase = .input
    /// The user-visible amount, in whatever denomination they
    /// picked. Replaces the previous sats-only field so a user can
    /// pay LNURL invoices in BTC, sats, or their preferred fiat.
    @State private var lnurlAmountInput: String = ""
    /// "sats", "BTC", or a fiat code like "USD" / "AED".
    @State private var lnurlAmountDenom: String = "sats"
    @State private var lnurlComment: String = ""
    @State private var showScanner: Bool = false
    @State private var showContacts: Bool = false
    @State private var showEditAddressBook: Bool = false

    /// Picker options for LNURL amount denomination. Mirrors the
    /// Bitcoin send view: always offers sats and BTC, appends the
    /// user's preferred fiat code as a third option when it's
    /// not already in the list.
    private var lnurlDenomOptions: [String] {
        var out: [String] = ["sats", "BTC"]
        let user = store.fiatPreferences.code.uppercased()
        if !user.isEmpty, user != "BTC", user != "SATS" {
            out.append(user)
        }
        return out
    }

    /// The current input parsed into satoshis, regardless of which
    /// denomination the user is typing in. Returns nil on parse
    /// failure or when a fiat conversion can't resolve a price yet,
    /// in which case the Pay button stays disabled.
    private var lnurlAmountSats: Int64? {
        let trimmed = lnurlAmountInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch lnurlAmountDenom {
        case "sats":
            return Int64(trimmed)
        case "BTC":
            guard let v = Double(trimmed), v > 0 else { return nil }
            return Int64((v * 100_000_000).rounded())
        default:
            // Fiat code. Convert via the cached BTC/<fiat> rate.
            guard let v = Double(trimmed), v > 0,
                  let btcPrice = store.assetPrices.price(asset: "bitcoin", fiat: lnurlAmountDenom.lowercased()),
                  btcPrice > 0 else { return nil }
            let btc = v / btcPrice
            return Int64((btc * 100_000_000).rounded())
        }
    }

    /// Captions below the amount field. Show the OTHER denominations
    /// (and always USD if neither sats nor BTC nor USD is selected)
    /// so a wrong-zero typo gets a sanity check in the other units.
    private var lnurlAmountCaptions: [String] {
        guard let sats = lnurlAmountSats, sats > 0 else { return [] }
        var out: [String] = []
        let btc = Decimal(sats) / Decimal(100_000_000)
        if lnurlAmountDenom != "sats" {
            out.append("\(sats) sats")
        }
        if lnurlAmountDenom != "BTC" {
            out.append(String(format: "%.8f BTC", Double(sats) / 100_000_000.0))
        }
        if lnurlAmountDenom.uppercased() != "USD" {
            if let cap = store.assetPrices.fiatCaption(amount: btc, asset: "bitcoin", fiat: "usd") {
                out.append(cap)
            }
        }
        return out
    }

    private var activeAccount: LightningAccount? {
        store.lightningAccountStore.activeAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .input, .error:
                    inputSection
                    if case .error(let msg) = phase {
                        Section { Text(msg).foregroundStyle(.red).font(.callout) }
                    }
                case .lnurlReady(let req):
                    lnurlAmountSection(req)
                case .sending:
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Routing payment…").font(.callout)
                        }
                    }
                case .sent(let result):
                    sentSection(result)
                }
            }
            .navigationTitle("Send Lightning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView(onCode: { code in
                        inputText = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        showScanner = false
                    })
                    .ignoresSafeArea()
                    .navigationTitle("Scan invoice or LNURL")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showContacts) {
                AddressBookPickerSheet(
                    network: .lightning,
                    onPick: { entry in inputText = entry.address },
                    onEdit: { showEditAddressBook = true }
                )
                .environment(store)
            }
            .sheet(isPresented: $showEditAddressBook) {
                NavigationStack {
                    AddressBookView().environment(store)
                }
            }
            .onAppear {
                if inputText.isEmpty,
                   let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   isPlausiblePayable(s) {
                    inputText = s
                }
            }
        }
    }

    // MARK: -- sections

    private var inputSection: some View {
        Section {
            HStack {
                TextField("lnbc…, lnurl1…, or you@domain.tld", text: $inputText, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...6)
                Button {
                    if let s = UIPasteboard.general.string {
                        inputText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                Button {
                    showScanner = true
                } label: { Image(systemName: "qrcode.viewfinder") }
                .buttonStyle(.borderless)
                Button {
                    showContacts = true
                } label: { Image(systemName: "person.text.rectangle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pick from contacts")
            }
            Button {
                Task { await proceed() }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputText.isEmpty || activeAccount == nil)
        } header: {
            Text("Invoice or LNURL")
        } footer: {
            Text("BOLT11 invoices are paid immediately. LNURLs are fetched first; you pick an amount inside the issuer's allowed range.")
                .font(.caption)
        }
    }

    private func lnurlAmountSection(_ req: LNURL.PayRequest) -> some View {
        let minSat = req.minSendable / 1_000
        let maxSat = req.maxSendable / 1_000
        let desc = LNURL.extractDescription(metadataJSON: req.metadata) ?? "Lightning payment"
        return Group {
            Section {
                Text(desc).font(.callout).foregroundStyle(.secondary)
                LabeledContent("Min", value: "\(minSat) sat")
                LabeledContent("Max", value: "\(maxSat) sat")
            } header: {
                Text("LNURL details")
            }
            Section {
                HStack {
                    TextField(lnurlAmountDenom == "sats" ? "0" : "0.00", text: $lnurlAmountInput)
                        .keyboardType(lnurlAmountDenom == "sats" ? .numberPad : .decimalPad)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: $lnurlAmountDenom) {
                        ForEach(lnurlDenomOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                ForEach(lnurlAmountCaptions, id: \.self) { line in
                    HStack {
                        Spacer()
                        Text(line).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                if (req.commentAllowed ?? 0) > 0 {
                    TextField("Comment (optional, max \(req.commentAllowed!) chars)", text: $lnurlComment)
                }
            } header: {
                Text("Amount")
            }
            Section {
                Button {
                    Task { await payLNURL(req) }
                } label: {
                    Text("Pay").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isAmountValid(req: req))
            }
        }
    }

    private func sentSection(_ result: LNDHubClient.PaymentResult) -> some View {
        Section {
            Label("Paid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.semibold))
            if let amt = result.amountSat {
                LabeledContent("Amount", value: "\(amt) sat")
            }
            if let fee = result.feeSat {
                LabeledContent("Fee", value: "\(fee) sat")
            }
            LabeledContent("Preimage") {
                Text(result.preimage.prefix(16) + "…")
                    .font(.caption.monospaced())
            }
            Button("Done") {
                onPaid()
                dismiss()
            }
        }
    }

    // MARK: -- behaviour

    private func isPlausiblePayable(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("lnbc")
            || lower.hasPrefix("lntb")
            || lower.hasPrefix("lnurl")
            || lower.hasPrefix("lightning:")
            || isLightningAddress(s)
    }

    /// LUD-16 Lightning Address shape: `user@domain.tld`. Cheap shape
    /// check, not a full RFC 5321 mailbox validator, just enough to
    /// disambiguate from invoice / lnurl strings.
    private func isLightningAddress(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    private func isAmountValid(req: LNURL.PayRequest) -> Bool {
        guard let sat = lnurlAmountSats, sat > 0 else { return false }
        let msat = sat * 1_000
        return msat >= req.minSendable && msat <= req.maxSendable
    }

    @MainActor
    private func proceed() async {
        var s = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("lightning:") {
            s = String(s.dropFirst("lightning:".count))
        }
        let lower = s.lowercased()
        if lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") {
            await payBOLT11(s)
        } else if lower.hasPrefix("lnurl") || isLightningAddress(s) {
            // Lightning Address (`user@domain.tld`) and bech32 LNURL
            // both end up at a payRequest endpoint; LNURL.decode
            // handles the URL rewrite for both shapes.
            await resolveLNURL(s)
        } else {
            phase = .error("Doesn't look like a BOLT11 invoice, LNURL, or Lightning Address. Expected lnbc…, lntb…, lnurl1…, or you@domain.tld.")
        }
    }

    @MainActor
    private func payBOLT11(_ invoice: String) async {
        guard let client = activeClient() else { return }
        // Fresh biometric / passcode before sending funds (ADR-0045
        // Authorization invariant). Lightning is custodial (LNDHub), so there is
        // no sandwich seed to gate; use the device-owner-auth gate directly.
        guard await LocalAuth.authorize(reason: "Authorize Lightning payment") else { return }
        phase = .sending
        do {
            let result = try await client.payInvoice(invoice)
            phase = .sent(result)
            LogStore.shared.info("lightning.send", "BOLT11 paid: amount=\(result.amountSat ?? 0) fee=\(result.feeSat ?? 0)")
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    @MainActor
    private func resolveLNURL(_ raw: String) async {
        do {
            let url = try LNURL.decode(raw)
            phase = .sending
            let req = try await LNURL.fetchPayRequest(url)
            phase = .lnurlReady(req)
            // Pre-fill amount with the min for convenience. The min
            // is in millisats; we display it in whichever denomination
            // the user has selected, defaulting to sats.
            let minSats = req.minSendable / 1_000
            lnurlAmountDenom = "sats"
            lnurlAmountInput = "\(minSats)"
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    @MainActor
    private func payLNURL(_ req: LNURL.PayRequest) async {
        guard let client = activeClient(), let sat = lnurlAmountSats, sat > 0 else { return }
        // Fresh biometric / passcode before sending funds (ADR-0045).
        guard await LocalAuth.authorize(reason: "Authorize Lightning payment") else { return }
        phase = .sending
        do {
            let invoice = try await LNURL.fetchInvoice(
                payRequest: req,
                amountSat: sat,
                comment: lnurlComment.isEmpty ? nil : lnurlComment
            )
            let result = try await client.payInvoice(invoice, amountSat: nil)
            phase = .sent(result)
            LogStore.shared.info("lightning.send", "LNURL paid: amount=\(sat) fee=\(result.feeSat ?? 0)")
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func activeClient() -> LNDHubClient? {
        guard let account = activeAccount,
              let password = (try? store.lightningAccountStore.password(for: account.id)) ?? nil
        else {
            phase = .error("No active Lightning account. Add one in Settings → Networks → Lightning.")
            return nil
        }
        return LNDHubClient(account: account, password: password)
    }
}
