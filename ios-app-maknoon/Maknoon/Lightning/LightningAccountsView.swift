// Account management. List existing LNDHub accounts (with
// thumbprint icons) + an "Add account" affordance that drops into
// the Add sheet with manual entry, lndhub:// URL paste, and QR
// scan options.

import SwiftUI

struct LightningAccountsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd: Bool = false
    @State private var renameTarget: LightningAccount?
    @State private var renameDraft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.lightningAccountStore.accounts) { a in
                        accountRow(a)
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add account", systemImage: "plus.circle")
                    }
                } header: {
                    Text("LNDHub accounts")
                } footer: {
                    Text("Each account is one LNDHub custodial wallet: server URL, username, password. Same Zeus/BlueWallet import URL format works here.")
                        .font(.caption)
                }
            }
            .navigationTitle("Lightning accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddLightningAccountSheet(onAdded: { _ in })
                    .environment(store)
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(target: target)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ a: LightningAccount) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.label).font(.callout.weight(.semibold))
                Text(subtitle(for: a)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if a.id == store.lightningAccountStore.activeAccount?.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.lightningAccountStore.setActive(a.id)
            dismiss()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.lightningAccountStore.remove(id: a.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                renameDraft = a.label
                renameTarget = a
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func subtitle(for a: LightningAccount) -> String {
        let host = URL(string: a.serverURL)?.host ?? a.serverURL
        var parts = ["\(a.username)@\(host)"]
        if a.allowInsecureTLS { parts.append("insecure TLS") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func renameSheet(target: LightningAccount) -> some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("e.g. Self-hosted hub", text: $renameDraft)
                }
                Section {
                    Button("Save") {
                        var updated = target
                        updated.label = renameDraft.trimmingCharacters(in: .whitespaces)
                        try? store.lightningAccountStore.update(updated)
                        renameTarget = nil
                    }
                }
            }
            .navigationTitle("Rename account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { renameTarget = nil }
                }
            }
        }
    }
}
