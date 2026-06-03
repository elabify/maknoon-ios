// Detail view for a saved ID document. Tap a card on the Identity
// tab to land here. Read-only; user can rename or delete.

import SwiftUI

struct IDDocumentDetailView: View {
    let documentId: UUID
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var nicknameDraft: String = ""
    @State private var isEditingNickname = false

    enum IssuanceState: Equatable {
        case idle
        case submitting
        /// Packet accepted but waiting for an operator to approve in
        /// /admin/pending-attestations. Reached when the issuer has
        /// auto-mint disabled or pre-verification didn't pass.
        case pendingReview(pendingId: String, proofPreVerified: Bool, reason: String)
        /// Issuer auto-approved on submit; the holder's
        /// PendingPickupsStore is now polling in the background and
        /// will deposit the credential into the wallet as soon as
        /// the issuer's batch flushes. User is free to close this
        /// screen — pending VCs appear at the top of the Identity
        /// tab where they can be cancelled.
        case submittedForAnchor(credentialId: String)
        case failed(String)
    }

    @State private var issuanceState: IssuanceState = .idle

    /// Sanctions-screening flow state, independent of issuance.
    enum SanctionsState: Equatable {
        case idle
        case checking
        case failed(String)
    }
    @State private var sanctionsState: SanctionsState = .idle
    @State private var passiveAuthRunning = false

    /// On-demand self-signed credential minted from this document for the
    /// Present (QR) flow. Set to drive the present sheet; the credential is
    /// not persisted as a separate card.
    @State private var presentCredential: Credential?
    @State private var presentError: String?

    /// The selected entry in the issuer Picker. Stored as a host /
    /// `host:port` string from `KnownIssuersStore`, or the sentinel
    /// `__custom__` when the user wants to type a one-off URL.
    @State private var selectedIssuerEntry: String = ""
    /// Free-form URL the user types when the Custom row is selected.
    /// Either a bare host (`musnad.elabify.com`), a `host:port`, or a
    /// full URL with scheme + path. Resolved at submit time.
    @State private var customIssuerURL: String = ""

    private var doc: IDDocument? {
        store.idDocuments.documents.first { $0.id == documentId }
    }

    var body: some View {
        if let doc {
            Form {
                photoSection(doc)
                detailsSection(doc)
                presentSection(doc)
                chipAuthSection(doc)
                issueVerifiedSection(doc)
                nicknameSection(doc)
                folderSection(doc)
                deleteSection(doc)
            }
            .navigationTitle(doc.nickname ?? doc.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $presentCredential) { cred in
                NavigationStack {
                    CredentialPresentView(credential: cred).environment(store)
                }
            }
            .onAppear { nicknameDraft = doc.nickname ?? "" }
            // Run on-device Passive Authentication once the view appears (and
            // whenever the document changes). Idempotent + cheap to re-run.
            .task(id: documentId) { await runPassiveAuth(for: doc) }
        } else {
            // Defensive: if the document disappears from the store
            // while this view is on screen (deletion from anywhere,
            // background sync, etc.), auto-dismiss instead of
            // stranding the user on an empty view with broken
            // navigation chrome.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func photoSection(_ doc: IDDocument) -> some View {
        Section {
            HStack(spacing: 16) {
                if let img = store.idDocuments.photo(for: doc) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 90, height: 110)
                        .overlay(Image(systemName: doc.iconName)
                            .font(.title)
                            .foregroundStyle(.tertiary))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(doc.displayName)
                        .font(.title3.weight(.semibold))
                    if let native = doc.nativeDisplayName {
                        Text(native)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(doc.kindLabel) · \(doc.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func detailsSection(_ doc: IDDocument) -> some View {
        Section("Details") {
            let docLabel = doc.userDeclaredKind?.documentNumberLabel ?? "Document number"
            row(docLabel, value: doc.documentNumber, monospaced: true)
            if let pn = doc.personalNumber, !pn.isEmpty {
                let label = doc.userDeclaredKind?.personalNumberLabel ?? "Personal number"
                row(label, value: pn, monospaced: true)
            }
            // Given + Family rendered separately so each is a labelled
            // attribute the user can copy independently. Prefer the
            // MRZ-derived Latin form (which is what foreign verifiers
            // see); fall back to the library-reported form for legacy
            // saved docs that pre-date the MRZ parser.
            let given = (doc.latinGivenNames ?? doc.givenNames).trimmingCharacters(in: .whitespaces)
            let family = (doc.latinSurname ?? doc.surname).trimmingCharacters(in: .whitespaces)
            if !given.isEmpty {
                row("Given name", value: given)
            }
            if !family.isEmpty {
                row("Family name", value: family)
            }
            // Native-script name as its own row when the chip exposed
            // one in DG11 and it differs from the Latin form. CHN /
            // JPN / KOR / Arabic-script issuers show up here.
            if let native = doc.nativeFullName?.trimmingCharacters(in: .whitespaces),
               !native.isEmpty,
               native.caseInsensitiveCompare("\(given) \(family)".trimmingCharacters(in: .whitespaces)) != .orderedSame {
                row("Native name", value: native)
            }
            if let dob = doc.formattedDateOfBirth {
                row("Date of birth", value: dob)
            }
            if let exp = doc.formattedDateOfExpiry {
                row("Expires", value: exp)
            }
            if let sex = doc.sex, !sex.isEmpty {
                row("Sex", value: sex)
            }
            if let nat = IDDocument.countryName(for: doc.nationality) {
                row("Nationality", value: nat)
            }
            if let issuer = IDDocument.countryName(for: doc.issuingAuthority) {
                row("Issued by", value: issuer)
            }
            if let pob = doc.formattedPlaceOfBirth, !pob.isEmpty {
                row("Place of birth", value: pob)
            }
            row("Saved", value: dateString(doc.readAt))
        }
    }

    @ViewBuilder
    private func presentSection(_ doc: IDDocument) -> some View {
        Section {
            Text("Present this passport as a self-signed credential: a QR another Maknoon user can verify on the spot, fully offline. It is signed by your post-quantum key and (on a real device) bound to this app via App Attest. No issuer, no network.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                presentError = nil
                guard let sandwich = store.sandwich else {
                    presentError = "Unlock your identity first."
                    return
                }
                do {
                    presentCredential = try LocalCredentialFactory.mint(from: doc, sandwich: sandwich)
                } catch {
                    presentError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            } label: {
                Label("Present (show QR)", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.sandwich == nil)
            if let presentError {
                Text(presentError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Present")
        }
    }

    @ViewBuilder
    private func issueVerifiedSection(_ doc: IDDocument) -> some View {
        Section {
            switch issuanceState {
            case .idle:
                Text("Upload the document's chip-signed fields to an issuer service for verification and sanctions screening, then issue a post-quantum credential anchored privately on ledger. You will receive an identity verified credential in your wallet that can be shared with any Elabify-compatible verifier.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Uploaded: name, document number, dates, nationality, sex. NOT uploaded: chip photo (stays on this device).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                IssuerPickerField(
                    knownIssuers: store.knownIssuers,
                    selectedEntry: $selectedIssuerEntry,
                    customURL: $customIssuerURL
                )
                Button {
                    Task { await runIssuance(for: doc) }
                } label: {
                    Label("Issue verified credential", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    doc.sodFilename == nil
                    || store.sandwich == nil
                    || resolvedIssuerBaseURL == nil
                )
            case .submitting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Submitting to \(submittingHost)…")
                        .font(.callout)
                }
            case .pendingReview(let pendingId, let preVerified, let reason):
                Label(
                    preVerified ? "Submitted, pre-verified" : "Submitted, awaiting manual review",
                    systemImage: preVerified ? "checkmark.seal" : "clock.badge.questionmark"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(preVerified ? .green : .orange)
                if preVerified {
                    Text("The issuer accepted your passport's chip-signed bytes and confirmed they chain to a recognised national CSCA. It's now pending review; an operator will approve it shortly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pre-verification did not complete automatically (\(reason)). An operator will review your packet shortly; you can close this screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Pending ID: \(pendingId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            case .submittedForAnchor(let credentialId):
                Label("Submitted; anchoring in background", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                Text("Your credential has been minted server-side and is being anchored. You can close this screen and continue using the app — the credential will appear on the Identity tab as soon as the issuer's batch flushes. The pending pickup also shows at the top of the Identity tab with a cancel option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Credential: \(credentialId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button {
                    issuanceState = .idle
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if doc.sodFilename == nil {
                Text("Chip-signed material isn't captured. Re-tap the document so Maknoon can store the SOD bytes; the issuer needs them to validate.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Sanctions screening sits immediately below the issue
            // action: it runs against the SAME selected issuer and its
            // result is part of the verification the credential carries.
            sanctionsCheckButton(doc)
            sanctionsResultView(doc)
        } header: {
            Text("Identity Verified Credential")
        }
    }

    /// Sanctions-check action, placed directly below the "Issue
    /// verified credential" button as its secondary counterpart. Runs
    /// against the same selected issuer.
    @ViewBuilder
    private func sanctionsCheckButton(_ doc: IDDocument) -> some View {
        Button {
            Task { await runSanctionsCheck(for: doc) }
        } label: {
            HStack(spacing: 8) {
                if sanctionsState == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "shield.lefthalf.filled")
                }
                Text(doc.sanctionsResult == nil ? "Check against OpenSanctions" : "Re-check sanctions")
                    .fontWeight(.medium)
            }
        }
        .disabled(sanctionsState == .checking || resolvedIssuerBaseURL == nil)

        if case .failed(let msg) = sanctionsState {
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// OpenSanctions screening outcome, rendered below the check
    /// button as a single grouped card. The trailing caption explains
    /// what data leaves the device.
    @ViewBuilder
    private func sanctionsResultView(_ doc: IDDocument) -> some View {
        if let result = doc.sanctionsResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Screening result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    sanctionsPill(result.outcome)
                }
                row("Last screened", value: formattedScreenDate(result.screenedAt))
                row("Dataset", value: result.datasetVersion, monospaced: true)
                if result.outcome != .clean {
                    ForEach(Array(result.matches.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.callout.weight(.medium))
                            Text(m.listName).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if screenIsStale(result.screenedAt) {
                    Label("Last screened more than 30 days ago. Re-check recommended.", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }

        Text("Submits your name and date of birth to the selected issuer for an OpenSanctions check. Your photo and chip data stay on this device.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: -- on-device chip authenticity (ICAO 9303 Passive Auth)

    @ViewBuilder
    private func chipAuthSection(_ doc: IDDocument) -> some View {
        Section {
            HStack {
                Text("Chip authenticity")
                    .font(.callout.weight(.medium))
                Spacer()
                if passiveAuthRunning {
                    ProgressView().controlSize(.small)
                } else if let r = doc.passiveAuthResult {
                    chipAuthPill(r)
                } else {
                    Text("Not checked").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let r = doc.passiveAuthResult, r.status != .verified {
                Text(chipAuthDetail(r))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await runPassiveAuth(for: doc, force: true) }
            } label: {
                Label("Re-check chip", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .disabled(passiveAuthRunning)
        } header: {
            Text("Passport chip")
        }
    }

    @ViewBuilder
    private func chipAuthPill(_ r: PassiveAuthResult) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch r.status {
            case .verified:     return ("Verified", .green, "checkmark.seal.fill")
            case .integrityOnly:
                return r.reason == "dsc_or_chain_expired"
                    ? ("Authentic · signer expired", .orange, "clock.badge.exclamationmark.fill")
                    : ("Genuine · signer not in list", .blue, "checkmark.seal")
            case .failed:       return ("Failed", .red, "xmark.seal.fill")
            case .unavailable:  return ("Unavailable", .secondary, "questionmark.circle")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func chipAuthDetail(_ r: PassiveAuthResult) -> String {
        switch r.status {
        case .verified:      return ""
        case .integrityOnly:
            if r.reason == "dsc_or_chain_expired" {
                return "The chip's data is intact and validly signed, but the signer certificate is past its validity window (expected for an expired passport). This checks chip authenticity, not document validity, so it is not a forgery signal."
            }
            // no_matching_csca: genuine chip, but we don't carry its national signer.
            return "The chip's data is genuine and validly signed, but this passport's national signing certificate (CSCA) isn't in the on-device trust list, which doesn't cover every country. The issuer verifies it on its side. Not a sign of tampering."
        case .failed:
            // Real failure - surface the signer DN for diagnosis.
            let signer = r.dscIssuer.map { "\n\nSigner (DSC) issuer: \($0)" } ?? ""
            return "On-device check failed (\(r.reason)): the chip's data did not match its signed hashes, or the SOD signature did not verify. The issuer makes the authoritative decision." + signer
        case .unavailable:   return "Could not run on-device (\(r.reason))."
        }
    }

    /// Resolve a CSCA-bundle source (first known issuer host), refresh the
    /// trust bundle, run Passive Auth from the stored chip bytes, and persist
    /// the verdict. Soft signal; never blocks issuance.
    private func runPassiveAuth(for doc: IDDocument, force: Bool = false) async {
        if passiveAuthRunning { return }
        if !force, doc.passiveAuthResult != nil { return }
        passiveAuthRunning = true
        defer { passiveAuthRunning = false }

        let cscaSource = store.knownIssuers.hosts
            .compactMap { store.knownIssuers.outboundBaseURL(forEntry: $0) }
            .first
        if let cscaSource {
            await CSCATrustStore.shared.refresh(from: cscaSource, force: force)
        }
        let cafileURL = await CSCATrustStore.shared.cafileURL
        let version = await CSCATrustStore.shared.version

        let sod = store.idDocuments.sodBytes(for: doc)
        var dgs: [String: Data] = [:]
        for g in ["dg1", "dg2", "dg11", "dg12", "dg15"] {
            if let b = store.idDocuments.rawDataGroup(g, for: doc) { dgs[g] = b }
        }
        let result = PassportPassiveAuthVerifier.verify(
            sod: sod,
            dataGroups: dgs,
            issuingAlpha3: doc.issuingAuthority,
            cafileURL: cafileURL,
            bundleVersion: version
        )
        store.idDocuments.setPassiveAuthResult(result, for: doc.id)
    }

    /// Host string shown in the "Submitting to …" line during the
    /// network request. Mirrors the URL the request actually targets
    /// so users with a custom issuer entry see their own host (and
    /// port, when one is set), not a hardcoded production hostname.
    private var submittingHost: String {
        guard let base = resolvedIssuerBaseURL,
              let host = base.host
        else { return "issuer" }
        if let port = base.port { return "\(host):\(port)" }
        return host
    }

    /// The base URL that the issuance POST should target. Returns nil
    /// when the user picked Custom and hasn't typed a parseable URL
    /// yet — that nil disables the submit button so we don't fire
    /// half-formed requests.
    // MARK: -- sanctions screening

    @ViewBuilder
    private func sanctionsPill(_ outcome: SanctionsOutcome) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch outcome {
            case .clean:        return ("Clean", .green, "checkmark.shield.fill")
            case .sanctioned:   return ("Sanctioned", .red, "xmark.shield.fill")
            case .pep:          return ("PEP match", .orange, "exclamationmark.shield.fill")
            case .inconclusive: return ("Inconclusive", .orange, "questionmark.diamond.fill")
            case .error:        return ("Screening error", .secondary, "wifi.exclamationmark")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func screenIsStale(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) > 30 * 24 * 3600
    }

    private func formattedScreenDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(identifier: "UTC")
        return "\(f.string(from: date)) UTC"
    }

    @MainActor
    private func runSanctionsCheck(for doc: IDDocument) async {
        guard let baseURL = resolvedIssuerBaseURL else {
            sanctionsState = .failed("Pick an issuer or enter a custom URL first.")
            return
        }
        sanctionsState = .checking
        // Use the Latin MRZ name so the screened identity matches what
        // the issuer screens at issuance time. DOB is converted from the
        // chip's YYMMDD to ISO 8601. Nationality is omitted: name + DOB
        // is the primary OpenSanctions matching signal, and it sidesteps
        // an alpha-3/alpha-2 mismatch in the holder-run path.
        let familyName = (doc.latinSurname ?? doc.surname)
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let givenName = (doc.latinGivenNames ?? doc.givenNames)
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let dob = Self.yymmddToISO(doc.dateOfBirth)
        do {
            let result = try await SanctionsScreeningClient.check(
                givenName: givenName,
                familyName: familyName,
                dateOfBirth: dob,
                nationality: nil,
                issuerBaseURL: baseURL,
            )
            store.idDocuments.setSanctionsResult(result, for: doc.id)
            sanctionsState = .idle
        } catch {
            sanctionsState = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Convert a chip YYMMDD to ISO 8601 YYYY-MM-DD using the birth
    /// century heuristic (YY <= current 2-digit year → 2000s, else 1900s).
    static func yymmddToISO(_ yymmdd: String) -> String {
        guard yymmdd.count == 6, yymmdd.allSatisfy(\.isNumber) else { return yymmdd }
        let yy = Int(yymmdd.prefix(2)) ?? 0
        let mm = String(yymmdd.dropFirst(2).prefix(2))
        let dd = String(yymmdd.suffix(2))
        let currentYY = Calendar.current.component(.year, from: Date()) % 100
        let century = yy <= currentYY ? 2000 : 1900
        return String(format: "%04d-%@-%@", century + yy, mm, dd)
    }

    private var resolvedIssuerBaseURL: URL? {
        IssuerSelection.resolveBaseURL(
            selectedEntry: selectedIssuerEntry,
            customURL: customIssuerURL,
            knownIssuers: store.knownIssuers
        )
    }

    @MainActor
    private func runIssuance(for doc: IDDocument) async {
        guard let baseURL = resolvedIssuerBaseURL else {
            issuanceState = .failed("Pick an issuer or enter a custom URL.")
            return
        }
        issuanceState = .submitting
        do {
            switch try await IDDocumentIssuance.submit(doc: doc, store: store, baseURL: baseURL) {
            case .submittedForAnchor(let credentialId):
                issuanceState = .submittedForAnchor(credentialId: credentialId)
            case .pendingReview(let pendingId, let preVerified, let reason):
                issuanceState = .pendingReview(
                    pendingId: pendingId,
                    proofPreVerified: preVerified,
                    reason: reason
                )
            }
        } catch {
            issuanceState = .failed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    private func nicknameSection(_ doc: IDDocument) -> some View {
        Section {
            HStack {
                TextField("Nickname (optional)", text: $nicknameDraft)
                    .autocorrectionDisabled()
                Button("Save") {
                    let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.idDocuments.setNickname(trimmed.isEmpty ? nil : trimmed, for: doc.id)
                }
                .disabled(nicknameDraft == (doc.nickname ?? ""))
            }
        } header: {
            Text("Nickname")
        } footer: {
            Text("Use a friendly label like \"Personal passport\" or \"Work ID\".")
                .font(.caption)
        }
    }

    /// Menu picker that lets the user move this scanned passport into
    /// a user-created folder, or back to the "All credentials" root.
    /// Same shape as the equivalent picker on CredentialPresentView so
    /// both kinds of cards share one Identity-tab folder space.
    private func folderSection(_ doc: IDDocument) -> some View {
        let cardId = "passport:\(doc.id.uuidString)"
        let folders = store.credentialFolderStore.folders
        let currentFolderId = store.credentialFolderStore.folderId(forCard: cardId)
        let currentFolderName = folders.first(where: { $0.id == currentFolderId })?.name ?? "None"
        return Section {
            Menu {
                Button {
                    store.credentialFolderStore.assign(cardId: cardId, to: nil)
                } label: {
                    if currentFolderId == nil {
                        Label("None (All credentials)", systemImage: "checkmark")
                    } else {
                        Text("None (All credentials)")
                    }
                }
                ForEach(folders, id: \.id) { folder in
                    Button {
                        store.credentialFolderStore.assign(cardId: cardId, to: folder.id)
                    } label: {
                        if currentFolderId == folder.id {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(currentFolderName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("Folder")
        } footer: {
            Text("Folders live at the root and group cards on the Identity tab.")
                .font(.caption)
        }
    }

    private func deleteSection(_ doc: IDDocument) -> some View {
        Section {
            Button(role: .destructive) {
                // Dismiss BEFORE mutating the store. The view body
                // resolves `doc` by re-querying `store.idDocuments`
                // through the `documentId` UUID; if we remove first
                // the computed `doc` is nil before `dismiss()` runs
                // and the sheet's NavigationStack is left rendering
                // an empty body, with the back / close affordance
                // tied to a phantom view.
                let idToRemove = doc.id
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    store.idDocuments.remove(id: idToRemove)
                }
            } label: {
                Label("Delete document", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("This only removes the document from Maknoon on this phone. Your physical document is unaffected.")
                .font(.caption)
        }
    }

    private func row(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
