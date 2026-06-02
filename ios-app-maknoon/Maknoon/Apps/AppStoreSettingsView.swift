// Settings page for managing configured dApps catalogs. Lists the
// built-in Elabify catalog (read-only), every user-added catalog, and
// an "Add dApps catalog" row that lets the user paste a URL.

import SwiftUI

struct AppStoreSettingsView: View {
    @Environment(HolderStore.self) private var store

    @State private var showAddSheet = false

    var body: some View {
        Form {
            Section {
                row(
                    title: store.appStores.defaultStore.name,
                    subtitle: "Curated by \(store.appStores.defaultStore.curator) - built in",
                    canRemove: false,
                    removeAction: nil
                )
            } header: {
                Text("Default dApps catalog")
            } footer: {
                Text("The Elabify-curated dApps catalog ships with Maknoon and cannot be removed.")
                    .font(.caption)
            }

            Section {
                if store.appStores.userStores.isEmpty {
                    Text("No additional dApps catalogs configured.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.appStores.userStores) { s in
                        row(
                            title: s.name,
                            subtitle: s.url.absoluteString,
                            canRemove: true,
                            removeAction: {
                                store.appStores.removeStore(id: s.id)
                            }
                        )
                    }
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add dApps catalog…", systemImage: "plus.circle")
                }
            } header: {
                Text("Additional dApps catalogs")
            } footer: {
                Text("Add an institution-curated dApps catalog by URL. The catalog is a JSON document Maknoon fetches and renders alongside the built-in one. Useful for issuers and verifier consortia that want to publish their own curated integration list.")
                    .font(.caption)
            }
        }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddSheet) {
            AddStoreSheet().environment(store)
        }
    }

    private func row(title: String, subtitle: String, canRemove: Bool, removeAction: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if canRemove, let removeAction {
                Button(role: .destructive) {
                    removeAction()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddStoreSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Catalog name (e.g. MyBank dApps)", text: $name)
                    TextField("https://example.com/dapps.json", text: $urlString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("The URL should serve a JSON dApps catalog matching Maknoon's schema. Maknoon fetches it and renders its entries alongside the built-in catalog.")
                        .font(.caption)
                }
                Section {
                    Button("Add") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        let trimmedURL = urlString.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty else {
                            error = "Name is required."
                            return
                        }
                        guard let url = URL(string: trimmedURL),
                              let scheme = url.scheme?.lowercased(),
                              scheme == "https" || scheme == "http" else {
                            error = "URL must start with http:// or https://."
                            return
                        }
                        store.appStores.addStore(name: trimmedName, url: url)
                        dismiss()
                    }
                    .disabled(name.isEmpty || urlString.isEmpty)
                }
            }
            .navigationTitle("Add dApps catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
