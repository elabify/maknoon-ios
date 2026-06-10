// dApps catalog browser. Lists the configured catalogs (always
// Elabify + any user-added), drills into a catalog to see its dApps,
// lets the user install one into the Apps tab.
//
// Reached from the Apps tab "+" toolbar button.

import SwiftUI

struct BrowseAppStoreView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Called when the user taps Open on a (now-)installed mini app, so the
    /// Apps tab can dismiss the browser and jump straight into it.
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.appStores.allCatalogs) { catalog in
                        NavigationLink {
                            CatalogDetailView(catalog: catalog, onOpen: onOpen)
                                .environment(store)
                        } label: {
                            row(catalog: catalog)
                        }
                    }
                } header: {
                    Text("dApps catalogs")
                } footer: {
                    Text("Add additional dApps catalogs in Settings > Apps. Each catalog is just a JSON document hosted at a URL of your (or your institution's) choosing.")
                        .font(.caption)
                }
            }
            .navigationTitle("Browse dApps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.appStores.refresh() }
            .refreshable { await store.appStores.refresh() }
        }
    }

    private func row(catalog: AppStoreCatalog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name).font(.callout.weight(.semibold))
                Text("Curated by \(catalog.curator) - \(catalog.apps.count) app\(catalog.apps.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CatalogDetailView: View {
    let catalog: AppStoreCatalog
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil
    @Environment(HolderStore.self) private var store
    @State private var selectedEntry: AppStoreEntry?

    /// Hide beta-channel apps unless the user opted in. Installed apps are
    /// unaffected (this only filters the browse list).
    private var visibleApps: [AppStoreEntry] {
        store.appStores.showBetaApps
            ? catalog.apps
            : catalog.apps.filter { !AppStoreRegistry.isBeta($0) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(visibleApps) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        entryRow(entry)
                    }
                    .buttonStyle(.plain)
                }
                if visibleApps.isEmpty {
                    if catalog.apps.isEmpty {
                        Text("This catalog has no dApps yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Beta dApps are hidden. Turn on “Show beta apps” in Apps settings to see experimental dApps.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(catalog.name)
            } footer: {
                if !catalog.summary.isEmpty {
                    Text(catalog.summary).font(.caption)
                }
            }
        }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            InstallSheet(catalog: catalog, entry: entry, onOpen: onOpen)
                .environment(store)
        }
    }

    private func entryRow(_ entry: AppStoreEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.iconName)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.callout.weight(.semibold))
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                if let v = entry.version {
                    Text("v\(v)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if store.appStores.isInstalled(storeId: catalog.id, appId: entry.id) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
            Text(entry.channelLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(entry.statusColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

private struct InstallSheet: View {
    let catalog: AppStoreCatalog
    let entry: AppStoreEntry
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var isInstalled: Bool {
        store.appStores.isInstalled(storeId: catalog.id, appId: entry.id)
    }

    /// Disclose the install/per-use capabilities the app requests, with
    /// reasons. Installing grants this set; auto capabilities aren't shown.
    @ViewBuilder
    private var capabilitiesSection: some View {
        let caps = MiniAppCapabilityRegistry.disclosable(entry.declaredCapabilityTokens)
        if !caps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("This app can").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(caps) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.icon).foregroundStyle(.purple).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.label).font(.callout.weight(.medium))
                            Text(entry.reason(for: c.token)).font(.caption).foregroundStyle(.secondary)
                        }
                        if c.tier == .perUse {
                            Spacer(minLength: 0)
                            Text("asks each time").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: entry.iconName)
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.title3.weight(.semibold))
                            Text("\(entry.channelLabel)\(entry.version.map { " · v\($0)" } ?? "") - curated by \(entry.curatedBy)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.statusColor)
                        }
                    }
                    DAppCompatibilityRow(requires: entry.requiresMaknoonVersion)
                    Divider()
                    Text(entry.summary).font(.callout.weight(.medium))
                    Text(entry.details).font(.callout).foregroundStyle(.secondary)
                    capabilitiesSection
                    Spacer(minLength: 0)
                    if isInstalled {
                        if entry.isMiniApp {
                            Button {
                                let app = store.appStores.installedApps.first { $0.id == "\(catalog.id)::\(entry.id)" }
                                dismiss()
                                if let app { onOpen?(app) }
                            } label: {
                                Label("Open", systemImage: "arrow.up.right.square")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button(role: .destructive) {
                            store.appStores.uninstall(installedAppId: "\(catalog.id)::\(entry.id)")
                            dismiss()
                        } label: {
                            Label("Uninstall", systemImage: "minus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            store.appStores.install(entry, fromStore: catalog.id)
                            // Jump straight in for a runnable mini app.
                            if entry.isMiniApp {
                                let app = store.appStores.installedApps.first { $0.id == "\(catalog.id)::\(entry.id)" }
                                dismiss()
                                if let app { onOpen?(app) }
                            } else {
                                dismiss()
                            }
                        } label: {
                            Label("Install to Apps tab", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
            }
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
