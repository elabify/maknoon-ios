// Restore an identity from its 24-word BIP39 recovery phrase OR from
// an encrypted iCloud backup blob.
//
// Two routes:
//   1. Type/paste the 24 BIP39 words, plus an optional passphrase.
//      Useful when restoring from offline paper or metal.
//   2. Download the encrypted blob from iCloud and decrypt it with the
//      passphrase. Faster on a new phone, assuming the user signed in
//      to iCloud and previously enabled iCloud backup.

import SwiftUI

struct RecoveryView: View {
    @Environment(HolderStore.self) private var store
    @Environment(DisplayPreferences.self) private var displayPrefs
    let onCancel: () -> Void
    /// Mode the view should land in on first appearance. Defaults to
    /// `.picker` (the user chooses between paper-phrase and encrypted
    /// file). Onboarding's welcome screen passes `.file` to deep-link
    /// straight into encrypted-backup restore, skipping the picker.
    let initialMode: Mode

    enum Mode: Equatable {
        case picker
        case wordsManual
        case file
    }

    init(onCancel: @escaping () -> Void, initialMode: Mode = .picker) {
        self.onCancel = onCancel
        self.initialMode = initialMode
        self._mode = State(initialValue: initialMode)
    }

    @State private var mode: Mode
    @State private var input: String = ""
    @State private var passphrase: String = ""
    @State private var errorMessage: String?
    @State private var working: Bool = false
    @State private var showBackupImporter: Bool = false
    /// Best-effort import report from the file restore path,
    /// wrapped in a stable Identifiable so `.sheet(item:)` doesn't
    /// see a fresh id each render.
    @State fileprivate var restoreDone: RestoreDone?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch mode {
                case .picker:       pickerView
                case .wordsManual:  wordsManualView
                case .file:         fileView
                }
            }
            .padding(.horizontal, 4)
        }
        // Confirmation BEFORE continuing: shows what was restored and anything
        // that could not be imported. Adopting the sandwich (which swaps to the
        // main app) is deferred to the Continue button so a partial restore is
        // never silently dropped. Mirrors the Android RESTORE_DONE step.
        .sheet(item: $restoreDone) { done in
            RestoreCompleteSheet(summary: done.summary) {
                let s = done.sandwich
                restoreDone = nil
                store.adopt(s)
                Task { await store.reissueCredentialsAfterRestore() }
            }
            .interactiveDismissDisabled(true)
        }
    }

    fileprivate struct RestoreSummary {
        let restored: [String]
        let warnings: [String]
        var hadWarnings: Bool { !warnings.isEmpty }
    }

    fileprivate struct RestoreDone: Identifiable {
        let id = UUID()
        let summary: RestoreSummary
        let sandwich: IdentitySandwich
    }

    // MARK: -- picker

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose how to restore your identity.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: { mode = .wordsManual }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Type the 24 recovery words")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("From your offline paper or metal backup. Add your passphrase too if you set one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: { mode = .file }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restore from backup file")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Pick the encrypted backup file you saved earlier (anywhere in iCloud Drive, On My iPhone, or another Files-app location). You will need the passphrase.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: -- words manual

    private var wordsManualView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Type or paste your 24-word recovery phrase. Separate words with spaces.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $input)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 160)
                .padding(8)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !words.isEmpty {
                HStack(spacing: 6) {
                    Text("\(words.count) of 24 words")
                        .font(.caption)
                        .foregroundStyle(words.count == 24 ? .primary : .secondary)
                    if let firstInvalid = firstInvalidWord() {
                        Text("• \"\(firstInvalid)\" is not in the BIP39 list")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Passphrase (leave blank if you didn't set one)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Button(action: { Task { await restoreFromWords() } }) {
                HStack {
                    if working { ProgressView().tint(.white) }
                    Text(working ? "Restoring…" : "Restore identity")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || words.count != 24 || firstInvalidWord() != nil)

            Button(action: { mode = .picker }) {
                Text("Back").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(working)

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: -- file restore

    private var fileView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Restore from backup file", systemImage: "doc.badge.arrow.up")
                .font(.title3.weight(.semibold))

            Text("Enter the passphrase you used when you encrypted this backup, then pick the file. Decryption and verification happen entirely on this phone.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Passphrase").font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Button(action: { showBackupImporter = true }) {
                HStack {
                    if working { ProgressView().tint(.white) }
                    Text(working ? "Restoring…" : "Pick backup file and decrypt")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || passphrase.isEmpty)

            Button(action: { mode = .picker }) {
                Text("Back").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(working)

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Restoring from a seed phrase alone rebuilds your identity key, but it does NOT restore your verified credentials, settings, or local wallet data. Any verified credentials will be abandoned and must be manually reissued by their issuers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: { mode = .wordsManual }) {
                        Text("Restore from a 24-word seed phrase only")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            .tint(.secondary)
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            Task { await restoreFromFile(result) }
        }
    }

    // MARK: -- derivations

    private var words: [String] {
        return input
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
    }

    private func firstInvalidWord() -> String? {
        for w in words where !BIP39.isValidWord(w) {
            return w
        }
        return nil
    }

    // MARK: -- actions

    @MainActor
    private func restoreFromWords() async {
        errorMessage = nil
        working = true
        defer { working = false }
        do {
            _ = try BIP39.seedFromMnemonic(words)   // validate checksum
            let sandwich = try IdentitySandwich.restoreFromMnemonic(
                words: words,
                passphrase: passphrase
            )
            store.adopt(sandwich)
            // Launch router picks up the new sandwich and swaps to
            // ContentView on the next render.
        } catch BIP39Error.badChecksum {
            errorMessage = "The phrase is well-formed but the checksum does not match. Double-check the spelling."
        } catch BIP39Error.unknownWord(let w) {
            errorMessage = "\"\(w)\" is not in the BIP39 wordlist."
        } catch BIP39Error.wrongWordCount(let n) {
            errorMessage = "Expected 24 words, found \(n)."
        } catch {
            errorMessage = "Restore failed: \(error)"
        }
    }

    @MainActor
    private func restoreFromFile(_ pick: Result<[URL], Error>) async {
        errorMessage = nil
        working = true
        defer { working = false }
        let url: URL
        switch pick {
        case .success(let urls):
            guard let first = urls.first else {
                errorMessage = "No file picked."
                return
            }
            url = first
        case .failure(let err):
            errorMessage = "File pick failed: \(err.localizedDescription)"
            return
        }
        // Files coming back from UIDocumentPickerViewController live
        // outside the app sandbox. We have to scope the access
        // explicitly or Data(contentsOf:) will return "you don't have
        // permission" on iCloud Drive and Files-app providers.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let blob = try Data(contentsOf: url)
            let backup = try EncryptedBackup.decryptFull(blob, passphrase: passphrase)
            let sandwich = try IdentitySandwich.restoreFromEntropy(backup.entropy, passphrase: passphrase)

            // 1) Write all device-protected UserDefaults state first.
            //    applyWalletState wipes its covered keys then writes the
            //    backup's bytes; running it before the structured
            //    SettingsBackup below lets that snapshot win for the
            //    per-chain settings keys the two mechanisms share.
            if backup.walletState != nil {
                EncryptedBackup.applyWalletState(backup.walletState)
            }

            // 2) Apply the snapshots that mutate live stores, collecting a
            //    summary of what came back + anything that couldn't be imported.
            //    The labels match the export manifest exactly so the two can be
            //    compared 1:1 (per-chain wallet counts included).
            func walletCount(_ key: String) -> Int {
                guard let b64 = backup.walletState?[key], let data = Data(base64Encoded: b64),
                      let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return 0 }
                return arr.count
            }
            var restored: [String] = ["Identity & recovery phrase"]
            var warnings: [String] = []
            for (label, key) in [("Bitcoin", "networks.bitcoin.wallets.v1"), ("Ethereum", "networks.ethereum.wallets.v2"), ("Solana", "networks.solana.wallets.v2"), ("Tron", "networks.tron.wallets.v2")] {
                let n = walletCount(key); if n > 0 { restored.append("\(label) wallets (\(n))") }
            }
            if backup.walletState != nil { restored.append("Networks, RPC/explorer overrides, tokens, currency & display") }
            if let settings = backup.settings {
                let report = settings.apply(to: store)
                warnings.append(contentsOf: report.skipped)
                if let note = report.versionNote { warnings.append(note) }
                if !settings.knownIssuers.isEmpty { restored.append("Trusted issuers (\(settings.knownIssuers.count))") }
                if let devs = settings.devices, !devs.isEmpty { restored.append("Hardware devices (\(devs.count))") }
                if let ab = settings.addressBook, !ab.isEmpty { restored.append("Address book (\(ab.count))") }
            }
            if let lightning = backup.lightningAccounts, !lightning.isEmpty {
                try? store.lightningAccountStore.importFromEncryptedBackup(lightning)
                restored.append("Lightning accounts (\(lightning.count))")
            }
            if let creds = backup.credentials {
                store.applyCredentialsBackup(creds)
                restored.append("Credentials (\(creds.credentials.count))")
            }
            if let docs = backup.idDocuments {
                store.idDocuments.applyBackup(docs)
                restored.append("ID documents / passports (\(docs.documents.count))")
            }

            // 3) Refresh the in-memory stores (wallet lists, settings,
            //    tokens, custom networks, fiat + display prefs) from the
            //    UserDefaults we just wrote, so the live UI reflects the
            //    restore without an app relaunch.
            store.reloadAfterRestore()
            displayPrefs.reload()

            // 4) Show the confirmation. Adopting the sandwich (which swaps to
            //    the main app) happens on Continue, so the user sees what was
            //    restored (and any warnings) before leaving this screen.
            restoreDone = RestoreDone(
                summary: RestoreSummary(restored: restored, warnings: warnings),
                sandwich: sandwich
            )
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}

// Restore confirmation: lists what was restored (and anything that couldn't be
// imported) with a Continue button that adopts the identity and enters the app.
private struct RestoreCompleteSheet: View {
    let summary: RecoveryView.RestoreSummary
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: summary.hadWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(summary.hadWarnings ? .orange : .green)
                        Text(summary.hadWarnings ? "Restore completed with warnings" : "Restore complete")
                            .font(.title3.weight(.semibold))
                    }
                    Text(summary.hadWarnings
                        ? "Your wallet was restored, but some items could not be imported. Review them below before continuing."
                        : "Everything in your backup was restored to this phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if !summary.restored.isEmpty {
                        Text("Restored").font(.subheadline.weight(.semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.restored, id: \.self) { item in
                                Label(item, systemImage: "checkmark").font(.callout)
                            }
                        }
                    }

                    if summary.hadWarnings {
                        Text("Not imported").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.warnings, id: \.self) { w in
                                Text("• \(w)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(action: onContinue) {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
