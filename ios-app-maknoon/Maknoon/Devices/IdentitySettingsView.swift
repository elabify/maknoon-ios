// Settings > Identity. Picks which registered device (if any) is
// the active second factor on the Identity Sandwich. Devices that
// haven't been registered yet, or that don't support the .identity
// capability, are not shown.

import SwiftUI

struct IdentitySettingsView: View {
    @Environment(HolderStore.self) private var store

    @State private var newIssuerDraft: String = ""
    /// Live health per known-issuer host. Drives the status indicator; the green
    /// shield only shows when the issuer is reachable over valid TLS and returns
    /// a well-formed /v1/issuer/info document.
    @State private var health: [String: IssuerHealth] = [:]

    // Cached CSCA trust-list state (for the Passport trust list section).
    @State private var cscaVersion: String?
    @State private var cscaCount: Int?
    @State private var cscaRefreshedAt: Date?
    @State private var cscaUpdating = false

    var body: some View {
        Form {
            biometricSection
            registeredSection
            knownIssuersSection
            cscaSection
            footerSection
        }
        .navigationTitle("Identity")
        .navigationBarTitleDisplayMode(.inline)
        // Re-check on appear and whenever the host list changes (add/remove);
        // pull-to-refresh forces a re-check.
        .task(id: store.knownIssuers.hosts) { await refreshAll() }
        .task { await loadCscaState() }
        .refreshable { await refreshAll() }
    }

    /// Allow-list of credential issuers. The Receive flow consults
    /// this at fetch time; unknown issuers trigger a one-time-trust
    /// prompt instead of silently issuing.
    private var knownIssuersSection: some View {
        Section {
            ForEach(store.knownIssuers.hosts, id: \.self) { host in
                HStack(alignment: .top, spacing: 8) {
                    statusIcon(health[host])
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host)
                            .font(.callout.monospaced())
                        if let sub = statusSubtitle(health[host]) {
                            Text(sub)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.knownIssuers.remove(host)
                        health[host] = nil
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            HStack {
                TextField("issuer.example.com", text: $newIssuerDraft)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout.monospaced())
                Button {
                    let raw = newIssuerDraft
                    newIssuerDraft = ""
                    store.knownIssuers.add(raw)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newIssuerDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Known issuers")
        } footer: {
            Text("Pickup URLs from these hosts are accepted silently. Other hosts trigger a one-time-trust prompt at Receive time. Paste a full URL or just a hostname; only the host is stored. The shield turns green only when the issuer is reachable over a valid TLS connection and returns a valid issuer document; pull down to re-check.")
                .font(.caption)
        }
    }

    // MARK: -- passport trust list (CSCA)

    private var cscaSection: some View {
        Section {
            HStack {
                Text("Trust list")
                Spacer()
                Text(cscaCount.map { "\($0) certificates" } ?? "Not downloaded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let v = cscaVersion {
                HStack {
                    Text("Version").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(v).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let d = cscaRefreshedAt {
                HStack {
                    Text("Updated").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(d, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await updateCsca() }
            } label: {
                HStack(spacing: 8) {
                    if cscaUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(cscaUpdating ? "Updating…" : "Update now").fontWeight(.medium)
                }
            }
            .disabled(cscaUpdating || store.knownIssuers.hosts.isEmpty)
        } header: {
            Text("Passport trust list (CSCA)")
        } footer: {
            Text("Country Signing CA certificates used to check passport chip authenticity on-device. Fetched from your first known issuer (\(store.knownIssuers.hosts.first ?? "none set")) and refreshed automatically; the issuer also verifies authoritatively. Tap Update now to pull the latest list.")
                .font(.caption)
        }
    }

    private func loadCscaState() async {
        cscaVersion = await CSCATrustStore.shared.version
        cscaCount = await CSCATrustStore.shared.certCount
        cscaRefreshedAt = await CSCATrustStore.shared.lastRefreshedAt
    }

    private func updateCsca() async {
        guard let host = store.knownIssuers.hosts.first,
              let base = store.knownIssuers.outboundBaseURL(forEntry: host) else { return }
        cscaUpdating = true
        defer { cscaUpdating = false }
        _ = await CSCATrustStore.shared.refresh(from: base, force: true)
        await loadCscaState()
    }

    // MARK: -- known-issuer health

    /// Re-check every known issuer concurrently. A host is healthy only when
    /// GET {host}/v1/issuer/info succeeds over valid TLS with a well-formed body.
    @MainActor
    private func refreshAll() async {
        let hosts = store.knownIssuers.hosts
        await withTaskGroup(of: (String, IssuerHealth).self) { group in
            for host in hosts {
                guard let base = store.knownIssuers.outboundBaseURL(forEntry: host) else {
                    health[host] = .invalid("bad host")
                    continue
                }
                health[host] = .checking
                group.addTask { (host, await IssuerHealthCheck.check(baseURL: base)) }
            }
            for await (host, status) in group {
                health[host] = status
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: IssuerHealth?) -> some View {
        switch status ?? .checking {
        case .checking:
            ProgressView().controlSize(.small)
        case .healthy:
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
        case .unreachable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .invalid:
            Image(systemName: "xmark.shield.fill").foregroundStyle(.red)
        }
    }

    private func statusSubtitle(_ status: IssuerHealth?) -> String? {
        guard let status else { return nil }
        switch status {
        case .checking: return "Checking…"
        case .healthy(let did): return "Verified · \(did)"
        case .unreachable(let reason): return "Unreachable · \(reason)"
        case .invalid(let reason): return "Not a valid issuer · \(reason)"
        }
    }

    // MARK: -- always-on biometric / passcode

    private var biometricSection: some View {
        Section {
            HStack {
                Image(systemName: "cpu.fill").foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Secure Enclave Signing").font(.callout.weight(.semibold))
                    Text("Required for every sensitive operation. Authorized by your preferred configured biometric or passcode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("On-device authorization")
        } footer: {
            Text("Always on. Cannot be disabled.")
                .font(.caption)
        }
    }

    // MARK: -- registered devices that can protect Identity

    private var identityDevices: [RegisteredDevice] {
        store.devices.devicesSupporting(.identity)
    }

    private var registeredSection: some View {
        Section {
            if identityDevices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No identity-capable devices registered yet.")
                        .font(.callout.weight(.semibold))
                    Text("Register a YubiKey or a Ledger Nano X from Settings > Devices, then return here to enable it as a second factor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(identityDevices) { dev in
                    deviceRow(dev)
                }
            }
        } header: {
            Text("Hardware second factor")
        } footer: {
            Text("Enabling a device wraps your BIP39 entropy with an AES-256 key derived from a deterministic signature only that device can produce. The device is required on every cold launch unlock once enabled. Losing the device strands the sandwich; restore from your 24-word paper seed in that case.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func deviceRow(_ dev: RegisteredDevice) -> some View {
        let active = dev.promotions.identity != nil
        HStack(spacing: 12) {
            Image(systemName: dev.kind.systemImage)
                .font(.title3)
                .foregroundStyle(active ? .green : .purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.label).font(.callout.weight(.semibold))
                Text("\(dev.kind.displayName) - \(dev.serialDisplay)")
                    .font(.caption).foregroundStyle(.secondary)
                if active {
                    Label("Enabled", systemImage: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            NavigationLink {
                DeviceDetailView(deviceId: dev.id)
                    .environment(store)
            } label: {
                Text("Configure").font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Enabling / disabling runs FIDO2 hmac-secret enrollment over the device's existing transport. Only YubiKey enrollment needs the paid Apple Developer Program (NFC reader + accessory entitlements). Ledger and Trezor run over Bluetooth and do not need any additional iOS entitlements.")
                .font(.caption)
        }
    }
}

/// Live health/validity of a known issuer, surfaced in Settings → Identity. A
/// host is only `healthy` (green shield) when its `/v1/issuer/info` is reachable
/// over a valid TLS connection and returns a well-formed Elabify issuer document.
enum IssuerHealth: Equatable, Sendable {
    case checking
    case healthy(did: String)
    case unreachable(String)   // DNS / TLS / connection / timeout
    case invalid(String)       // reachable, but not a valid issuer (non-2xx or bad body)
}

enum IssuerHealthCheck {
    private struct InfoResponse: Decodable { let did: String }

    /// GET {baseURL}/v1/issuer/info with a short timeout. URLError (incl. TLS
    /// failures) → `.unreachable`; non-2xx or undecodable body → `.invalid`.
    static func check(baseURL: URL) async -> IssuerHealth {
        guard let url = URL(string: baseURL.absoluteString + "/v1/issuer/info") else {
            return .invalid("bad URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .invalid("no response") }
            guard (200..<300).contains(http.statusCode) else { return .invalid("HTTP \(http.statusCode)") }
            guard let info = try? JSONDecoder().decode(InfoResponse.self, from: data),
                  !info.did.isEmpty else {
                return .invalid("not an Elabify issuer")
            }
            return .healthy(did: info.did)
        } catch let err as URLError {
            return .unreachable(err.shortReason)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

private extension URLError {
    /// Short, human-readable reason for the status subtitle.
    var shortReason: String {
        switch code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost: return "cannot connect"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .secureConnectionFailed: return "TLS handshake failed"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "untrusted TLS certificate"
        case .appTransportSecurityRequiresSecureConnection: return "insecure (HTTP) blocked"
        case .notConnectedToInternet: return "no internet"
        default: return localizedDescription
        }
    }
}
