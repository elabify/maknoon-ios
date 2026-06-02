// Identity tab — primary home for verified credentials.
//
// Layout, top to bottom:
//   1. Compact identity header (collapsed by default, tap to expand).
//      Shows holder DID, delegation, hardware-wallet status.
//   2. Backup reminder banner (if the user skipped phrase verification).
//   3. Folder pill strip: "All" + each user folder + "+ New folder".
//      Tapping a folder pill filters the stack to its members; long-
//      pressing a folder pill offers Rename / Delete.
//   4. List of credential cards. Tap any card → CredentialPresentView,
//      which defaults to a no-PII badge QR.
//   5. Toolbar: gear icon (Settings) on the left, "+" menu on the right
//      with "Receive credential" (and future "Scan QR").

import SwiftUI

struct IdentityView: View {
    @Environment(HolderStore.self) private var store
    @State private var showSettings = false
    @State private var showReceive = false
    @State private var showVerify = false
    @State private var showScanVerifier = false
    @State private var showVerifyOther = false
    @State private var showTapIDDocument = false
    @State private var selectedIDDocumentId: SelectedDocumentId?
    /// Set when the post-scan sheet asks to continue to Elabify issuance;
    /// consumed on the scan sheet's dismissal to open the document detail.
    @State private var pendingIssuanceDocId: UUID?

    /// `nil` = "All" pseudo-folder. When set, the stack filters to
    /// the cards assigned to this folder via `credentialFolderStore`.
    @State private var activeFolderId: UUID?

    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var renameFolderTarget: CredentialFolder?
    @State private var renameDraftName = ""
    @State private var pendingDeleteFolder: CredentialFolder?

    private struct SelectedDocumentId: Identifiable, Hashable {
        let id: UUID
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if store.isIdentityLocked {
                    lockedBanner
                }

                if BackupState.shouldShowReminder() {
                    BackupReminderBanner(onTap: { showVerify = true })
                }

                // Pending pickups: credentials minted by the issuer
                // that haven't anchored yet. The PendingPickupsStore
                // polls in the background; each row shows progress
                // and a cancel button.
                if !store.pendingPickups.pending.isEmpty {
                    pendingPickupsSection
                }

                // Unified card stack: verified credentials AND
                // scanned passports render with the same Apple-Wallet
                // shape, sorted alphabetically by type, nickname,
                // issuer. The empty state shows only when there are
                // no cards of either kind.
                if walletCards.isEmpty {
                    emptyState
                } else {
                    folderStrip
                    if displayedCards.isEmpty {
                        folderEmptyState
                    } else {
                        credentialStack
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .navigationTitle("Identity")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showReceive = true
                    } label: {
                        Label("Receive credential", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showScanVerifier = true
                    } label: {
                        Label("Scan verifier", systemImage: "checkmark.shield")
                    }
                    Button {
                        showVerifyOther = true
                    } label: {
                        Label("Verify someone", systemImage: "person.fill.viewfinder")
                    }
                    #if MAKNOON_NFC
                    Button {
                        showTapIDDocument = true
                    } label: {
                        Label("Tap ID document", systemImage: "wave.3.right.circle")
                    }
                    #endif
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .navigationDestination(for: String.self) { credId in
            CredentialNavigationDestination(credId: credId)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(store)
        }
        .sheet(isPresented: $showReceive) {
            ReceiveSheet().environment(store)
        }
        .sheet(isPresented: $showVerify) {
            VerifyFromBannerSheet(store: store, onClose: { showVerify = false })
        }
        .sheet(isPresented: $showScanVerifier) {
            ScanVerifierSheet(store: store, onClose: { showScanVerifier = false })
                .environment(store)
        }
        .sheet(isPresented: $showVerifyOther) {
            VerifyOtherSheet(onClose: { showVerifyOther = false })
        }
        #if MAKNOON_NFC
        .sheet(isPresented: $showTapIDDocument, onDismiss: {
            // After the scan sheet closes, if the user asked to get a verified
            // credential from Elabify, open that document's detail (where the
            // issuance + sanctions flow lives).
            if let id = pendingIssuanceDocId {
                pendingIssuanceDocId = nil
                selectedIDDocumentId = SelectedDocumentId(id: id)
            }
        }) {
            TapIDDocumentSheet(onFinish: { savedDocId, openIssuance in
                pendingIssuanceDocId = (openIssuance ? savedDocId : nil)
                showTapIDDocument = false
            }).environment(store)
        }
        .sheet(item: $selectedIDDocumentId) { wrapper in
            NavigationStack {
                IDDocumentDetailView(documentId: wrapper.id).environment(store)
            }
        }
        #endif
        .sheet(isPresented: $showNewFolderSheet) {
            FolderNameSheet(title: "New folder", initial: "") { name in
                let folder = store.credentialFolderStore.add(name: name)
                activeFolderId = folder.id
            }
        }
        .sheet(item: $renameFolderTarget) { folder in
            FolderNameSheet(title: "Rename folder", initial: folder.name) { newName in
                store.credentialFolderStore.rename(id: folder.id, to: newName)
            }
        }
        .confirmationDialog(
            confirmDeleteFolderTitle,
            isPresented: confirmDeleteFolderBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteFolder
        ) { folder in
            Button("Delete folder", role: .destructive) {
                if activeFolderId == folder.id { activeFolderId = nil }
                store.credentialFolderStore.remove(id: folder.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            let count = store.credentialFolderStore.count(in: folder.id)
            Text("\(count) credential\(count == 1 ? "" : "s") will move back to All. The credentials themselves are not deleted.")
        }
        .onAppear {
            if BackupState.shouldShowReminder() {
                try? BackupState.markReminded()
            }
        }
    }

    /// List of in-flight credential pickups — the issuer minted the
    /// credential server-side and the holder's background poller is
    /// waiting for it to anchor. One row per pending entry, with a
    /// schema-keyed icon, the credentialId (short), a relative
    /// timestamp, a spinner / error glyph, and a destructive cancel
    /// button. Tapping cancel only removes the row locally; the
    /// minted credential is untouched on the issuer side.
    private var pendingPickupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pending pickups")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(store.pendingPickups.pending) { entry in
                pendingPickupRow(entry)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func pendingPickupRow(_ entry: PendingPickup) -> some View {
        let palette = entry.schemaURI.map { SchemaPalette.forSchema($0) }
            ?? SchemaPalette.forSchema("")
        let error = store.pendingPickups.lastError[entry.id]
        HStack(spacing: 12) {
            Image(systemName: palette.iconSystemName)
                .font(.callout)
                .foregroundStyle(palette.foreground)
                .frame(width: 28, height: 28)
                .background(palette.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.humanLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Anchoring…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.credentialId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(role: .destructive) {
                store.pendingPickups.cancel(id: entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel pending pickup")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: -- folder strip

    /// Horizontal pill strip pinned above the credential stack. "All"
    /// is always present; each user-created folder follows; a trailing
    /// "+ New" pill creates one. Long-press any folder pill for
    /// Rename / Delete via the system context menu. Folder pills are
    /// draggable horizontally to reorder.
    private var folderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderPill(
                    label: "All",
                    count: walletCards.count,
                    isSelected: activeFolderId == nil
                ) {
                    activeFolderId = nil
                }
                ForEach(store.credentialFolderStore.folders, id: \.id) { folder in
                    folderPill(
                        label: folder.name,
                        count: cardCount(in: folder.id),
                        isSelected: activeFolderId == folder.id
                    ) {
                        activeFolderId = folder.id
                    }
                    .draggable(folder.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let droppedId = UUID(uuidString: raw),
                              droppedId != folder.id,
                              let from = store.credentialFolderStore.folders.firstIndex(where: { $0.id == droppedId }),
                              let to = store.credentialFolderStore.folders.firstIndex(where: { $0.id == folder.id })
                        else { return false }
                        store.credentialFolderStore.move(from: from, to: to)
                        return true
                    }
                    .contextMenu {
                        Button {
                            renameDraftName = folder.name
                            renameFolderTarget = folder
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDeleteFolder = folder
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button {
                    newFolderName = ""
                    showNewFolderSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule()
                                .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                        )
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 4)
    }

    private func folderPill(
        label: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isSelected
                                ? Color.white.opacity(0.18)
                                : Color(uiColor: .tertiarySystemBackground)
                        )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color.purple
                        : Color(uiColor: .secondarySystemBackground)
                )
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// Member count for a folder, restricted to cards that are still
    /// present in the live wallet so deleted credentials don't inflate
    /// the badge.
    private func cardCount(in folderId: UUID) -> Int {
        let ids = store.credentialFolderStore.cardIds(in: folderId)
        return walletCards.filter { ids.contains($0.id) }.count
    }

    // MARK: -- credential stack

    /// Verified credentials + scanned passports rendered in the same
    /// Apple-Wallet-style stack, sorted alphabetically by type, then
    /// nickname, then issuer. Each card peeks the top
    /// `CredentialCard.peekHeight` (~90 pt) of the next; the last
    /// card is fully revealed. Tap routes through different
    /// destination mechanisms (NavigationLink for credentials, sheet
    /// for passports) so the existing detail views don't have to
    /// change.
    private var credentialStack: some View {
        let overlap = CredentialCard.height - CredentialCard.peekHeight
        return VStack(spacing: -overlap) {
            ForEach(displayedCards) { card in
                walletCardLink(card)
            }
        }
    }

    /// Unified, sorted list of all cards (verified credentials +
    /// scanned passports). Sort: type → nickname → issuer, all
    /// case-insensitive.
    private var walletCards: [WalletCardData] {
        // Known-issuer hosts to probe for each credential's signed well-known
        // doc (verified-issuer-name resolution). iOS stores no per-credential
        // issuer URL, so the resolver matches the doc DID across these hosts.
        let candidateBaseURLs = store.knownIssuers.hosts.compactMap {
            store.knownIssuers.outboundBaseURL(forEntry: $0)
        }
        // A self-signed passport credential (issuer == holder, passport
        // schema) is represented by its passport card (which can Present it on
        // demand), so it must not also render its own duplicate card. Elabify-
        // issued passport VCs have a different issuer DID and stay visible.
        let holderDID = store.sandwich?.holderDID
        let credentialCards = store.credentials
            .filter { cred in
                !(cred.header.schema == passportSchemaURI && cred.header.iss == holderDID)
            }
            .map { cred in
                WalletCardData.forCredential(
                    cred,
                    nickname: store.nickname(for: cred.id),
                    candidateBaseURLs: candidateBaseURLs
                )
            }
        let passportCards = store.idDocuments.documents.map { doc in
            WalletCardData.forPassport(doc, photo: store.idDocuments.photo(for: doc))
        }
        return (credentialCards + passportCards).sorted { lhs, rhs in
            if lhs.sortKey.0 != rhs.sortKey.0 { return lhs.sortKey.0 < rhs.sortKey.0 }
            if lhs.sortKey.1 != rhs.sortKey.1 { return lhs.sortKey.1 < rhs.sortKey.1 }
            return lhs.sortKey.2 < rhs.sortKey.2
        }
    }

    /// Cards filtered by the active folder pill. `nil` = all cards.
    private var displayedCards: [WalletCardData] {
        let all = walletCards
        guard let activeFolderId else { return all }
        let ids = store.credentialFolderStore.cardIds(in: activeFolderId)
        return all.filter { ids.contains($0.id) }
    }

    /// Tap target per card. Credentials use the existing String-based
    /// `.navigationDestination`; passports use the existing
    /// `selectedIDDocumentId` sheet. Long-press surfaces "Move to
    /// folder" and (for passports) the destructive delete.
    @ViewBuilder
    private func walletCardLink(_ card: WalletCardData) -> some View {
        switch card.kind {
        case .credential(let credId):
            NavigationLink(value: credId) {
                CredentialCard(data: card)
            }
            .buttonStyle(.plain)
            .contextMenu {
                cardContextMenu(card)
                Divider()
                Button(role: .destructive) {
                    store.credentialFolderStore.assign(cardId: card.id, to: nil)
                    store.removeCredential(id: credId)
                } label: {
                    Label("Delete credential", systemImage: "trash")
                }
            }
        case .passport(let uuid):
            Button {
                selectedIDDocumentId = SelectedDocumentId(id: uuid)
            } label: {
                CredentialCard(data: card)
            }
            .buttonStyle(.plain)
            .contextMenu {
                cardContextMenu(card)
                Divider()
                Button(role: .destructive) {
                    store.idDocuments.remove(id: uuid)
                } label: {
                    Label("Delete document", systemImage: "trash")
                }
            }
        }
    }

    /// "Move to folder" submenu listed at the top of every card's
    /// long-press menu so users can re-file a card without opening
    /// the detail view first.
    @ViewBuilder
    private func cardContextMenu(_ card: WalletCardData) -> some View {
        let currentFolderId = store.credentialFolderStore.folderId(forCard: card.id)
        Menu("Move to folder") {
            Button {
                store.credentialFolderStore.assign(cardId: card.id, to: nil)
            } label: {
                if currentFolderId == nil {
                    Label("None (All credentials)", systemImage: "checkmark")
                } else {
                    Text("None (All credentials)")
                }
            }
            ForEach(store.credentialFolderStore.folders, id: \.id) { folder in
                Button {
                    store.credentialFolderStore.assign(cardId: card.id, to: folder.id)
                } label: {
                    if currentFolderId == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        }
    }

    // MARK: -- folder name sheet plumbing

    private var confirmDeleteFolderTitle: String {
        guard let pendingDeleteFolder else { return "Delete folder" }
        return "Delete \"\(pendingDeleteFolder.name)\"?"
    }

    private var confirmDeleteFolderBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteFolder != nil },
            set: { if !$0 { pendingDeleteFolder = nil } }
        )
    }

    // MARK: -- banners + empty states

    /// Shown when the sandwich is wrapped by a hardware device and
    /// the user hasn't unlocked it this session. Tapping opens the
    /// hardware-unlock sheet.
    private var lockedBanner: some View {
        Button {
            store.showHardwareUnlock = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(Color.indigo)
                Text("Identity is locked")
                    .font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.indigo.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No credentials yet").font(.title3).bold()
            Text("Use the + menu in the top right to receive your first credential from an issuer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 64)
    }

    /// Shown when a folder is selected but no cards live in it.
    /// Offers a one-tap path back to the "All" pill.
    private var folderEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing in this folder yet")
                .font(.callout.weight(.semibold))
            Text("Long-press a card and pick \"Move to folder\" to add it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                activeFolderId = nil
            } label: {
                Text("Show all credentials")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Small sheet for folder create + rename. Pulled out so the
/// keyboard binding doesn't drag the rest of IdentityView's render
/// down on each keystroke.
private struct FolderNameSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("Folders live at the root and cannot contain other folders.")
                        .font(.caption)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = initial
                focused = true
            }
        }
        .presentationDetents([.height(220)])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

/// Resolves the pushed credentialId against the store on every render
/// and falls back to an auto-dismiss when no match is found. The
/// Remove flow uses dismiss-first-mutate-later, but if any other code
/// path (background sync, programmatic removal, …) drops the
/// credential while this view is on screen, this proxy pops the
/// destination cleanly instead of leaving an empty body underneath a
/// stuck navigation bar.
private struct CredentialNavigationDestination: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let credId: String

    var body: some View {
        if let cred = store.credentials.first(where: { $0.id == credId }) {
            CredentialPresentView(credential: cred)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
