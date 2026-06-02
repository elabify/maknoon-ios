// dApps catalog browser. Lists the configured catalogs (always
// Elabify + any user-added), drills into a catalog to see its dApps,
// lets the user install one into the Apps tab.
//
// Reached from the Apps tab "+" toolbar button.

import SwiftUI

struct BrowseAppStoreView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.appStores.allCatalogs) { catalog in
                        NavigationLink {
                            CatalogDetailView(catalog: catalog)
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
    @Environment(HolderStore.self) private var store
    @State private var selectedEntry: AppStoreEntry?

    var body: some View {
        Form {
            Section {
                ForEach(catalog.apps) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        entryRow(entry)
                    }
                    .buttonStyle(.plain)
                }
                if catalog.apps.isEmpty {
                    Text("This catalog has no dApps yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text(catalog.name)
            } footer: {
                Text(catalog.summary).font(.caption)
            }
        }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            InstallSheet(catalog: catalog, entry: entry)
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
                if store.appStores.isInstalled(storeId: catalog.id, appId: entry.id) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
            Text(entry.statusLabel)
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
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var isInstalled: Bool {
        store.appStores.isInstalled(storeId: catalog.id, appId: entry.id)
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
                            Text("\(entry.statusLabel) - curated by \(entry.curatedBy)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.statusColor)
                        }
                    }
                    Divider()
                    Text(entry.summary).font(.callout.weight(.medium))
                    Text(entry.details).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if isInstalled {
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
                            dismiss()
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
