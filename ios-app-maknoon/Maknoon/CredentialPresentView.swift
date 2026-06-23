// Per-credential present screen.
//
// Two modes via a segmented control at the top:
//
//   1. Badge QR (default): renders a `BadgePayload` as a QR. No PII,
//      no holder pubkey, no claims. Static, anyone with the QR could
//      replay it, but since the payload reveals nothing private, replay
//      is harmless. A verifier scanning the QR sees issuer + schema +
//      cid + anchor reference and can confirm the credential exists by
//      checking the on-chain anchor.
//
//   2. Share attributes: the existing claim-by-claim disclosure flow.
//      Selects which claims to reveal, POSTs an authenticated
//      presentation to the live verifier, renders the verdict + check
//      matrix. Uses `PresentAttributesView`, which has access to the
//      pre-selected credential (no picker).
//
// Underneath both modes there is a collapsible "Technical details"
// section mirroring the old CredentialDetailView.

import SwiftUI

/// Identifiable share request driven by `.sheet(item:)` from this screen's
/// Form (a stable anchor) instead of from inside `PresentAttributesView`'s
/// Form-nested rows, where a sheet was torn down on Form recompute and
/// dismissed itself. One item with a `kind` so a single `.sheet` covers
/// both share variants, two sibling `.sheet` modifiers on one view
/// conflict in SwiftUI.
private struct ShareItem: Identifiable {
    enum Kind { case qr, drop }
    let id = UUID()
    let kind: Kind
    let presentation: Presentation
}

struct CredentialPresentView: View {
    let credential: Credential
    /// If non-nil, the Share Attributes section opens in Respond mode with
    /// the required claims pre-selected. Used by `ScanVerifierSheet` when
    /// the user picks a matching credential.
    var pendingRequest: VerifierRequest?
    /// Optional injection so callers can skip the .environment(store) dance
    /// in deep navigation pushes. Not used today; kept for API symmetry.
    var nicknameInjection: String? = nil
    /// Initial segmented-control mode. Defaults to Badge QR for normal
    /// taps; `ScanVerifierSheet` opens in Share Attributes / Respond.
    var initialMode: Mode = .badge
    /// Passport flow (ADR-0039): hides the Privacy-QR mode entirely and always
    /// uses the attribute (server-assisted) QR, defaulting to all attributes
    /// and allowing redaction down to zero.
    var passportMode: Bool = false

    enum Mode: Hashable {
        case badge
        case attributes
    }

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .badge
    @State private var renameOpen = false
    @State private var nicknameDraft = ""
    @State private var activeShare: ShareItem?

    init(
        credential: Credential,
        initialMode: Mode = .badge,
        passportMode: Bool = false,
        pendingRequest: VerifierRequest? = nil,
        nicknameInjection: String? = nil
    ) {
        self.credential = credential
        self.initialMode = initialMode
        self.passportMode = passportMode
        self.pendingRequest = pendingRequest
        self.nicknameInjection = nicknameInjection
        self._mode = State(initialValue: passportMode ? .attributes : initialMode)
    }

    var body: some View {
        Form {
            // Passport Show-QR is lean (ADR-0039): just the attribute QR builder.
            // Nickname, mode picker, technical details, folder, and remove live
            // in Advanced options, not here.
            if !passportMode { nicknameSection }

            if !passportMode {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Privacy QR").tag(Mode.badge)
                        Text(pendingRequest == nil ? "Attribute QR" : "Respond").tag(Mode.attributes)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if mode == .badge && !passportMode {
                BadgeMode(credential: credential)
            } else {
                PresentAttributesView(
                    credential: credential,
                    pendingRequest: pendingRequest,
                    compact: passportMode,
                    onPresentQR: { activeShare = ShareItem(kind: .qr, presentation: $0) },
                    onPresentDrop: { activeShare = ShareItem(kind: .drop, presentation: $0) }
                )
            }

            if !passportMode {
                Section {
                    DisclosureGroup("Technical details") {
                        TechnicalDetails(credential: credential)
                    }
                    .font(.callout)
                }

                folderSection
            }

            if !passportMode {
            Section {
                Button(role: .destructive) {
                    // Pop the Identity tab's navigation path
                    // EXPLICITLY via the store's binding rather than
                    // via `@Environment(\.dismiss)`. The dismiss
                    // action has shown itself to be unreliable in
                    // this exact context on iOS 26 (Form button →
                    // `dismiss()` + state mutation on the same
                    // tick): the navigation chrome ends up wedged,
                    // back button unresponsive, view never popped.
                    // Manipulating the path directly is deterministic.
                    let idToRemove = credential.id
                    if !store.identityNavigationPath.isEmpty {
                        store.identityNavigationPath.removeLast()
                    }
                    // Schedule the actual store mutation slightly
                    // after the pop animation so the destination
                    // view's body doesn't re-evaluate against a
                    // missing credential while still on screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [store] in
                        store.removeCredential(id: idToRemove)
                    }
                } label: {
                    Label("Remove Verified Credential", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            }
        }
        .navigationTitle(SchemaPalette.forSchema(credential.header.schema).humanLabel)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename credential", isPresented: $renameOpen) {
            TextField("Nickname", text: $nicknameDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            Button("Save") {
                store.setNickname(nicknameDraft, for: credential.id)
            }
            Button("Clear", role: .destructive) {
                store.setNickname(nil, for: credential.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this credential a memorable name. Local-only; not part of the signed payload.")
        }
        // Anchored to the Form (the pushed screen's root), not to the
        // Share-attributes rows, so a Form recompute can't tear it down.
        // One sheet, switched on kind: two sibling .sheet modifiers conflict.
        .sheet(item: $activeShare) { share in
            // In passport mode, closing the QR returns all the way to the
            // passport (dismiss this builder too), not back to the builder.
            switch share.kind {
            case .qr:
                LocalShareQrSheet(presentation: share.presentation, onClose: { activeShare = nil; if passportMode { dismiss() } })
            case .drop:
                DropQrSheet(presentation: share.presentation, onClose: { activeShare = nil; if passportMode { dismiss() } })
            }
        }
    }

    // MARK: -- nickname header

    /// Menu picker for moving the credential into a user-created
    /// folder (or back to the "All credentials" root). Writes through
    /// to `credentialFolderStore`; the Identity tab observes the
    /// change and re-filters on next render.
    private var folderSection: some View {
        let cardId = "cred:\(credential.id)"
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

    private var nicknameSection: some View {
        let nickname = store.nickname(for: credential.id)
        return Section {
            Button(action: {
                nicknameDraft = nickname ?? ""
                renameOpen = true
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nickname?.isEmpty == false ? nickname! : "Set a nickname")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(nickname?.isEmpty == false ? .primary : .secondary)
                        Text("Local only. Not part of the signed credential.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Nickname")
        }
    }
}

// MARK: -- Badge mode

private struct BadgeMode: View {
    let credential: Credential
    @Environment(HolderStore.self) private var store
    @State private var verifiedIssuer: String?

    var body: some View {
        let payload = BadgeQR.payload(for: credential)
        let qr = BadgeQR.image(for: credential)
        // All anchors (ADR-0030 multi-network); fall back to the legacy single
        // `anchor` field for back-compat.
        let anchors: [BadgeAnchor] = payload.anchors ?? payload.anchor.map { [$0] } ?? []

        Section {
            if let qr {
                Image(uiImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Text("Could not render QR for this credential.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Scan to verify")
        } footer: {
            Text("Static QR. Anyone with this code can confirm the credential exists and is anchored on chain, but cannot read your personal information from it.")
                .font(.caption)
        }

        Section("What this shares") {
            kv("Issuer",     verifiedIssuer ?? shortIssuerName(payload.iss))
            kv("Type",       SchemaPalette.forSchema(payload.schema).humanLabel)
            kv("Issued",     formatDate(payload.iat))
            if let exp = payload.exp {
                kv("Expires", formatDate(exp))
            }
            // One row per chain the batch root is anchored on (multi-network).
            ForEach(Array(anchors.enumerated()), id: \.offset) { _, a in
                kv("Anchor · \(caip2Label(a.chain))", short(a.batchTxHash))
            }
        }
        .task(id: credential.id) {
            let bases = store.knownIssuers.hosts.compactMap {
                store.knownIssuers.outboundBaseURL(forEntry: $0)
            }
            if let v = await IssuerIdentityResolver.shared.resolve(
                credential: credential, candidateBaseURLs: bases
            ) {
                verifiedIssuer = v.humanLabel
            }
        }

        Section {
            Label("PII stays on this device", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Text("None of the personal information on this credential, such as your name or date of birth, is encoded in the QR. To share specific attributes with a verifier, switch to \"Share attributes\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.callout.weight(.medium)).multilineTextAlignment(.trailing)
        }
    }

    /// Credential timestamps are normalized to UTC (the issuer caps a
    /// passport credential's exp at end-of-day UTC on the printed
    /// expiry date, and JWT-style iat/exp are Unix seconds, i.e. UTC
    /// instants). Render the date in UTC so the day a verifier sees
    /// matches the day the issuer stamped, regardless of the holder's
    /// local timezone. "UTC" suffix avoids ambiguity for users near a
    /// day boundary.
    private func formatDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        fmt.timeZone = TimeZone(identifier: "UTC")
        return "\(fmt.string(from: date)) UTC"
    }

    private func short(_ hex: String) -> String {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if s.count <= 14 { return "0x\(s)" }
        return "0x\(s.prefix(8))…\(s.suffix(6))"
    }
}

// MARK: -- Technical details

private struct TechnicalDetails: View {
    let credential: Credential

    var body: some View {
        Group {
            section("Header") {
                kv("iss",    credential.header.iss)
                kv("sub",    credential.header.sub)
                kv("schema", credential.header.schema)
                kv("cid",    credential.header.cid)
                kv("root",   credential.header.root)
                // ISO 8601 with `Z` suffix is the standard wire format
                // for credential timestamps (W3C VC, JWT, OpenID, CWT).
                // The raw Unix seconds remain on the same row for
                // operators who need the canonical numeric value.
                kv("iat",    "\(credential.header.iat)  (\(Self.iso8601UTC(credential.header.iat)))")
                if let exp = credential.header.exp {
                    kv("exp", "\(exp)  (\(Self.iso8601UTC(exp)))")
                }
            }
            Divider()
            section("Cryptography") {
                kv("headerSig", credential.headerSig)
                let sigHex = credential.headerSig.hasPrefix("0x") ? String(credential.headerSig.dropFirst(2)) : credential.headerSig
                kv("sigBytes",  String(sigHex.count / 2))
                let anchors = credential.anchor?.anchors ?? []
                ForEach(Array(anchors.enumerated()), id: \.offset) { idx, a in
                    let n = anchors.count > 1 ? " #\(idx + 1)" : ""
                    kv("anchor\(n) chain",    "\(caip2Label(a.chain)) (\(a.chain))")
                    kv("anchor\(n) registry", a.registry)
                    kv("anchor\(n) tx",       a.batchTxHash)
                    kv("anchor\(n) batch root", a.batchRoot)
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(.vertical, 4)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(k)).font(.caption2).foregroundStyle(.tertiary)
            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// Render a Unix-seconds instant as ISO 8601 / RFC 3339 in UTC,
    /// e.g. `2024-03-07T23:59:59Z`. Cached formatter, same one used
    /// across all credentials in this view.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime] // YYYY-MM-DDTHH:MM:SSZ
        return f
    }()
    private static func iso8601UTC(_ unix: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
