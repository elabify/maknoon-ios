// Apple-Wallet-shaped credential card.
//
// Renders either a verified Credential or a scanned ID document
// (passport) from the chip. The two used to ship as visually
// different cards; they're unified here so the Identity tab can
// stack and sort them together as one wallet surface.
//
// Layout: icon (SF symbol OR photo thumbnail) top-left, type label +
// nickname + issuer/identifier on a single stacked column that fits
// inside the top ~90 pt of the card. The top-right corner carries
// the expiry status dot and (if a sanctions screen has been run for
// this card) the sanctions shield — both visible at every stack
// position because they sit in the peek region. The bottom strip
// (visible only when this card is fully revealed at the bottom of
// the stack) carries issuance + expiry dates.

import SwiftUI

struct CredentialCard: View {
    let data: WalletCardData

    /// Verified issuer name, resolved async by binding the issuer's signed
    /// well-known doc to this credential. nil until resolved / on failure, in
    /// which case the DID-heuristic `data.issuerShort` is shown.
    @State private var verifiedIssuerName: String?

    /// Total card height. The Identity tab stacks cards with overlap so
    /// each card peeks the top `peekHeight` while the one fully visible
    /// shows the full height.
    static let height: CGFloat = 168

    /// Top portion always visible when stacked.
    static let peekHeight: CGFloat = 90

    var body: some View {
        let palette = data.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                cardIcon(palette: palette)
                    .frame(width: 36, height: 36, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(data.typeLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                    Text(data.nickname?.isEmpty == false ? data.nickname! : "Tap to rename")
                        .font(.subheadline)
                        .foregroundStyle(palette.foreground.opacity(data.nickname?.isEmpty == false ? 0.85 : 0.55))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verifiedIssuerName ?? data.issuerShort)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.foreground.opacity(0.85))
                        Text("·")
                            .foregroundStyle(palette.foreground.opacity(0.5))
                        Text(data.identifier)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(palette.foreground.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let badge = data.sanctionsBadge {
                        sanctionsBadgeView(badge)
                    }
                    statusDot(palette: palette)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text("Issued \(issuedAtText)")
                    .font(.caption2)
                    .foregroundStyle(palette.foreground.opacity(0.7))
                if let expText = expiryText {
                    Text("·")
                        .foregroundStyle(palette.foreground.opacity(0.4))
                    Text(expText)
                        .font(.caption2)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                }
                if let net = data.networkLabel {
                    Text("·")
                        .foregroundStyle(palette.foreground.opacity(0.4))
                    Text(net)
                        .font(.caption2)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .background(palette.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.foreground.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .task(id: data.id) {
            guard let cred = data.verifyCredential, !data.candidateBaseURLs.isEmpty else { return }
            if let v = await IssuerIdentityResolver.shared.resolve(
                credential: cred, candidateBaseURLs: data.candidateBaseURLs
            ) {
                verifiedIssuerName = v.humanLabel
            }
        }
    }

    // MARK: -- helpers

    @ViewBuilder
    private func cardIcon(palette: SchemaPalette) -> some View {
        if let photo = data.photo {
            // Photo-as-icon for passports. Clip to a rounded square so
            // it visually echoes the card's outer corner radius.
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(palette.foreground.opacity(0.4), lineWidth: 0.5)
                )
        } else {
            Image(systemName: palette.iconSystemName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(palette.foreground)
        }
    }

    private func statusDot(palette: SchemaPalette) -> some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.5), lineWidth: 0.5)
            )
    }

    /// Shield chip at the card's bottom-right reflecting the
    /// OpenSanctions screen outcome. No chip is rendered for the
    /// `.error` outcome (a transient screening failure isn't a
    /// statement about the holder) or when un-screened (badge nil).
    @ViewBuilder
    private func sanctionsBadgeView(_ outcome: SanctionsOutcome) -> some View {
        let spec: (icon: String, tint: Color)? = {
            switch outcome {
            case .clean:        return ("checkmark.shield.fill", .green)
            case .pep:          return ("exclamationmark.shield.fill", .yellow)
            case .inconclusive: return ("questionmark.diamond.fill", .yellow)
            case .sanctioned:   return ("xmark.shield.fill", .red)
            case .error:        return nil
            }
        }()
        if let spec {
            Image(systemName: spec.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(spec.tint)
                .padding(4)
                .background(.black.opacity(0.22))
                .clipShape(Circle())
        }
    }

    private var statusColor: Color {
        // Expiry traffic light: green when expiry is more than 30
        // days away (or absent), yellow within 30 days, red after.
        // Applies uniformly to verified credentials and scanned
        // passport cards — both expose a real expiry the user cares
        // about.
        let now = Date()
        guard let exp = data.expiresAt else { return .green }
        if exp <= now { return .red }
        if exp.timeIntervalSince(now) < 30 * 24 * 3600 { return .yellow }
        return .green
    }

    private var issuedAtText: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: data.issuedAt)
    }

    private var expiryText: String? {
        guard let exp = data.expiresAt else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "Expires \(f.string(from: exp))"
    }
}

// MARK: -- View-model shared between verified credentials and passports

/// Display + sort fields for one wallet card. Built once per render
/// pass from either a `Credential` or an `IDDocument`; CredentialCard
/// reads it without caring which source it came from.
struct WalletCardData: Identifiable {
    /// Stable id namespaced by source kind so a Credential id and an
    /// IDDocument UUID can't collide in a ForEach.
    let id: String
    let kind: Kind
    let typeLabel: String
    let nickname: String?
    let issuerShort: String
    let identifier: String
    let issuedAt: Date
    let expiresAt: Date?
    let palette: SchemaPalette
    let photo: UIImage?
    /// OpenSanctions screening outcome for a scanned passport, when the
    /// user has run a check. nil for credentials and un-screened
    /// passports; drives the shield chip at the card's bottom-right.
    var sanctionsBadge: SanctionsOutcome? = nil

    /// Friendly name(s) of the network(s) this credential is anchored on
    /// (e.g. "Sepolia"). nil for passports / un-anchored credentials.
    var networkLabel: String? = nil

    /// Inputs for the verified-issuer-name resolution (credential cards only).
    /// `verifyCredential` carries the held credential whose headerSig binds the
    /// issuer's well-known doc; `candidateBaseURLs` are the known-issuer hosts to
    /// probe for that doc. nil/empty for passports -> card keeps the heuristic.
    var verifyCredential: Credential? = nil
    var candidateBaseURLs: [URL] = []

    /// Tag carrying just enough to route the tap to the right detail
    /// view. Credentials route through the existing String-based
    /// NavigationDestination; passports route to IDDocumentDetailView
    /// through a sheet.
    enum Kind: Hashable {
        case credential(id: String)
        case passport(uuid: UUID)
    }

    /// Sort tuple. Identity tab sorts cards alphabetically by type,
    /// then nickname, then issuer (case-insensitive on each).
    var sortKey: (String, String, String) {
        (
            typeLabel.lowercased(),
            (nickname ?? "").lowercased(),
            issuerShort.lowercased(),
        )
    }
}

extension WalletCardData {
    static func forCredential(
        _ cred: Credential,
        nickname: String?,
        candidateBaseURLs: [URL] = []
    ) -> WalletCardData {
        let palette = SchemaPalette.forSchema(cred.header.schema)
        let cidShort = "\(cred.header.cid.prefix(6))…\(cred.header.cid.suffix(4))"
        let chains = cred.anchor?.anchors.map(\.chain) ?? []
        return WalletCardData(
            id: "cred:\(cred.id)",
            kind: .credential(id: cred.id),
            typeLabel: palette.humanLabel,
            nickname: nickname,
            issuerShort: shortIssuerName(cred.header.iss),
            identifier: cidShort,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(cred.header.iat)),
            expiresAt: cred.header.exp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            palette: palette,
            photo: nil,
            sanctionsBadge: sanctionsOutcome(from: cred.claims["sdnScreen"]),
            networkLabel: chains.isEmpty ? nil : caip2LabelList(chains),
            verifyCredential: cred,
            candidateBaseURLs: candidateBaseURLs
        )
    }

    /// Extract a sanctions outcome from a credential's `sdnScreen`
    /// claim, if present. The issuer emits the claim with a `result`
    /// string field whose values match `SanctionsOutcome` raw values
    /// (see the issuer backend); we
    /// just decode and return. Absent claim, malformed shape, or
    /// unknown result string -> nil (no badge).
    private static func sanctionsOutcome(from claim: JSONValue?) -> SanctionsOutcome? {
        guard let claim,
              case let .object(fields) = claim,
              case let .string(result) = fields["result"] ?? .null
        else { return nil }
        return SanctionsOutcome(rawValue: result)
    }

    static func forPassport(_ doc: IDDocument, photo: UIImage?) -> WalletCardData {
        // Reuse the passport palette (navy gradient, white foreground)
        // but override the human label so passports read "Passport
        // (NFC)" in the wallet, distinguishing them from issuer-signed
        // passport credentials.
        let basePalette = SchemaPalette.forSchema("elabify://schema/global/passport/v1")
        let palette = SchemaPalette(
            gradient: basePalette.gradient,
            foreground: basePalette.foreground,
            humanLabel: "Passport (NFC)",
            iconSystemName: basePalette.iconSystemName,
        )
        // Default nickname = Latin full name when the user hasn't set
        // one. Composed from the MRZ-derived fields with the
        // library-reported form as fallback (handles legacy saved
        // docs that pre-date the MRZ parser).
        let given = (doc.latinGivenNames ?? doc.givenNames).trimmingCharacters(in: .whitespaces)
        let family = (doc.latinSurname ?? doc.surname).trimmingCharacters(in: .whitespaces)
        let latinFull = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        let nickname = (doc.nickname?.isEmpty == false ? doc.nickname : (latinFull.isEmpty ? nil : latinFull))
        // Country in the issuer slot. Prefer the ISO 3166-1 alpha-2
        // code (the chip emits alpha-3); fall back to alpha-3 when no
        // mapping is known.
        let issuerShort = ISO3166.alpha2(for: doc.issuingAuthority) ?? doc.issuingAuthority
        // Expiry from MRZ YYMMDD. Reuses the document's own century-
        // aware parser through formattedDateOfExpiry → re-parse the
        // formatted string isn't ideal; instead parse the raw YYMMDD
        // directly here.
        let expiry = Self.parseExpiry(doc.dateOfExpiry)
        return WalletCardData(
            id: "passport:\(doc.id.uuidString)",
            kind: .passport(uuid: doc.id),
            typeLabel: "Passport (NFC)",
            nickname: nickname,
            issuerShort: issuerShort,
            identifier: "NFC Scan",
            issuedAt: doc.readAt,
            expiresAt: expiry,
            palette: palette,
            photo: photo,
            sanctionsBadge: doc.sanctionsResult?.outcome,
        )
    }

    /// MRZ YYMMDD → Date using the same century rule used elsewhere
    /// for expiry dates: always 2000s (passports valid today expire
    /// between now and 2099).
    private static func parseExpiry(_ yymmdd: String) -> Date? {
        guard yymmdd.count == 6, yymmdd.allSatisfy(\.isNumber) else { return nil }
        let yy = Int(yymmdd.prefix(2)) ?? 0
        let mm = Int(yymmdd.dropFirst(2).prefix(2)) ?? 0
        let dd = Int(yymmdd.suffix(2)) ?? 0
        var comps = DateComponents()
        comps.year = 2000 + yy
        comps.month = mm
        comps.day = dd
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

struct SchemaPalette {
    let gradient: LinearGradient
    let foreground: Color
    let humanLabel: String
    let iconSystemName: String

    static func forSchema(_ schemaUri: String) -> SchemaPalette {
        switch schemaUri {
        case "elabify://schema/global/passport/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x1a3d6d), Color(hex: 0x0d2447)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: "Passport",
                iconSystemName: "person.text.rectangle.fill"
            )
        case "elabify://schema/adgm/emiratesId/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0xb91c1c), Color(hex: 0x7f1010)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: "Emirates ID",
                iconSystemName: "person.crop.rectangle.fill"
            )
        case "elabify://schema/global/musnadMaknoon/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x93278f), Color(hex: 0x5e1660)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: "Musnad-Maknoon membership",
                iconSystemName: "person.2.fill"
            )
        case "elabify://schema/global/walletControlEth/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x475569), Color(hex: 0x1e293b)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: "Ethereum wallet control",
                iconSystemName: "diamond.fill"
            )
        case "elabify://schema/global/walletControlBtc/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0xd97706), Color(hex: 0x92400e)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: "Bitcoin wallet control",
                iconSystemName: "bitcoinsign.circle.fill"
            )
        case "elabify://schema/global/corporateIdentity/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x0f172a), Color(hex: 0x1e293b)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: Color(hex: 0xfde68a),
                humanLabel: "Corporate identity",
                iconSystemName: "building.2.fill"
            )
        case "elabify://schema/global/corporateOfficer/v1":
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x0f172a), Color(hex: 0x1e293b), Color(hex: 0x422006)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: Color(hex: 0xfde68a),
                humanLabel: "Corporate officer",
                iconSystemName: "person.badge.shield.checkmark.fill"
            )
        default:
            let humanLabel = schemaUri.split(separator: "/").suffix(2).joined(separator: "/")
            return SchemaPalette(
                gradient: LinearGradient(colors: [Color(hex: 0x5b6370), Color(hex: 0x1a1a1a)], startPoint: .topLeading, endPoint: .bottomTrailing),
                foreground: .white,
                humanLabel: humanLabel.isEmpty ? "Verified credential" : humanLabel,
                iconSystemName: "doc.text.fill"
            )
        }
    }
}

/// Offline fallback issuer label, mirroring the React shortIssuerName().
/// Generic: no hardcoded tenant names. The verified humanLabel from the
/// issuer's signed well-known doc (IssuerIdentityResolver) replaces this once
/// it resolves. For did:method:network:type:slug we show the title-cased issuer
/// slug, then the network, then a neutral "Issuer".
func shortIssuerName(_ issuerDid: String) -> String {
    let parts = issuerDid.split(separator: ":").map(String.init)
    if parts.count >= 5, let slug = parts.last, !slug.isEmpty {
        return slug.capitalized
    }
    if parts.count >= 3 {
        return parts[2].capitalized
    }
    return "Issuer"
}

extension Color {
    /// Convenience initializer for 0xRRGGBB hex.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8)  & 0xff) / 255
        let b = Double( hex        & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
