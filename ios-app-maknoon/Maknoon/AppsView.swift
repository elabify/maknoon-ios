// Apps tab. Empty by default; populates from the AppStoreRegistry's
// installedApps as the user installs integrations via the
// BrowseAppStoreView ("+" toolbar) → tap a dApp → Install.
//
// Connected-verifiers history is preserved beneath the installed-apps
// section: a record of every credential disclosure the holder has
// performed, regardless of whether the verifier ships through a
// dApps catalog.

import SwiftUI

struct AppsView: View {
    @Environment(HolderStore.self) private var store
    @State private var entries: [VerifierHistoryEntry] = []
    @State private var groups: [(verifierDid: String, verifierName: String?, label: String, entries: [VerifierHistoryEntry])] = []
    @State private var selectedInstalled: AppStoreRegistry.InstalledApp?
    @State private var showSettings = false
    @State private var showBrowse = false

    var body: some View {
        Form {
            installedSection
            verifierHistorySection
        }
        .navigationTitle("Apps")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBrowse = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add app")
            }
        }
        .onAppear { refresh() }
        .task { await store.appStores.refresh() }
        .sheet(isPresented: $showBrowse) {
            BrowseAppStoreView(onOpen: { app in
                showBrowse = false
                selectedInstalled = app
            }).environment(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(store)
        }
        .sheet(item: $selectedInstalled) { app in
            InstalledAppDetailSheet(app: app)
                .environment(store)
        }
    }

    // MARK: -- installed apps

    @ViewBuilder
    private var installedSection: some View {
        Section {
            if store.appStores.installedApps.isEmpty {
                emptyState
            } else {
                ForEach(store.appStores.installedApps) { app in
                    Button {
                        selectedInstalled = app
                    } label: {
                        installedRow(app)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Installed")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No apps installed yet")
                .font(.callout.weight(.semibold))
            Text("Tap the + in the top right to browse the Maknoon dApps catalog (and any catalogs you have added in Settings > Apps).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func installedRow(_ app: AppStoreRegistry.InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: app.entry.iconName)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.entry.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(app.entry.summary).font(.caption).foregroundStyle(.secondary)
                if let v = app.entry.version {
                    Text("v\(v)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Text(app.entry.channelLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(app.entry.statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(app.entry.statusColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    // MARK: -- verifier history

    @ViewBuilder
    private var verifierHistorySection: some View {
        Section {
            if groups.isEmpty {
                Text("No verifiers yet. Once you share a credential, the verifier appears here with the claims you disclosed and the last time you shared.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups, id: \.verifierDid) { group in
                    NavigationLink {
                        VerifierHistoryDetail(group: group)
                    } label: {
                        verifierHistoryRow(group)
                    }
                }
            }
        } header: {
            Text("Connected verifiers")
        }
    }

    private func verifierHistoryRow(_ group: (verifierDid: String, verifierName: String?, label: String, entries: [VerifierHistoryEntry])) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group.verifierName == nil ? "person.crop.circle.dashed" : "person.crop.circle.fill.badge.checkmark")
                .font(.title3)
                .foregroundStyle(group.verifierName == nil ? Color.secondary : Color.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.verifierName ?? group.label).font(.callout.weight(.semibold))
                Text(verifierDidShort(group.verifierDid))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let first = group.entries.first {
                    Text("Last share \(formatRelative(first.lastUsedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Text("\(group.entries.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: -- helpers

    private func refresh() {
        entries = VerifierHistory.all()
        groups = VerifierHistory.groupedByVerifier()
    }

    private func verifierDidShort(_ did: String) -> String {
        if did.count <= 36 { return did }
        return String(did.prefix(20)) + "…" + String(did.suffix(10))
    }

    private func formatRelative(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: -- installed app detail sheet

private struct InstalledAppDetailSheet: View {
    let app: AppStoreRegistry.InstalledApp
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var openApp = false
    @State private var granted: Set<String> = []

    private var hasOpenAction: Bool {
        app.entry.isMiniApp
    }

    /// Capabilities the user can review + revoke for this app.
    @ViewBuilder
    private var capabilitiesSection: some View {
        let caps = MiniAppCapabilityRegistry.disclosable(app.entry.declaredCapabilityTokens)
        if !caps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(caps) { c in
                    Toggle(isOn: Binding(
                        get: { granted.contains(c.token) },
                        set: { on in
                            if on { granted.insert(c.token) } else { granted.remove(c.token) }
                            store.appStores.setGrantedCapabilities(installedAppId: app.id, granted)
                        }
                    )) {
                        HStack(spacing: 10) {
                            Image(systemName: c.icon).foregroundStyle(.purple).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.label).font(.callout)
                                Text(app.entry.reason(for: c.token)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Revoking a permission takes effect next time the app runs.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: app.entry.iconName)
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                            .frame(width: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.entry.title).font(.title3.weight(.semibold))
                            Text("\(app.entry.channelLabel)\(app.entry.version.map { " · v\($0)" } ?? "") - curated by \(app.entry.curatedBy)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(app.entry.statusColor)
                        }
                    }
                    DAppCompatibilityRow(requires: app.entry.requiresMaknoonVersion)
                    Text(app.entry.summary).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Text(app.entry.details).font(.callout)
                    capabilitiesSection
                    if hasOpenAction {
                        Button {
                            openApp = true
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        store.appStores.uninstall(installedAppId: app.id)
                        // Remove the app's durable settings (incl. its receipts),
                        // merchant identity + cached bundle so nothing orphaned survives.
                        store.miniAppSettings.evict(appId: app.id)
                        store.merchantIdentity.evict(app.id)
                        let installedId = app.id
                        Task { await MiniAppBundleStore.shared.evict(installedAppId: installedId) }
                        dismiss()
                    } label: {
                        Label("Uninstall", systemImage: "minus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationDestination(isPresented: $openApp) {
                MiniAppHostView(app: app)
                    .environment(store)
            }
            .navigationTitle(app.entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                granted = store.appStores.installedApps.first { $0.id == app.id }?.grantedSet ?? app.grantedSet
            }
        }
    }
}

// MARK: -- verifier detail screen

private struct VerifierHistoryDetail: View {
    let group: (verifierDid: String, verifierName: String?, label: String, entries: [VerifierHistoryEntry])

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.verifierName ?? group.label).font(.callout.weight(.semibold))
                    Text(group.verifierDid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Verifier")
            }
            Section("Shares") {
                ForEach(group.entries) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SchemaPalette.forSchema(e.credentialSchema).humanLabel)
                            .font(.callout.weight(.medium))
                        Text("Disclosed: \(e.disclosedKeys.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatAbsolute(e.lastUsedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Verifier history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatAbsolute(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
