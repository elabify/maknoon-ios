// Settings → Networks → Lightning. Lists every LNDHub account
// with its TLS flag. Tap into one to edit the flag or rotate
// credentials.

import SwiftUI

struct LightningSettingsView: View {
    @Environment(HolderStore.self) private var store

    @State private var showAdd: Bool = false
    @State private var editTarget: LightningAccount?

    var body: some View {
        Form {
            Section {
                if store.lightningAccountStore.accounts.isEmpty {
                    Text("No Lightning accounts yet. Tap below to add one.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.lightningAccountStore.accounts) { a in
                        Button {
                            editTarget = a
                        } label: {
                            HStack(spacing: 12) {
                                WalletThumbprint(seed: a.thumbprintSeed, size: 32, systemImage: "bolt.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.label).font(.callout.weight(.semibold))
                                    Text(rowSubtitle(a))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.lightningAccountStore.remove(id: a.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showAdd = true
                } label: {
                    Label("Add account", systemImage: "plus.circle")
                }
            } header: {
                Text("LNDHub accounts")
            } footer: {
                Text("Each account is one LNDHub-compatible credential set (server URL + username + password). Multiple separate accounts are supported; switch which one's active from the Lightning wallet's account picker.")
                    .font(.caption)
            }

            Section {
                Text("Lightning passwords live in Keychain. Account metadata (label, server, username) is included in the YAML settings backup; passwords are NOT exported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Security")
            }
        }
        .navigationTitle("Lightning")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddLightningAccountSheet().environment(store)
        }
        .sheet(item: $editTarget) { account in
            EditLightningAccountSheet(account: account).environment(store)
        }
    }

    private func rowSubtitle(_ a: LightningAccount) -> String {
        let host = URL(string: a.serverURL)?.host ?? a.serverURL
        var parts = ["\(a.username)@\(host)"]
        if a.allowInsecureTLS { parts.append("insecure TLS") }
        return parts.joined(separator: " · ")
    }
}

/// Edit the flags + label + (optionally) the password of an
/// existing LNDHub account.
struct EditLightningAccountSheet: View {
    let account: LightningAccount
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var allowInsecureTLS: Bool
    @State private var newPassword: String = ""
    @State private var lastError: String?

    init(account: LightningAccount) {
        self.account = account
        _label = State(initialValue: account.label)
        _allowInsecureTLS = State(initialValue: account.allowInsecureTLS)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Label", text: $label)
                    LabeledContent("Server", value: account.serverURL)
                        .font(.caption.monospaced())
                    LabeledContent("Username", value: account.username)
                        .font(.caption.monospaced())
                }
                Section {
                    Toggle("Validate TLS certificate", isOn: Binding(
                        get: { !allowInsecureTLS },
                        set: { allowInsecureTLS = !$0 }
                    ))
                } header: {
                    Text("Transport")
                } footer: {
                    Text("Disable TLS validation only if your hub uses a self-signed certificate you trust.")
                        .font(.caption)
                }
                Section {
                    SecureField("New password (leave blank to keep current)", text: $newPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Rotate password")
                } footer: {
                    Text("Saved to Keychain. Use this if the LNDHub provider rotated your credentials.")
                        .font(.caption)
                }
                if let lastError {
                    Section { Text(lastError).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button("Save") {
                        save()
                    }
                }
            }
            .navigationTitle("Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() {
        var updated = account
        updated.label = label.trimmingCharacters(in: .whitespaces)
        updated.allowInsecureTLS = allowInsecureTLS
        do {
            try store.lightningAccountStore.update(
                updated,
                newPassword: newPassword.isEmpty ? nil : newPassword
            )
            dismiss()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
