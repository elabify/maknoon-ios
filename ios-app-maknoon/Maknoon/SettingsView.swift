// Settings: show the recovery phrase under a Face ID gate, trigger
// the irreversible Lockdown flow, surface encrypted-backup status,
// and offer a wallet reset.
//
// The Show recovery phrase entry disappears once the user enables
// Lockdown. After Lockdown, the only way to see the phrase again is
// to recover from offline paper or from the encrypted backup.
//
// We deliberately do NOT expose a separate "Show passphrase" entry.
// The passphrase is best stored in a password manager and need not
// be browsable in this app; the recovery-phrase reveal sheet
// reminds the user that a passphrase was set up and must be backed
// up separately.

import SwiftUI

struct SettingsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var route: Route?
    @State private var lockdownStep: LockdownStep = .none
    @State private var lockdownTypedWords: String = ""
    @State private var lockdownTypedPassphrase: String = ""
    @State private var errorMessage: String?
    @State private var backupWorking = false
    @State private var backupStatus: String?
    /// Set when `prepareBackupFile` detects a locked sandwich and
    /// triggers HardwareUnlockView. The encryptedBackupSection
    /// watches `store.sandwich` and re-runs the backup as soon as the
    /// unlock succeeds, so the user doesn't have to tap the save
    /// button a second time.
    @State private var pendingBackupRetry = false
    @State private var showResetMaknoonConfirm = false
    @State private var showResetMaknoonDone = false

    /// The route carries the decrypted material as an associated value
    /// for the reveal cases. This makes it structurally impossible to
    /// present an empty (black) sheet — previously a separate
    /// `revealedMaterial` @State could lag the route observer under
    /// iOS 26's stricter sheet recomposition.
    enum Route: Identifiable {
        case showPhrase(MasterRecoveryMaterial)
        case lockdown
        case verifyPhrase

        var id: String {
            switch self {
            case .showPhrase:      return "showPhrase"
            case .lockdown:        return "lockdown"
            case .verifyPhrase:    return "verifyPhrase"
            }
        }
    }

    enum LockdownStep: Equatable {
        case none
        case explain
        case typeWords
        case typePassphrase
        case confirm
    }

    var body: some View {
        NavigationStack {
            Form {
                topLevelSections
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $route) { r in
                switch r {
                case .showPhrase(let material):
                    RevealSheet(
                        material: material,
                        onDismiss: { route = nil }
                    )
                case .lockdown:
                    lockdownSheet
                case .verifyPhrase:
                    verifyPhraseSheet
                }
            }
            .alert("Settings error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: -- new top-level navigation

    @ViewBuilder
    private var topLevelSections: some View {
        Section {
            NavigationLink {
                localKeyDestination
            } label: {
                Label("Local Key", systemImage: "key.fill")
            }
            NavigationLink {
                IdentitySettingsView()
                    .environment(store)
            } label: {
                Label("Identity", systemImage: "person.crop.circle.badge.checkmark")
            }
            NavigationLink {
                DevicesView()
                    .environment(store)
            } label: {
                Label("Devices", systemImage: "key.radiowaves.forward.fill")
            }
            NavigationLink {
                NetworksDestination()
                    .environment(store)
            } label: {
                Label("Networks", systemImage: "network")
            }
            NavigationLink {
                AppStoreSettingsView()
                    .environment(store)
            } label: {
                Label("Apps", systemImage: "square.grid.2x2")
            }
            NavigationLink {
                AddressBookView()
                    .environment(store)
            } label: {
                Label("Address book", systemImage: "person.text.rectangle")
            }
            NavigationLink {
                CurrencySettingsView()
                    .environment(store)
            } label: {
                Label("Currency", systemImage: "dollarsign.circle")
            }
            NavigationLink {
                DisplaySettingsView()
            } label: {
                Label("Display", systemImage: "paintbrush")
            }
            NavigationLink {
                AboutView()
            } label: {
                Label("About", systemImage: "info.circle")
            }
        }

        encryptedBackupSection
        resetMaknoonSection
    }

    @ViewBuilder
    private var resetMaknoonSection: some View {
        Section {
            Button(role: .destructive) {
                showResetMaknoonConfirm = true
            } label: {
                Label("Reset Maknoon", systemImage: "trash.slash")
            }
        } header: {
            Text("Reset Maknoon")
        } footer: {
            Text("Wipes everything on this device: Identity Sandwich, every wallet on every chain, every label, every paired hardware device, the address book, ID documents, Lightning accounts, installed dApps, and every UserDefault setting. Equivalent to deleting and reinstalling the app. The only recovery paths are your 24-word phrase or an encrypted backup file.")
                .font(.caption)
        }
        .confirmationDialog(
            "Reset Maknoon?",
            isPresented: $showResetMaknoonConfirm,
            titleVisibility: .visible
        ) {
            Button("Wipe everything", role: .destructive) {
                Task { await performResetMaknoon() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes every key, wallet, label, device, and credential on this iPhone. You'll need your 24-word phrase or an encrypted backup file to recover. Maknoon will close once the wipe completes; reopen the app to start fresh.")
        }
        .alert(
            "Maknoon has been reset",
            isPresented: $showResetMaknoonDone
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Everything has been wiped. You'll land on the onboarding screen on the next render and can set up a fresh identity from there.")
        }
    }

    // MARK: -- backup status surface
    //
    // The standalone YAML settings backup that used to live here was
    // removed in favour of the single encrypted-backup path. Settings
    // (RPC overrides, known issuers, address book, devices) are now
    // bundled INSIDE the encrypted backup blob, so there's no second
    // file to manage. See `encryptedBackupSection` below.
    //
    // The encrypted backup section now lives at the Settings root
    // (was: inside Local Keys); see `topLevelSections` above. The
    // helpers used to render it live further down.

    @ViewBuilder
    private var localKeyDestination: some View {
        Form {
            if let did = store.sandwich?.holderDID {
                Section("Identity") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Holder DID").font(.caption).foregroundStyle(.secondary)
                        Text(did)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            recoverySection
            if !BackupState.lockdownEnabled {
                lockdownSectionInline
            }
        }
        .navigationTitle("Local Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: -- local-key sub-sections

    @ViewBuilder
    private var recoverySection: some View {
        Section("Recovery") {
            if !BackupState.lockdownEnabled {
                Button {
                    Task { await revealPhrase() }
                } label: {
                    Label("Show recovery phrase", systemImage: "doc.text.viewfinder")
                }
            }
            if !BackupState.isVerified {
                Button {
                    route = .verifyPhrase
                } label: {
                    Label("Verify recovery phrase", systemImage: "checkmark.shield")
                        .foregroundStyle(.orange)
                }
            }
            if BackupState.lockdownEnabled {
                Label("Lockdown enabled. Recovery phrase is no longer viewable on this device.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var lockdownSectionInline: some View {
        Section {
            Button(role: .destructive) {
                lockdownStep = .explain
                route = .lockdown
            } label: {
                Label("Lockdown wallet…", systemImage: "lock.shield")
            }
        } header: {
            Text("Lockdown")
        } footer: {
            Text("Irreversibly removes the option to view your recovery phrase on this device. Useful after you have written it down and stored it safely. The only way to recover after Lockdown is from your offline paper or an encrypted backup.")
        }
    }

    @ViewBuilder
    private var encryptedBackupSection: some View {
        Section {
            if BackupState.hasPassphrase {
                Text("Save an encrypted backup so you can restore on a new device without retyping your 24 words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await prepareBackupFile() }
                } label: {
                    HStack {
                        if backupWorking { ProgressView() }
                        Label("Save encrypted backup…", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(backupWorking)
                if let backupStatus {
                    Text(backupStatus)
                        .font(.caption)
                        .foregroundStyle(backupStatus.hasPrefix("Saved") ? .green : .red)
                }
            } else {
                Text("You did not set a passphrase at onboarding, so we cannot encrypt a backup. The 24 offline words remain your only recovery path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Encrypted backup")
        } footer: {
            Text("The file is AES-256-GCM with a key derived from your passphrase (PBKDF2-SHA256, 600,000 iterations) AND signed with your post-quantum master signature (ML-DSA-65). Without the passphrase the file is useless, to an attacker and to you.")
        }
        // Auto-retry the backup after the user unlocks the sandwich
        // (HardwareUnlockView was triggered from inside
        // prepareBackupFile). Without this, the user would have to
        // tap "Save encrypted backup" a second time after unlocking,
        // which is confusing since they already initiated the
        // backup action.
        .onChange(of: store.sandwich != nil) { _, isUnlocked in
            guard isUnlocked, pendingBackupRetry else { return }
            pendingBackupRetry = false
            backupStatus = nil
            Task { await prepareBackupFile() }
        }
    }

    // MARK: -- reveal

    private func revealPhrase() async {
        guard let sandwich = store.sandwich else { return }
        do {
            let material = try sandwich.recoveryMaterial(
                localizedReason: "Show recovery phrase"
            )
            route = .showPhrase(material)
        } catch {
            errorMessage = "Could not read recovery material: \(error)"
        }
    }

    @MainActor
    private func performResetMaknoon() async {
        store.resetEverything()
        // Show the relaunch instruction. The user can dismiss it
        // and force-quit Maknoon from the App Switcher; the next
        // cold launch sees empty UserDefaults + a fresh first-launch
        // token and routes to OnboardingView with no carry-over.
        showResetMaknoonDone = true
    }

    // MARK: -- encrypted backup

    /// Build the encrypted backup blob and present the document
    /// picker so the user picks the destination. The picker defaults
    /// to iCloud Drive's Maknoon Backups folder when the container is
    /// reachable (entitlement granted + user signed into iCloud); the
    /// user can navigate to any other Files-app destination from
    /// there. When iCloud isn't reachable, the picker opens at the
    /// system's last-used location.
    ///
    /// We present the picker directly through UIKit
    /// (`EncryptedBackup.presentBackupPicker`) rather than via
    /// SwiftUI's `.sheet { UIViewControllerRepresentable }` because
    /// the latter has a presentation conflict with
    /// `UIDocumentPickerViewController` that auto-dismisses the
    /// picker before the user can interact with it.
    @MainActor
    private func prepareBackupFile() async {
        guard let sandwich = store.sandwich else {
            // Sandwich is locked (hardware-wrapped). Route through
            // HardwareUnlockView and queue an auto-retry so the
            // backup runs the moment the user unlocks, instead of
            // forcing them to tap "Save encrypted backup" again.
            // The retry hook lives on the encryptedBackupSection's
            // onChange(of: store.sandwich) observer.
            pendingBackupRetry = true
            backupStatus = "Identity Sandwich is locked. Tap your enrolled device to unlock; the backup will run as soon as you do."
            store.showHardwareUnlock = true
            return
        }
        backupWorking = true
        backupStatus = nil
        do {
            let material = try sandwich.recoveryMaterial(localizedReason: "Encrypt backup")
            let entropy = try BIP39.seedFromMnemonic(material.words)
            let snapshot = SettingsBackup.capture(from: store)
            let lightning = store.lightningAccountStore.exportForEncryptedBackup()
            // v4 sections: capture credentials, ID documents (with
            // chip binaries + photos), and the wallet-state opaque
            // UserDefaults dump. Each is optional; missing sections
            // restore as empty/no-op.
            let credentialsSnapshot = store.captureCredentialsBackup()
            let idDocumentsSnapshot = store.idDocuments.captureBackup()
            let walletStateSnapshot = EncryptedBackup.captureWalletState()
            let blob = try EncryptedBackup.encrypt(
                entropy: entropy,
                passphrase: material.passphrase,
                settings: snapshot,
                lightningAccounts: lightning.isEmpty ? nil : lightning,
                credentials: credentialsSnapshot.credentials.isEmpty && credentialsSnapshot.nicknames.isEmpty ? nil : credentialsSnapshot,
                idDocuments: idDocumentsSnapshot.documents.isEmpty ? nil : idDocumentsSnapshot,
                walletState: walletStateSnapshot
            )
            EncryptedBackup.presentBackupPicker(blob: blob) { url, error in
                backupWorking = false
                if let error {
                    backupStatus = "Save failed: \(error.localizedDescription)"
                } else if let url {
                    backupStatus = "Saved \(url.lastPathComponent)"
                }
                // user-cancelled path: leave previous status visible.
            }
        } catch {
            backupWorking = false
            backupStatus = "Encrypt failed: \(userFacingYubiKeyMessage(for: error))"
        }
    }

    // MARK: -- About
    //
    // About is now a single NavigationLink in `topLevelSections`
    // pointing at AboutView, which renders the Version / Build /
    // Commit rows alongside its other content (third-party credits,
    // diagnostic logs, etc.). No inline section at the Settings root.

    // MARK: -- lockdown sheet

    private var lockdownSheet: some View {
        NavigationStack {
            content
                .navigationTitle("Lockdown")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            lockdownStep = .none
                            lockdownTypedWords = ""
                            lockdownTypedPassphrase = ""
                            route = nil
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch lockdownStep {
        case .none, .explain:
            lockdownExplainView
        case .typeWords:
            lockdownTypeWordsView
        case .typePassphrase:
            lockdownTypePassphraseView
        case .confirm:
            lockdownConfirmView
        }
    }

    private var lockdownExplainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("This cannot be undone", systemImage: "exclamationmark.triangle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)

                Text("Enabling Lockdown removes the ability to view your recovery phrase on this device. After this, the only ways to recover your identity are:")
                    .font(.callout)

                VStack(alignment: .leading, spacing: 8) {
                    bullet("Your offline paper or metal backup of the 24 words")
                    bullet("Your encrypted backup, if you set one up")
                }

                Text("Use Lockdown only after you are absolutely sure your backups are safe and accessible. To prove that, the next step asks you to retype all 24 words and your passphrase.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    lockdownStep = .typeWords
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.horizontal, 16)
        }
    }

    private var lockdownTypeWordsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Type all 24 words")
                    .font(.title3.weight(.semibold))
                Text("Separate words with spaces. They must match the recovery phrase exactly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $lockdownTypedWords)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    Task { await checkWords() }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(lockdownTypedWords.split(whereSeparator: { $0.isWhitespace }).count != 24)

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var lockdownTypePassphraseView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Type your passphrase")
                    .font(.title3.weight(.semibold))
                Text("Must match the passphrase you set during onboarding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField("Passphrase", text: $lockdownTypedPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    Task { await checkPassphrase() }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(lockdownTypedPassphrase.isEmpty)

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var lockdownConfirmView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Final confirmation", systemImage: "lock.shield")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Enabling Lockdown now will permanently remove the Show recovery phrase option from this device. You can still present credentials and use the wallet normally, you just cannot view the recovery phrase on this device anymore.")
                    .font(.callout)
                Button(role: .destructive) {
                    Task { await enableLockdownNow() }
                } label: {
                    Text("Enable Lockdown").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 16)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 6)).padding(.top, 6)
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    @MainActor
    private func checkWords() async {
        guard let sandwich = store.sandwich else { return }
        do {
            let material = try sandwich.recoveryMaterial(localizedReason: "Lockdown — verify phrase")
            let actualWords = material.words.map { $0.lowercased() }
            let typed = lockdownTypedWords
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            guard typed == actualWords else {
                errorMessage = "The typed phrase does not match. Try again."
                return
            }
            errorMessage = nil
            if material.hasPassphrase {
                lockdownStep = .typePassphrase
            } else {
                lockdownStep = .confirm
            }
        } catch {
            errorMessage = "Could not verify phrase: \(error)"
        }
    }

    @MainActor
    private func checkPassphrase() async {
        guard let sandwich = store.sandwich else { return }
        do {
            let material = try sandwich.recoveryMaterial(localizedReason: "Lockdown — verify passphrase")
            if lockdownTypedPassphrase != material.passphrase {
                errorMessage = "Passphrase does not match. Try again."
                return
            }
            errorMessage = nil
            lockdownStep = .confirm
        } catch {
            errorMessage = "Could not verify passphrase: \(error)"
        }
    }

    @MainActor
    private func enableLockdownNow() async {
        do {
            try BackupState.enableLockdown()
            lockdownStep = .none
            lockdownTypedWords = ""
            lockdownTypedPassphrase = ""
            route = nil
        } catch {
            errorMessage = "Could not enable Lockdown: \(error)"
        }
    }

    // MARK: -- verify sheet

    private var verifyPhraseSheet: some View {
        NavigationStack {
            VerifyContent(
                store: store,
                onDone: { route = nil },
                onError: { errorMessage = $0 },
                onReReveal: {
                    // Hop from the verify sheet into the reveal sheet
                    // without making the user re-tap Settings: dismiss
                    // ourselves, then re-trigger Face ID and open the
                    // reveal flow once the sheet animation settles.
                    route = nil
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await revealPhrase()
                    }
                }
            )
            .navigationTitle("Verify recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { route = nil }
                }
            }
        }
    }
}

// MARK: -- RevealSheet

private struct RevealSheet: View {
    let material: MasterRecoveryMaterial
    let onDismiss: () -> Void

    @State private var revealed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    offlineWarning
                    wordGrid(words: material.words, masked: !revealed)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.2)) { revealed.toggle() }
                        }
                    Text(revealed
                        ? "Hide before screen-sharing."
                        : "Tap the grid to reveal.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if material.hasPassphrase {
                        passphraseReminder
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private var offlineWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("OFFLINE only", systemImage: "exclamationmark.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("Write these words on paper or stamped metal. Store OFFLINE. Never type them into a computer, never photograph or screenshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var passphraseReminder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("You also have a passphrase", systemImage: "key.horizontal")
                .font(.callout.weight(.medium))
            Text("During onboarding you set a passphrase. It is NOT shown here. Make sure it is backed up in your password manager (1Password, Bitwarden, iCloud Keychain), kept separate from this 24-word phrase. Without BOTH the phrase and the passphrase, the wallet cannot be recovered.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.purple.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func wordGrid(words: [String], masked: Bool) -> some View {
        let columns = [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading),
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                    Text(masked ? "•••••" : word)
                        .font(.callout.monospaced())
                        .foregroundStyle(masked ? .tertiary : .primary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(masked ? Color(white: 0.15) : Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

// MARK: -- VerifyContent (used by both Settings and the weekly banner)

private struct VerifyContent: View {
    let store: HolderStore
    let onDone: () -> Void
    let onError: (String) -> Void
    let onReReveal: () -> Void

    @State private var words: [String]?

    var body: some View {
        Group {
            if let words {
                VerifyPhraseView(
                    words: words,
                    allowSkip: false,
                    onVerified: {
                        try? BackupState.markVerified()
                        onDone()
                    },
                    onSkipped: { onDone() },
                    onReReveal: onReReveal
                )
                .padding(.horizontal, 16)
            } else {
                ProgressView().task { await load() }
            }
        }
    }

    @MainActor
    private func load() async {
        guard let sandwich = store.sandwich else {
            onError("Wallet not loaded")
            onDone()
            return
        }
        do {
            let material = try sandwich.recoveryMaterial(localizedReason: "Verify recovery phrase")
            words = material.words
        } catch {
            onError("Could not load recovery phrase: \(error)")
            onDone()
        }
    }
}
