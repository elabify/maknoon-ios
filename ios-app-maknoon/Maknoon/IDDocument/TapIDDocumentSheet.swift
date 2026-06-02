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
    /// (nil if the user cancelled before saving); `openIssuance` is true when
    /// the user chose "Get a verified credential from Elabify", so the caller
    /// can open that document's detail (where the issuance + sanctions flow
    /// lives).
    var onFinish: (_ savedDocId: UUID?, _ openIssuance: Bool) -> Void = { _, _ in }

    enum Step: Hashable { case kindPicker, form, scanning, review, minted, error }

    @State private var mintedDocId: UUID?

    @State private var step: Step = .kindPicker
    @State private var parameters = IDDocumentReadParameters(
        kind: .passport,
        documentNumber: "", dateOfBirthYYMMDD: "", dateOfExpiryYYMMDD: ""
    )
    @State private var birthDate: Date = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var expiryDate: Date = Calendar.current.date(byAdding: .year, value: 5, to: Date()) ?? Date()
    @State private var hasSetBirthDate = false
    @State private var hasSetExpiryDate = false
    @State private var lastError: String?
    @State private var readResult: IDDocumentReadResult?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .kindPicker: kindPickerStep
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
            Section {
                Text(formIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField(parameters.kind.documentNumberLabel, text: $parameters.documentNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .font(.system(.body, design: .monospaced))
                DatePicker(
                    "Date of birth",
                    selection: $birthDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .onChange(of: birthDate) { _, new in
                    hasSetBirthDate = true
                    parameters.dateOfBirthYYMMDD = Self.toYYMMDD(new)
                }
                DatePicker(
                    "Date of expiry",
                    selection: $expiryDate,
                    displayedComponents: .date
                )
                .onChange(of: expiryDate) { _, new in
                    hasSetExpiryDate = true
                    parameters.dateOfExpiryYYMMDD = Self.toYYMMDD(new)
                }
            } header: {
                Text("Document details")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parameters.kind.documentNumberHint)
                    if !hasSetBirthDate || !hasSetExpiryDate {
                        Label(
                            "Set both the birth date and expiry date exactly as printed. The chip only unlocks to these three values.",
                            systemImage: "calendar"
                        )
                        .foregroundStyle(.orange)
                    }
                }
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
                Button {
                    step = .kindPicker
                } label: {
                    Text("Change document type")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
            && hasSetBirthDate
            && hasSetExpiryDate
    }

    /// Kind-specific opening sentence shown above the number /
    /// date inputs.
    private var formIntro: String {
        switch parameters.kind {
        case .passport:
            return "Type the details from the inside of your passport, then tap your phone to the photo page when the system NFC sheet appears."
        case .other:
            return "Type the details from the data page of your ID, then tap your phone to it when the system NFC sheet appears."
        }
    }

    private static func toYYMMDD(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd"
        return f.string(from: date)
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
            Text("Hold your phone against the photo page")
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
                    if let pn = result.document.personalNumber, !pn.isEmpty {
                        let label = result.document.userDeclaredKind?.personalNumberLabel ?? "Personal number"
                        detailRow(label, value: pn)
                    }
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
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func save(result: IDDocumentReadResult) {
        let saved = store.idDocuments.add(
            result.document,
            photo: result.photo,
            rawChipData: result.rawChipData
        )
        mintedDocId = saved.id
        // The saved passport is itself the single card on the Identity tab; it
        // can be presented as a self-signed credential on demand from its
        // detail screen (no separate credential card is created). Offer the
        // optional Elabify verified credential as the next step.
        step = .minted
    }

    // MARK: -- step: minted (auto local credential + offer Elabify)

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
            Section {
                Button {
                    onFinish(mintedDocId, true)
                    dismiss()
                } label: {
                    Label("Get a verified credential from Elabify", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } footer: {
                Text("Elabify verifies the document chip on its server and screens you against sanctions lists, then issues an anchored credential. Optional, takes a moment.")
                    .font(.caption)
            }
            Section {
                Button("Done, keep the local credential only") {
                    onFinish(mintedDocId, false)
                    dismiss()
                }
            }
        }
    }

    private var localCredentialIcon: String { "checkmark.seal.fill" }

    private var localCredentialStatus: String {
        "Document saved. It appears as a single card on the Identity tab; open it to present it as a QR (self-signed, offline) or to get an Elabify-verified credential."
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
