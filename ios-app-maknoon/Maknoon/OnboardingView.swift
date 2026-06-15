// First-launch onboarding for the Identity Sandwich.
//
// Flow (per the Maknoon onboarding spec):
//
//   welcome
//      ├─ create new identity ─►  reveal ─►  verify ─►  passphraseEntry ─►  encryptedBackup ─►  done
//      │                            └─ skip-for-now ───────────►  passphraseEntry (no verify)
//      └─ restore ─►  RecoveryView (separate)
//
// Notes:
//   - Reveal happens BEFORE passphrase. The entropy is generated up
//     front (no Keychain write yet); the sandwich is only persisted
//     once the user has set a passphrase.
//   - Verify has no Skip: the choice to skip lives on the reveal
//     screen. Verify only has Back (which returns to reveal).
//   - Passphrase is MANDATORY. There is no "skip passphrase" branch.
//     The combined entry + confirmation screen also doubles as a
//     last-call reminder to save it to a password manager.
//   - Encrypted backup screen is vendor-neutral; on free Apple ID
//     teams the upload step fails at runtime with a clear message
//     because CloudKit needs the paid Developer Program.

import SwiftUI

struct OnboardingView: View {
    @Environment(HolderStore.self) private var store

    enum Phase: Equatable {
        case welcome
        /// Restore from a written-down 24-word recovery phrase. Lands
        /// on RecoveryView's picker so the user can also pivot to the
        /// encrypted-file path from there if they change their mind.
        case restore
        /// Restore from an encrypted backup file. Lands directly on
        /// RecoveryView's file-import path, skipping the picker.
        case restoreEncryptedBackup
        case reveal
        case verify
        case passphraseEntry
        case encryptedBackup
        case provisioning
        /// Post-identity steps (sandwich already adopted): optionally scan a
        /// passport to mint a credential, then recommend a first wallet.
        case passportScan
        case recommendWallet
    }

    @State private var phase: Phase = .welcome
    @State private var revealed = false
    @State private var confirmedOffline = false
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var confirmedSavedToPasswordManager = false
    @State private var pendingEntropy: Data?
    @State private var pendingWords: [String] = []
    @State private var pendingSandwich: IdentitySandwich?
    @State private var errorMessage: String?
    @State private var backupWorking = false
    @State private var showBackupExporter = false
    @State private var pendingBackupDocument: MaknoonBackupDocument?
    @State private var showOnboardingPassport = false
    @State private var showHardwarePicker = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
    }

    private var navigationTitle: String {
        switch phase {
        case .welcome:                  return "Welcome"
        case .restore:                  return "Restore"
        case .restoreEncryptedBackup:   return "Restore backup"
        case .reveal:                   return "Recovery phrase"
        case .verify:                   return "Verify phrase"
        case .passphraseEntry:          return "Set passphrase"
        case .encryptedBackup:          return "Encrypted backup"
        case .provisioning:             return "Setting up"
        case .passportScan:             return "Scan passport"
        case .recommendWallet:          return "First wallet"
        }
    }

    // MARK: -- phase routing

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .welcome:                welcomeView
        case .restore:                RecoveryView(onCancel: { phase = .welcome })
        case .restoreEncryptedBackup: RecoveryView(onCancel: { phase = .welcome }, initialMode: .file)
        case .reveal:                 revealView
        case .verify:                 verifyView
        case .passphraseEntry:        passphraseEntryView
        case .encryptedBackup:        encryptedBackupView
        case .provisioning:           provisioningView
        case .passportScan:           passportScanView
        case .recommendWallet:        recommendWalletView
        }
    }

    // MARK: -- welcome

    private var welcomeView: some View {
        // GeometryReader + minHeight keeps the Spacers centring the content
        // when there's room (portrait), but lets it scroll instead of
        // clipping when the viewport is short (landscape).
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        Image("MaknoonLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.30), radius: 12, y: 6)
                        Text("Maknoon").font(.title.bold())
                        VStack(spacing: 4) {
                            Text("Own your Identity, Assets, and Privacy")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        bullet("Scan a passport into your phone with post-quantum encryption")
                        bullet("Manage digital assets with a secure hardware wallet")
                        bullet("Privately use your identity and assets with those you verify and trust")
                    }
                    .padding(.horizontal, 8)
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        Button(action: { startNewIdentity() }) {
                            Text("Create new").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: { phase = .restoreEncryptedBackup }) {
                            Text("Restore encrypted backup").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                }
                .frame(minHeight: geo.size.height)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.purple)
                .font(.callout)
            Text(text).font(.callout).foregroundStyle(.primary)
        }
    }

    // MARK: -- reveal

    private var revealView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Store this OFFLINE", systemImage: "exclamationmark.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("The only safe place for these 24 words without encryption is paper or stamped metal, stored OFFLINE, in a locked safe. Never type them into any computer or phone. Never take a photo or screenshot. Anyone with this recovery phrase AND your passphrase can recreate your identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                wordGrid(words: pendingWords, masked: !revealed)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { revealed.toggle() }
                    }

                if !revealed {
                    Text("Tap the grid to reveal. Tap again to hide before walking away or screen-sharing.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Hide before screen-sharing or putting the phone down.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 4)

                Toggle(isOn: $confirmedOffline) {
                    Text("I have written this on paper or metal and stored it OFFLINE. I understand losing it means losing access.")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .tint(.purple)

                Button(action: { phase = .verify }) {
                    Text("Continue to verification").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmedOffline)

                Button(action: { skipRecoveryStorage() }) {
                    Text("Skip for now — remind me in 7 days").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
        }
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

    // MARK: -- verify

    private var verifyView: some View {
        VerifyPhraseView(
            words: pendingWords,
            allowSkip: false,
            onVerified: {
                try? BackupState.markVerified()
                phase = .passphraseEntry
            },
            onSkipped: {
                // Skip is not allowed from verify, but VerifyPhraseView
                // still calls this on its (hidden) Skip path.
                phase = .passphraseEntry
            },
            onReReveal: { phase = .reveal }
        )
    }

    // MARK: -- passphrase

    private var passphraseEntryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set a passphrase")
                    .font(.title3.weight(.semibold))

                Text("A passphrase is used to backup your identity and any local assets using post-quantum encryption.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Passphrase").font(.caption).foregroundStyle(.secondary)
                    SecureField("", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Confirm passphrase").font(.caption).foregroundStyle(.secondary)
                    SecureField("", text: $passphraseConfirm)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if !passphrase.isEmpty,
                   passphraseConfirm.isEmpty == false,
                   passphrase != passphraseConfirm {
                    Text("Passphrases do not match")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Save it to a password manager NOW", systemImage: "key.horizontal")
                        .font(.callout.weight(.medium))
                    Text("This is the last time the passphrase will be shown. Add it to a vetted password manager before you continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Toggle(isOn: $confirmedSavedToPasswordManager) {
                    Text("I have saved this passphrase").font(.callout)
                }
                .toggleStyle(.switch)
                .tint(.purple)

                Button(action: { Task { await buildSandwich() } }) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    passphrase.isEmpty
                    || passphrase != passphraseConfirm
                    || !confirmedSavedToPasswordManager
                )

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: -- encrypted backup

    private var encryptedBackupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Encrypted backup", systemImage: "lock.doc")
                    .font(.title3.weight(.semibold))

                Text("Maknoon will store an encrypted backup in any location you prefer using your passphrase. Without the passphrase, the post-quantum encrypted backup is useless and nobody can unlock it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }

                Button(action: { Task { await prepareBackupFile() } }) {
                    HStack {
                        if backupWorking { ProgressView().tint(.white) }
                        Text(backupWorking ? "Preparing…" : "Save encrypted backup…").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(backupWorking)
            }
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: pendingBackupDocument,
            contentType: .json,
            defaultFilename: EncryptedBackup.defaultFilename()
        ) { result in
            pendingBackupDocument = nil
            switch result {
            case .success:
                beginPostIdentitySteps()
            case .failure(let err):
                errorMessage = "Save was canceled: \(err.localizedDescription)"
            }
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 6)).padding(.top, 6)
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    @MainActor
    private func prepareBackupFile() async {
        errorMessage = nil
        backupWorking = true
        defer { backupWorking = false }
        do {
            let entropy = try BIP39.seedFromMnemonic(pendingWords)
            // Bundle the current settings so a restore brings RPC
            // overrides + known issuers + registered devices back
            // alongside the master entropy.
            let snapshot = SettingsBackup.capture(from: store)
            let lightning = store.lightningAccountStore.exportForEncryptedBackup()
            let blob = try EncryptedBackup.encrypt(
                entropy: entropy,
                passphrase: passphrase,
                settings: snapshot,
                lightningAccounts: lightning.isEmpty ? nil : lightning
            )
            pendingBackupDocument = MaknoonBackupDocument(blob: blob)
            showBackupExporter = true
        } catch {
            errorMessage = "Encrypted backup failed: \(error.localizedDescription)"
        }
    }

    // MARK: -- provisioning + done

    private var provisioningView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("Provisioning your Secure Enclave…")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).padding(.top, 18)
            }
            Spacer()
        }
    }

    // MARK: -- actions

    /// Create-a-new-identity entry. Generates 32 bytes of entropy
    /// (no Keychain write yet), derives the 24-word mnemonic, and
    /// advances straight to the passphrase screen. The seed phrase is
    /// no longer shown or verified during onboarding (it stays
    /// viewable later in Settings, Local Key); the mandatory encrypted
    /// backup is the primary recovery path. The actual sandwich (and
    /// its Keychain writes) is built once the user has set a passphrase.
    private func startNewIdentity() {
        errorMessage = nil
        do {
            var entropyBytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, 32, &entropyBytes)
            guard status == errSecSuccess else {
                throw NSError(domain: "Maknoon", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Could not generate entropy"])
            }
            pendingEntropy = Data(entropyBytes)
            pendingWords = BIP39.mnemonicFromSeed(Data(entropyBytes))
            phase = .passphraseEntry
        } catch {
            errorMessage = "Could not generate a new identity: \(error.localizedDescription)"
        }
    }

    /// "Skip — remind me in 7 days" on the reveal screen. Per the
    /// spec we assume the user has NOT actually stored the phrase
    /// and mark the verification state accordingly. The 7-day
    /// reminder banner picks this up.
    private func skipRecoveryStorage() {
        try? BackupState.markReminded()
        // confirmedOffline stays false so future passes through this
        // screen still show the toggle. Proceed to the passphrase
        // step because the passphrase is mandatory and independent
        // of whether the user wrote down the phrase.
        phase = .passphraseEntry
    }

    /// Build the sandwich now that entropy + passphrase are both set,
    /// and advance to the encrypted-backup step.
    @MainActor
    private func buildSandwich() async {
        guard let entropy = pendingEntropy else {
            errorMessage = "Internal error: no pending entropy"
            phase = .welcome
            return
        }
        phase = .provisioning
        errorMessage = nil
        do {
            let sandwich = try IdentitySandwich.restoreFromEntropy(entropy, passphrase: passphrase)
            pendingSandwich = sandwich
            phase = .encryptedBackup
        } catch {
            errorMessage = "Could not provision identity: \(error.localizedDescription)"
            phase = .passphraseEntry
        }
    }

    // MARK: -- post-identity: passport scan

    private var passportScanView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Scan your passport", systemImage: "person.text.rectangle")
                    .font(.title3.weight(.semibold))
                Text("Tap your passport and Maknoon reads its chip on-device and mints an identity credential signed by your post-quantum key, that you can present from your phone. Nothing is uploaded unless you then choose an Elabify-verified credential.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: { showOnboardingPassport = true }) {
                    Label("Scan passport", systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { phase = .recommendWallet }) {
                    Text("Skip for now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 6) {
                    bulletRow("The credential is signed by your key and verifiable by another Maknoon user offline, with no server.")
                    bulletRow("You can also submit it to an issuer for a sanctions-checked, authority-issued credential, right after the scan or later from the Identity tab.")
                }
            }
        }
        .sheet(isPresented: $showOnboardingPassport) {
            TapIDDocumentSheet(onFinish: { _ in
                showOnboardingPassport = false
                phase = .recommendWallet
            }).environment(store)
        }
    }

    // MARK: -- post-identity: first wallet (Bitcoin-first)

    private var recommendWalletView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Create your first wallet", systemImage: "creditcard")
                    .font(.title3.weight(.semibold))
                Text("Maknoon supports many networks, and even anchors temporary verified credentials on some of them. For holding value, though, we only recommend Bitcoin: it is the only cryptocurrency proven as a long-term store of value. The safest option is a hardware wallet; a software Bitcoin wallet is convenient for small amounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: { showHardwarePicker = true }) {
                    Label("Add a hardware wallet", systemImage: "externaldrive.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    store.bitcoinWalletStore.seedDefaultIfNeeded()
                    completeOnboarding()
                }) {
                    Label("Create Bitcoin software wallet", systemImage: "bitcoinsign.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: { completeOnboarding() }) {
                    Text("Skip for now").frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("For meaningful amounts, use a hardware wallet", systemImage: "snowflake")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.blue)
                    Text("A software wallet is convenient for small amounts. A separate hardware wallet keeps your keys offline for larger holdings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .sheet(isPresented: $showHardwarePicker) {
            NavigationStack {
                AddHardwareDeviceFlow(
                    kinds: DeviceKind.walletCapableRegistrableCases,
                    autoDiscoverBitcoin: true,
                    onFinished: { registered in
                        showHardwarePicker = false
                        if registered { completeOnboarding() }
                    }
                )
                .environment(store)
                .navigationTitle("Add a hardware wallet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { showHardwarePicker = false }
                    }
                }
            }
        }
    }

    /// Adopt the freshly-built sandwich and move into the post-identity steps
    /// (passport scan, first wallet). The launch router stays on
    /// OnboardingView because `isCompletingOnboarding` is set, so these steps
    /// run with a live `store.sandwich`.
    private func beginPostIdentitySteps() {
        guard let s = pendingSandwich else {
            errorMessage = "Internal error: no pending sandwich"
            phase = .welcome
            return
        }
        store.isCompletingOnboarding = true
        store.adopt(s)
        phase = .passportScan
    }

    /// Finish onboarding: clear the post-identity flag (so the launch router
    /// swaps to the main app) and wipe transient onboarding state.
    private func completeOnboarding() {
        store.isCompletingOnboarding = false
        pendingSandwich = nil
        pendingEntropy = nil
        pendingWords = []
        passphrase = ""
        passphraseConfirm = ""
        confirmedOffline = false
        confirmedSavedToPasswordManager = false
    }
}
