// Multi-step sheet for the "Tap ID document" action.
//
// Step 1 (form):    Collect document number, birth date, expiry. The
//                   chip will only unlock to these three values.
// Step 2 (scan):    Kicks off the NFC session. The library shows its
//                   own bottom sheet; we keep our sheet on a quiet
//                   "Looking for the chip..." screen as a fallback.
// Step 3 (review):  Show what came off the chip with a Save button.

import SwiftUI
import UIKit

struct TapIDDocumentSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Called when the sheet finishes. `savedDocId` is the stored document
    /// (nil if the user cancelled before saving). Issuance now happens inline
    /// in the minted step, so the caller just needs to dismiss the sheet.
    var onFinish: (_ savedDocId: UUID?) -> Void = { _ in }

    /// When true, skip the document-kind picker and go straight to the passport
    /// form (onboarding's "Scan your passport" is passport-specific).
    var skipKindPicker: Bool = false

    enum Step: Hashable { case kindPicker, form, scanning, review, minted, error }

    /// Inline issuance state for the minted step's "Get a verified
    /// credential from an issuer" action. Mirrors the issuance flow on
    /// IDDocumentDetailView so the user can request a verified
    /// credential immediately after the scan without hunting for it.
    enum IssuanceState: Equatable {
        case idle
        case submitting
        case submittedForAnchor(credentialId: String)
        case pendingReview(pendingId: String, proofPreVerified: Bool, reason: String)
        case failed(String)
    }

    @State private var mintedDocId: UUID?
    @State private var issuance: IssuanceState = .idle
    /// Selected issuer Picker entry (a KnownIssuersStore host /
    /// `host:port`, or `IssuerSelection.customSentinel`) and the
    /// free-form URL typed when Custom is chosen.
    @State private var selectedIssuerEntry: String = ""
    @State private var customIssuerURL: String = ""

    @State private var step: Step = .kindPicker
    @State private var parameters = IDDocumentReadParameters(
        kind: .passport,
        documentNumber: "", dateOfBirthYYMMDD: "", dateOfExpiryYYMMDD: ""
    )
    /// Full 4-digit-year date entry (YYYYMMDD digits) the user types. The
    /// chip's BAC key only needs the 2-digit-year YYMMDD, derived from these by
    /// dropping the century, so `parameters` stays MRZ-shaped.
    @State private var dobDigits = ""
    @State private var expDigits = ""
    @State private var lastError: String?
    @State private var readResult: IDDocumentReadResult?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .kindPicker:
                    if skipKindPicker {
                        // Passport-only entry (onboarding): skip straight to the form.
                        Color.clear.onAppear {
                            parameters.kind = .passport
                            step = .form
                        }
                    } else {
                        kindPickerStep
                    }
                case .form:       formStep
                case .scanning:   scanningStep
                case .review:     reviewStep
                case .minted:     mintedStep
                case .error:      errorStep
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .minted {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var navTitle: String {
        switch step {
        case .kindPicker: return "Tap ID document"
        case .minted:     return "Saved"
        case .form, .scanning, .review, .error:
            return parameters.kind.displayName
        }
    }

    // MARK: -- step 0: kind picker

    @ViewBuilder
    private var kindPickerStep: some View {
        Form {
            Section {
                Text("What kind of document are you about to tap?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(IDDocumentKind.allCases) { kind in
                    Button {
                        parameters.kind = kind
                        step = .form
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.iconName)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.displayName)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(kind.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: -- step 1: form

    @ViewBuilder
    private var formStep: some View {
        Form {
            // Compact, box-free header (matches Android): a small passport+NFC
            // image (passport only) and a one-line caption.
            Section {
                VStack(spacing: 8) {
                    if parameters.kind == .passport {
                        Image("PassportNFC")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 150, maxHeight: 84)
                            .accessibilityLabel("Chip-enabled passport")
                    }
                    Text(formIntro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.clear)
            Section {
                TextField(parameters.kind.documentNumberLabel, text: $parameters.documentNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .font(.system(.body, design: .monospaced))
                // YYYY-MM-DD entry: the user types the full 4-digit year and the
                // dashes appear LIVE (eager trailing separator) via a UITextField
                // (a SwiftUI TextField bound to a reformatting Binding does not
                // re-read its getter mid-edit, so the mask only applied on commit).
                // The chip-facing value stays the 2-digit-year YYMMDD the MRZ /
                // BAC key derivation expects (the century is dropped on the way in).
                MaskedDateField(placeholder: "Date of birth (YYYY-MM-DD)", digits: $dobDigits)
                    .onChange(of: dobDigits) { _, new in
                        parameters.dateOfBirthYYMMDD = Self.yymmdd(fromYYYYMMDD: new)
                    }
                MaskedDateField(placeholder: "Date of expiry (YYYY-MM-DD)", digits: $expDigits)
                    .onChange(of: expDigits) { _, new in
                        parameters.dateOfExpiryYYMMDD = Self.yymmdd(fromYYYYMMDD: new)
                    }
            } header: {
                Text("Document details")
            } footer: {
                Text("The passport can only be read if the passport number, date of birth, and expiration are entered correctly.")
                .font(.caption)
            }
            Section {
                Button {
                    step = .scanning
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
                if !skipKindPicker {
                    Button {
                        step = .kindPicker
                    } label: {
                        Text("Change document type")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                if !IDDocumentReader.isAvailable {
                    Label(
                        "NFC reading isn't available on this device. You can still fill in the details, but the scan step will not work here.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var canContinue: Bool {
        // Require all three values to be set deliberately. The date
        // pickers start on placeholder defaults (30 years ago, +5
        // years); submitting those silently derives the wrong BAC/PACE
        // key and the chip answers 0x63Cx ("verification failed"),
        // which reads to the user as a scan glitch. Gating Continue on
        // the user having actually touched both pickers turns that
        // into an obvious "fill this in" instead.
        !parameters.documentNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && dobDigits.count == 8
            && expDigits.count == 8
    }

    /// Kind-specific opening sentence shown above the number /
    /// date inputs.
    private var formIntro: String {
        switch parameters.kind {
        case .passport:
            return "Type your details from inside of your passport, then place your phone over the passport."
        case .other:
            return "Type the details from the data page of your ID, then tap your phone to it when the system NFC sheet appears."
        }
    }

    /// Drop the century from a complete YYYYMMDD to the MRZ-shaped YYMMDD the
    /// chip's BAC key needs; returns "" until all 8 digits are present.
    private static func yymmdd(fromYYYYMMDD digits: String) -> String {
        let d = digits.filter(\.isNumber)
        return d.count == 8 ? String(d.dropFirst(2)) : ""
    }

    // MARK: -- step 2: scanning

    @ViewBuilder
    private var scanningStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text("Hold your phone over top of the NFC enabled passport")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Move slowly until the phone finds the chip. The bottom of an iPhone reads best.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                step = .form
            } label: {
                Text("Cancel scan")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task(id: step) {
            guard step == .scanning else { return }
            await performRead()
        }
    }

    @MainActor
    private func performRead() async {
        let reader = IDDocumentReader()
        do {
            let result = try await reader.read(parameters: parameters)
            readResult = result
            step = .review
        } catch let e as IDDocumentReaderError {
            lastError = e.errorDescription
            step = .error
        } catch {
            lastError = error.localizedDescription
            step = .error
        }
    }

    // MARK: -- step 3: review

    @ViewBuilder
    private var reviewStep: some View {
        if let result = readResult {
            Form {
                Section {
                    HStack(spacing: 16) {
                        if let img = result.photo {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.15))
                                .frame(width: 80, height: 100)
                                .overlay(Image(systemName: "person.crop.rectangle").foregroundStyle(.tertiary))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.document.displayName)
                                .font(.title3.weight(.semibold))
                            if let native = result.document.nativeDisplayName {
                                Text(native)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(result.document.kindLabel) · \(result.document.summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Details") {
                    let docLabel = result.document.userDeclaredKind?.documentNumberLabel ?? "Document number"
                    detailRow(docLabel, value: result.document.documentNumber)
                    // Personal number intentionally not shown (ADR-0039).
                    if let dob = result.document.formattedDateOfBirth {
                        detailRow("Date of birth", value: dob)
                    }
                    if let exp = result.document.formattedDateOfExpiry {
                        detailRow("Expires", value: exp)
                    }
                    if let sex = result.document.sex, !sex.isEmpty {
                        detailRow("Sex", value: sex)
                    }
                    if let nat = IDDocument.countryName(for: result.document.nationality) {
                        detailRow("Nationality", value: nat)
                    }
                    if let pob = result.document.formattedPlaceOfBirth, !pob.isEmpty {
                        detailRow("Place of birth", value: pob)
                    }
                }
                Section {
                    Button {
                        save(result: result)
                    } label: {
                        Label("Save to wallet", systemImage: "tray.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        readResult = nil
                        step = .form
                    } label: {
                        Text("Discard").frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Saved documents stay on this phone. Tap one on the Identity tab to view it.")
                        .font(.caption)
                }
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func save(result: IDDocumentReadResult) {
        // De-dup (ADR-0037): refuse a second copy of the same document with a
        // friendly message rather than saving a duplicate card.
        if store.idDocuments.isDuplicate(result.document) {
            lastError = "This document is already saved."
            step = .error
            return
        }
        let saved = store.idDocuments.add(
            result.document,
            photo: result.photo,
            rawChipData: result.rawChipData
        )
        mintedDocId = saved.id
        // Run the chip-authenticity (passive auth / CSCA chain) check now, on
        // import, so the genuineness badge is already resolved the first time the
        // passport card is opened (not only after visiting Advanced).
        Task { await store.ensurePassiveAuth(for: saved) }
        // The saved passport is itself the single card on the Identity tab; it
        // can be presented as a self-signed credential on demand from its
        // detail screen (no separate credential card is created). Offer the
        // optional Elabify verified credential as the next step.
        step = .minted
    }

    // MARK: -- step: minted (local credential saved + inline issuer issuance)

    @ViewBuilder
    private var mintedStep: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: localCredentialIcon)
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text(localCredentialStatus)
                        .font(.callout)
                }
                .padding(.vertical, 2)
            }
            issuanceSection
        }
    }

    /// Inline "get a verified credential" flow, rendered per state.
    @ViewBuilder
    private var issuanceSection: some View {
        switch issuance {
        case .idle:
            Section {
                Text("Send the document to an issuer for verification, sanctions screening, and anchoring on ledger that any compatible verifier can check.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                IssuerPickerField(
                    knownIssuers: store.knownIssuers,
                    selectedEntry: $selectedIssuerEntry,
                    customURL: $customIssuerURL
                )
                Button {
                    Task { await runMintIssuance() }
                } label: {
                    Label("Get verified credential", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canIssue)
                if let hint = issuanceDisabledHint {
                    Text(hint).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Button("Done, keep the local credential only") {
                    onFinish(mintedDocId)
                    dismiss()
                }
            }
        case .submitting:
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Submitting to \(submittingHost)…").font(.callout)
                }
            }
        case .submittedForAnchor:
            Section {
                Label("Submitted; anchoring in background", systemImage: "checkmark.seal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                Text("Your verified credential is being anchored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                doneButton
            }
        case .pendingReview(let pendingId, let preVerified, let reason):
            Section {
                Label(
                    preVerified ? "Submitted, pre-verified" : "Submitted, awaiting manual review",
                    systemImage: preVerified ? "checkmark.seal" : "clock.badge.questionmark"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(preVerified ? .green : .orange)
                if preVerified {
                    Text("The issuer accepted your passport's chip-signed bytes and confirmed they chain to a recognised national CSCA. An operator will approve it shortly.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Pre-verification did not complete automatically (\(reason)). An operator will review your packet shortly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Pending ID: \(pendingId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                doneButton
            }
        case .failed(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button {
                    issuance = .idle
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("Done, keep the local credential only") {
                    onFinish(mintedDocId)
                    dismiss()
                }
            }
        }
    }

    private var doneButton: some View {
        Button {
            onFinish(mintedDocId)
            dismiss()
        } label: {
            Text("Done").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var localCredentialIcon: String { "checkmark.seal.fill" }

    private var localCredentialStatus: String {
        "Document verified and saved locally"
    }

    // MARK: -- minted-step issuance helpers

    private var mintedDoc: IDDocument? {
        guard let id = mintedDocId else { return nil }
        return store.idDocuments.documents.first { $0.id == id }
    }

    private var resolvedIssuerBaseURL: URL? {
        IssuerSelection.resolveBaseURL(
            selectedEntry: selectedIssuerEntry,
            customURL: customIssuerURL,
            knownIssuers: store.knownIssuers
        )
    }

    private var canIssue: Bool {
        guard let doc = mintedDoc else { return false }
        return doc.sodFilename != nil
            && store.sandwich != nil
            && resolvedIssuerBaseURL != nil
    }

    /// One-line reason the Issue button is disabled, shown beneath it so
    /// the path forward is obvious (re-tap for SOD, unlock, pick issuer).
    private var issuanceDisabledHint: String? {
        guard let doc = mintedDoc else { return nil }
        if doc.sodFilename == nil {
            return "Chip-signed material isn't captured. Re-tap the document so Maknoon can store the SOD bytes; the issuer needs them to validate."
        }
        if store.sandwich == nil {
            return "Unlock your identity first, then try again."
        }
        if resolvedIssuerBaseURL == nil {
            return "Pick an issuer or enter a custom URL."
        }
        return nil
    }

    /// Host[:port] shown in the "Submitting to …" line, mirroring the
    /// URL the request actually targets.
    private var submittingHost: String {
        guard let base = resolvedIssuerBaseURL, let host = base.host else { return "issuer" }
        if let port = base.port { return "\(host):\(port)" }
        return host
    }

    @MainActor
    private func runMintIssuance() async {
        guard let doc = mintedDoc else {
            issuance = .failed("The saved document could not be found.")
            return
        }
        guard let baseURL = resolvedIssuerBaseURL else {
            issuance = .failed("Pick an issuer or enter a custom URL.")
            return
        }
        issuance = .submitting
        do {
            switch try await IDDocumentIssuance.submit(doc: doc, store: store, baseURL: baseURL) {
            case .submittedForAnchor(let credentialId):
                issuance = .submittedForAnchor(credentialId: credentialId)
            case .pendingReview(let pendingId, let preVerified, let reason):
                issuance = .pendingReview(
                    pendingId: pendingId,
                    proofPreVerified: preVerified,
                    reason: reason
                )
            }
        } catch {
            issuance = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: -- step 4: error

    @ViewBuilder
    private var errorStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.orange)
            Text("Scan didn't finish")
                .font(.headline)
            Text(lastError ?? "Something went wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                step = .scanning
            } label: {
                Text("Try again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            Button {
                step = .form
            } label: {
                Text("Edit details").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

/// A `UITextField`-backed field that masks an 8-digit YYYYMMDD entry as
/// "YYYY-MM-DD" LIVE on every keystroke, with an EAGER trailing separator: the
/// dash shows the instant a group completes ("2017-" the moment the 4th digit is
/// typed). The model stays the raw digit string (`digits`). A SwiftUI TextField
/// bound to a reformatting Binding does not re-read its getter mid-edit, so the
/// mask only applied on commit — hence the UIKit field (ADR-0043).
struct MaskedDateField: UIViewRepresentable {
    let placeholder: String
    @Binding var digits: String

    /// digits -> "YYYY-MM-DD" with the eager trailing dash.
    static func format(_ digits: String) -> String {
        let d = Array(digits.filter(\.isNumber).prefix(8))
        var out = ""
        for (i, c) in d.enumerated() {
            if i == 4 || i == 6 { out.append("-") }
            out.append(c)
        }
        if d.count == 4 || d.count == 6 { out.append("-") }
        return out
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.keyboardType = .numberPad
        tf.placeholder = placeholder
        tf.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular
        )
        tf.text = Self.format(digits)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        let formatted = Self.format(digits)
        if tf.text != formatted { tf.text = formatted }
    }

    func makeCoordinator() -> Coordinator { Coordinator($digits) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let digits: Binding<String>
        init(_ digits: Binding<String>) { self.digits = digits }

        func textField(
            _ tf: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = tf.text ?? ""
            guard let r = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: r, with: string)
            var newDigits = String(proposed.filter(\.isNumber))
            if string.isEmpty {
                // Deletion: if only a separator was removed (digit count
                // unchanged), drop the last digit so one backspace clears the
                // eager trailing dash AND the digit it followed.
                let curDigits = current.filter(\.isNumber)
                if newDigits.count == curDigits.count, !newDigits.isEmpty {
                    newDigits = String(newDigits.dropLast())
                }
            }
            newDigits = String(newDigits.prefix(8))
            digits.wrappedValue = newDigits
            tf.text = MaskedDateField.format(newDigits)
            let end = tf.endOfDocument
            tf.selectedTextRange = tf.textRange(from: end, to: end)
            return false
        }
    }
}
