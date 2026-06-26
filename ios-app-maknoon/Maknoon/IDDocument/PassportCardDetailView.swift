// The retail passport detail: one navy hero card merging the scanned chip with
// its pinned-network anchors (ADR-0039). Replaces the old IDDocumentDetailView
// as the primary passport screen; the technical table + management actions move
// behind "Advanced options" (the existing IDDocumentDetailView, lightly edited).
//
// Tap a passport badge on the Identity tab → here. One tap on the card's QR icon
// (or the Show QR button) produces the server-assisted verifier QR; Share offers
// the rendered card image; Advanced options pushes the full detail.

import SwiftUI
import UIKit
import LocalAuthentication

struct PassportCardDetailView: View {
    let documentId: UUID
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Advanced opt-in (Settings, Identity) to also show testnet anchor badges.
    /// Off by default: the credential always shows, but testnet anchor chips
    /// (Sepolia, Base Sepolia) are hidden unless the holder turns this on.
    @AppStorage("maknoon.showTestnetAnchors") private var showTestnetAnchors = false

    /// Credential chosen for presentation (issued match when present, else a
    /// freshly minted self-signed one). Drives the Show-QR sheet.
    @State private var presentCredential: Credential?
    @State private var presentError: String?
    @State private var shareImage: ShareableImage?
    @State private var sharing = false
    @State private var passiveAuthRunning = false

    private var doc: IDDocument? { store.idDocuments.documents.first { $0.id == documentId } }

    private var matchedCredential: Credential? {
        guard let doc else { return nil }
        return PassportPairing.matchedCredential(
            for: doc, in: store.credentials, holderDID: store.sandwich?.holderDID
        )
    }

    private var anchors: [AnchorEntry] { matchedCredential?.anchor?.anchors ?? [] }

    /// Anchors shown on the card: production always, testnets only when the
    /// holder opted in via Settings, Identity, Advanced.
    private var shownAnchors: [AnchorEntry] {
        anchors.filter {
            ChainMark.isProduction($0.chain) || (showTestnetAnchors && ChainMark.isTestnet($0.chain))
        }
    }

    var body: some View {
        Group {
            if let doc {
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard(doc)
                        actions(doc)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                .navigationTitle("Passport")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $presentCredential) { cred in
                    NavigationStack {
                        CredentialPresentView(credential: cred, passportMode: true).environment(store)
                    }
                }
                .sheet(item: $shareImage) { wrap in
                    ActivityView(items: [wrap.image] + (wrap.link.map { [$0 as Any] } ?? []))
                }
                // Resolve the chip-authenticity badge on first appear (a safety
                // net in case the post-import run hasn't finished or the app was
                // relaunched); ensurePassiveAuth is a no-op once a result exists.
                .task(id: documentId) {
                    guard doc.passiveAuthResult == nil else { return }
                    passiveAuthRunning = true
                    await store.ensurePassiveAuth(for: doc)
                    passiveAuthRunning = false
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
    }

    // MARK: -- hero card

    @ViewBuilder
    private func heroCard(_ doc: IDDocument, forSharing: Bool = false) -> some View {
        let palette = SchemaPalette.forSchema(passportSchemaURI)
        let fg = palette.foreground
        VStack(alignment: .leading, spacing: 0) {
            // header: icon + Passport + version, QR + Share
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: palette.iconSystemName).font(.title3)
                Text("Passport").font(.title3.weight(.bold))
                Text("v\(doc.displaySchemaVersion)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().stroke(fg.opacity(0.4), lineWidth: 1))
                Spacer()
                Image("MaknoonLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(fg.opacity(0.25), lineWidth: 0.5))
                    .accessibilityLabel("Maknoon")
            }
            .foregroundStyle(fg)

            // issuer + passport number
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(flagEmoji(forAlpha3: doc.issuingAuthority))
                    Text("Issued by \(issuerCode(doc))")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Passport No").font(.system(size: 9, weight: .semibold)).opacity(0.7)
                    Text(doc.documentNumber)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(fg)
            .padding(.top, 10)

            // photo + fields
            HStack(alignment: .top, spacing: 14) {
                photo(doc, fg: fg)
                VStack(alignment: .leading, spacing: 7) {
                    field("Surname", name(doc.latinSurname ?? doc.surname), fg: fg)
                    field("Given names", name(doc.latinGivenNames ?? doc.givenNames), fg: fg)
                    HStack(alignment: .top, spacing: 18) {
                        field("Nationality", issuerCodeFor(doc.nationality), fg: fg)
                        if let sex = doc.sex, !sex.isEmpty { field("Sex", sex.uppercased(), fg: fg) }
                        field("Date of birth", isoDate(doc.dateOfBirth, kind: .birth), fg: fg)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        field("Issued", issueDate(doc) ?? "—", fg: fg)
                        field("Expires", isoDate(doc.dateOfExpiry, kind: .expiry), fg: fg)
                    }
                    if let pob = doc.formattedPlaceOfBirth, !pob.isEmpty {
                        field("Place of birth", pob, fg: fg)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)

            Rectangle().fill(fg.opacity(0.16)).frame(height: 1).padding(.vertical, 9)

            // genuine seal (expiry now lives with the other attributes above)
            HStack(alignment: .center) {
                genuineSeal(doc, fg: fg)
                Spacer()
            }

            // pinned-network strip — on-screen only. The shared picture omits
            // the registry / address / chain marks (ledger detail isn't part of
            // a shareable ID card) and uses a cleaner rectangular shape.
            // Shown when there is an anchor to display: production always, plus
            // testnets when the holder opted in (ADR-0040 / ADR-0043).
            if !forSharing && !shownAnchors.isEmpty {
                pinnedStrip(fg: fg)
                    .padding(.top, 9)
            }
        }
        .padding(15)
        .background(palette.gradient)
        .clipShape(RoundedRectangle(cornerRadius: forSharing ? 12 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: forSharing ? 12 : 22, style: .continuous)
                .stroke(fg.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: forSharing ? .clear : .black.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private func photo(_ doc: IDDocument, fg: Color) -> some View {
        if let img = store.idDocuments.photo(for: doc) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 88, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(fg.opacity(0.3), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(fg.opacity(0.12))
                .frame(width: 88, height: 108)
                .overlay(Text(monogram(doc)).font(.system(size: 30, weight: .bold)).foregroundStyle(fg.opacity(0.8)))
        }
    }

    private func field(_ label: String, _ value: String, fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(label)).font(.system(size: 9, weight: .semibold)).foregroundStyle(fg.opacity(0.7))
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(fg)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func genuineSeal(_ doc: IDDocument, fg: Color) -> some View {
        if passiveAuthRunning && doc.passiveAuthResult == nil {
            // Authenticity check in flight (first import / first open): show a
            // neutral "Checking…" state instead of a premature "Not verified".
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking authenticity…").font(.callout.weight(.semibold)).foregroundStyle(fg)
            }
        } else {
            let g = genuineState(doc)
            HStack(spacing: 7) {
                Image(systemName: g.icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(g.color, in: Circle())
                Text(LocalizedStringKey(g.label)).font(.callout.weight(.semibold)).foregroundStyle(fg)
            }
        }
    }

    @ViewBuilder
    private func pinnedStrip(fg: Color) -> some View {
        // Production anchors always; testnet anchors only when the holder opted
        // in (Settings, Identity, Advanced, "Show testnet anchors").
        let shown = shownAnchors
        let primary = shown.first
        HStack(spacing: 10) {
            if let primary, let url = ChainMark.explorerAddressURL(chain: primary.chain, address: primary.registry) {
                // Visibly a hyperlink (accent colour + underline) so it reads as
                // tappable on the navy card, opening the registry contract on the
                // chain's block explorer.
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.caption2)
                        Text("Musnad Registry").font(.caption.weight(.semibold)).underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(Color(hex: 0x9DC0FF))
            } else {
                Text("Musnad Registry").font(.caption.weight(.semibold)).foregroundStyle(fg)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                ForEach(Array(shown.prefix(3).enumerated()), id: \.offset) { idx, a in
                    ChainMarkChip(mark: ChainMark.forCAIP2(a.chain), pinned: idx == 0, size: 22)
                }
                if shown.count > 3 {
                    Text("+\(shown.count - 3)").font(.caption2.weight(.bold)).foregroundStyle(fg)
                        .frame(width: 22, height: 22).background(fg.opacity(0.14), in: Circle())
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(fg.opacity(0.10), lineWidth: 1))
    }

    // MARK: -- actions

    @ViewBuilder
    private func actions(_ doc: IDDocument) -> some View {
        VStack(spacing: 12) {
            Button { showQR(doc) } label: {
                Label("Share QR", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.sandwich == nil && matchedCredential == nil)

            HStack(spacing: 12) {
                Button { share(doc) } label: {
                    HStack(spacing: 6) {
                        if sharing { ProgressView().controlSize(.small) }
                        Label("Share", systemImage: "square.and.arrow.up")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sharing)
                NavigationLink {
                    IDDocumentDetailView(documentId: documentId).environment(store)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let presentError {
                Text(presentError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func showQR(_ doc: IDDocument) {
        // Gate ENTRY to the Build/Share QR flow with biometric (matches Android).
        // The builder's own actions (Build Online/Offline QR, Copy) don't
        // re-prompt: this single check covers the session.
        Task {
            guard await authorize("Show your passport QR") else { return }
            await MainActor.run {
                presentError = nil
                if let matched = matchedCredential {
                    presentCredential = matched
                    return
                }
                guard let sandwich = store.sandwich else {
                    presentError = "Unlock your identity first."
                    return
                }
                do {
                    presentCredential = try LocalCredentialFactory.mint(from: doc, sandwich: sandwich)
                } catch {
                    presentError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    @MainActor
    private func share(_ doc: IDDocument) { Task { await buildShare(doc) } }

    /// Biometric / device-passcode gate. Returns true when there is no
    /// biometric available (simulator) so the flow still works in dev.
    private func authorize(_ reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Build the shareable picture: the rectangular card (no ledger strip) with
    /// the default all-attributes verifier QR embedded below it, plus the
    /// verifiable link as share text. Falls back to the card image alone if the
    /// presentation / drop can't be built (offline, locked).
    @MainActor
    private func buildShare(_ doc: IDDocument) async {
        guard await authorize("Share your passport") else { return }
        presentError = nil
        sharing = true
        defer { sharing = false }

        let cardRenderer = ImageRenderer(content: heroCard(doc, forSharing: true).frame(width: 360).environment(store))
        cardRenderer.scale = 3
        let cardImage = cardRenderer.uiImage

        // Credential to present: the issued (anchored) one if matched, else mint.
        let cred: Credential?
        if let matched = matchedCredential {
            cred = matched
        } else if let sandwich = store.sandwich {
            cred = try? LocalCredentialFactory.mint(from: doc, sandwich: sandwich)
        } else {
            cred = nil
        }

        var qr: UIImage?
        var expiresAt: Int64?
        if let cred {
            do {
                let allKeys = Set(cred.merkleTree.sortedKeys)
                let presentation = try await PresentationFactory.build(
                    credential: cred, selectedClaims: allKeys,
                    challenge: "0x" + PresentationFactory.selfNonceHex(),
                    verifierDid: "did:elabify:open", pendingRequest: nil, store: store
                )
                let env = try await PresentationDrop.upload(host: HolderStore.elabifyDropHost, presentation: presentation)
                // Encode the same DropEnvelope JSON the on-screen Online QR uses
                // so a verifier's Maknoon app scans it identically.
                qr = BadgeQR.render(try JSONEncoder().encode(env), scale: 8)
                expiresAt = env.expiresAt
            } catch {
                // image-only fallback
            }
        }

        // No web link in the share: the verifiable QR is the artifact a verifier
        // scans with their Maknoon app. (A public web-verify page is pending
        // backend work; until then a URL would 404.)
        let composed = composeShareImage(card: cardImage, qr: qr, expiresAt: expiresAt)
        if let img = composed ?? cardImage {
            shareImage = ShareableImage(image: img, link: nil)
        } else {
            // Surface rather than silently doing nothing (the button felt dead).
            presentError = cred == nil
                ? "Unlock your identity first, then tap Share."
                : "Could not render the share image. Try again."
        }
    }

    /// Stack the card image over the QR on a light card so the shared picture
    /// reads as one ID with a scannable verifier QR. A footer always carries the
    /// download call-to-action; when the drop carries an expiry it also states
    /// how long the QR stays valid plus the exact ISO 8601 / UTC expiry stamp.
    @MainActor
    private func composeShareImage(card: UIImage?, qr: UIImage?, expiresAt: Int64?) -> UIImage? {
        guard let card else { return nil }
        let pad: CGFloat = 24
        let gap: CGFloat = 20

        let footer = footerString(expiresAt: expiresAt)
        let contentWidth = max(card.size.width, qr?.size.width ?? 0)
        let width = contentWidth + pad * 2
        let footerHeight = ceil(footer.boundingRect(
            with: CGSize(width: width - pad * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).height)

        var height = pad + card.size.height
        if let qr { height += gap + qr.size.height }
        height += gap + footerHeight + pad

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            UIColor(white: 0.97, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
            var y = pad
            card.draw(in: CGRect(x: (width - card.size.width) / 2, y: y, width: card.size.width, height: card.size.height))
            y += card.size.height
            if let qr {
                y += gap
                qr.draw(in: CGRect(x: (width - qr.size.width) / 2, y: y, width: qr.size.width, height: qr.size.height))
                y += qr.size.height
            }
            y += gap
            footer.draw(in: CGRect(x: pad, y: y, width: width - pad * 2, height: footerHeight))
        }
    }

    /// Centered footer lines. Always ends with the download call-to-action; when
    /// an expiry is known it leads with a human "valid for next X minutes" line
    /// and the exact machine-readable ISO 8601 expiry timestamp in UTC (`Z`).
    @MainActor
    private func footerString(expiresAt: Int64?) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 2
        let s = NSMutableAttributedString()
        if let expiresAt {
            let mins = max(0, Int(ceil((TimeInterval(expiresAt) - Date().timeIntervalSince1970) / 60)))
            let iso = ISO8601DateFormatter()   // defaults to UTC, "yyyy-MM-dd'T'HH:mm:ss'Z'"
            let stamp = iso.string(from: Date(timeIntervalSince1970: TimeInterval(expiresAt)))
            s.append(NSAttributedString(
                string: "This QR is valid for the next \(mins) minute\(mins == 1 ? "" : "s").\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: UIColor(white: 0.25, alpha: 1),
                    .paragraphStyle: para,
                ]
            ))
            s.append(NSAttributedString(
                string: "Expires \(stamp) (UTC)\n",
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: UIColor(white: 0.45, alpha: 1),
                    .paragraphStyle: para,
                ]
            ))
        }
        s.append(NSAttributedString(
            string: "Download Elabify Maknoon for Apple and Android to verify",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor(white: 0.30, alpha: 1),
                .paragraphStyle: para,
            ]
        ))
        return s
    }

    // MARK: -- formatting helpers

    private func name(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "<", with: " ")
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return cleaned.isEmpty ? "—" : cleaned
    }
    private func issuerCode(_ doc: IDDocument) -> String { issuerCodeFor(doc.issuingAuthority) }
    private func issuerCodeFor(_ alpha3: String) -> String { ISO3166.alpha2(for: alpha3) ?? alpha3.uppercased() }

    private enum DateKind { case birth, expiry }

    /// MRZ YYMMDD → ISO 8601 "YYYY-MM-DD". Birth uses a sliding century window
    /// (yy ≤ current 2-digit year → 2000s, else 1900s); expiry is always 2000s.
    /// Dashes (not slashes) per ISO 8601, and safe to copy into input fields.
    /// Empty / malformed input → "—".
    private func isoDate(_ yymmdd: String, kind: DateKind) -> String {
        guard yymmdd.count == 6, yymmdd.allSatisfy(\.isNumber),
              let yy = Int(yymmdd.prefix(2)) else { return "—" }
        let c = Array(yymmdd)
        let century: Int
        switch kind {
        case .birth:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let currentYY = cal.component(.year, from: Date()) % 100
            century = yy <= currentYY ? 2000 : 1900
        case .expiry:
            century = 2000
        }
        return "\(century + yy)-\(c[2])\(c[3])-\(c[4])\(c[5])"
    }

    /// Date of issue from DG12 tag 0x5F26 (ASCII "YYYYMMDD"), rendered as ISO
    /// 8601 "YYYY-MM-DD". The MRZ never carries an issue date and DG12 is often
    /// absent, so this is nil for many passports (the field then shows "—").
    /// We do NOT substitute the credential's estimated issue date (expiry − 10y)
    /// here: that is an approximation and must not read as a chip-attested fact.
    private func issueDate(_ doc: IDDocument) -> String? {
        guard let dg12 = store.idDocuments.rawDataGroup("dg12", for: doc) else { return nil }
        let b = [UInt8](dg12)
        var i = 0
        while i + 2 < b.count {
            // BER-TLV tag 0x5F26 (date is 8 bytes). Accept short-form length
            // (0x08) and long-form one-byte length (0x81 0x08); some issuers
            // encode it long-form, which a short-form-only scan would miss.
            if b[i] == 0x5F, b[i + 1] == 0x26 {
                var p = i + 2
                var len = Int(b[p])
                if len == 0x81, p + 1 < b.count { p += 1; len = Int(b[p]) }
                let start = p + 1
                if len == 8, start + len <= b.count {
                    let s = String(decoding: b[start..<start + len], as: UTF8.self)
                    if s.count == 8, s.allSatisfy(\.isNumber) {
                        let c = Array(s)
                        return "\(c[0])\(c[1])\(c[2])\(c[3])-\(c[4])\(c[5])-\(c[6])\(c[7])"
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private func truncatedAddress(_ a: String) -> String {
        guard a.count > 12 else { return a }
        return "\(a.prefix(6))…\(a.suffix(4))"
    }

    private func monogram(_ doc: IDDocument) -> String {
        let given = (doc.latinGivenNames ?? doc.givenNames).trimmingCharacters(in: .whitespaces)
        let family = (doc.latinSurname ?? doc.surname).trimmingCharacters(in: .whitespaces)
        let a = given.first.map(String.init) ?? ""
        let b = family.first.map(String.init) ?? ""
        let m = (a + b).uppercased()
        return m.isEmpty ? "ID" : m
    }

    /// alpha-3 → flag emoji via alpha-2 regional indicators. Empty when unknown.
    private func flagEmoji(forAlpha3 alpha3: String) -> String {
        guard let a2 = ISO3166.alpha2(for: alpha3), a2.count == 2 else { return "" }
        let base: UInt32 = 0x1F1E6
        var s = ""
        for u in a2.uppercased().unicodeScalars {
            guard u.value >= 65, u.value <= 90, let scalar = Unicode.Scalar(base + (u.value - 65)) else { return "" }
            s.unicodeScalars.append(scalar)
        }
        return s
    }

    private func genuineState(_ doc: IDDocument) -> (icon: String, color: Color, label: String) {
        if doc.passiveAuthResult?.status == .verified || doc.activeAuthVerifiedLocally == true {
            // Full CSCA-verified chip: the same green "Verified" badge the
            // Advanced options pill shows.
            return ("checkmark", Color(hex: 0x34d399), "Verified")
        }
        switch doc.passiveAuthResult?.status {
        // Chip data is intact + validly signed; the signer just isn't in the
        // on-device CSCA trust list (or is expired). Still a genuine chip, so a
        // confident blue "Genuine" badge, not a cautionary yellow. The nuance
        // lives in Advanced options.
        case .integrityOnly: return ("checkmark", Color(hex: 0x3b82f6), "Genuine")
        case .failed:        return ("xmark", Color(hex: 0xf87171), "Authenticity failed")
        default:             return ("questionmark", Color.gray, "Not verified")
        }
    }
}

/// Identifiable wrapper so a rendered image can drive a `.sheet(item:)`.
private struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let link: String?
}

/// Minimal UIActivityViewController bridge for sharing the rendered card image.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
