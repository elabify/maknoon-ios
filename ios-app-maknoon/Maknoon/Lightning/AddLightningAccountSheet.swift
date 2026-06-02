// Add an LNDHub-compatible account. Two ways in:
//
//   • Import — paste or scan a `lndhub://user:pass@host[:port][/path]`
//     URL. Same wire format Zeus, BlueWallet, and most LNDHub
//     front-ends use to export an account. The parsed values fill in
//     the manual fields below so the user can sanity-check before
//     saving.
//   • Manual — server URL + username + password fields the user fills
//     in directly. Useful for self-hosted hubs whose operator hands
//     credentials over out-of-band.
//
// A single TLS toggle in the Transport section lets users opt into
// self-signed certificates when they're running a hub behind a
// private CA.

import SwiftUI

struct AddLightningAccountSheet: View {
    var onAdded: (LightningAccount) -> Void = { _ in }

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var manualLabel: String = ""
    @State private var manualServer: String = ""
    @State private var manualUsername: String = ""
    @State private var manualPassword: String = ""
    @State private var allowInsecureTLS: Bool = false
    @State private var lastError: String?
    @State private var showScanner: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if let s = UIPasteboard.general.string {
                            applyImport(s)
                        } else {
                            lastError = "Clipboard is empty."
                        }
                    } label: {
                        Label("Paste lndhub URL", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan lndhub QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Format: lndhub://user:password@host[:port][/path]. Same wire shape Zeus and BlueWallet export. Imported values fill the fields below; tap Add account to save.")
                        .font(.caption)
                }

                Section {
                    TextField("Label (e.g. Self-hosted hub)", text: $manualLabel)
                    TextField("Server URL (https://...)", text: $manualServer)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                    TextField("Username", text: $manualUsername)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                    SecureField("Password", text: $manualPassword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                } header: {
                    Text("Server credentials")
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

                if let lastError {
                    Section {
                        Text(lastError).foregroundStyle(.red).font(.callout)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Add account").frame(maxWidth: .infinity)
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Add Lightning account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                ScanLNDHubSheet { scanned in
                    showScanner = false
                    applyImport(scanned)
                }
            }
        }
    }

    private var canSave: Bool {
        !manualServer.trimmingCharacters(in: .whitespaces).isEmpty
            && !manualUsername.trimmingCharacters(in: .whitespaces).isEmpty
            && !manualPassword.isEmpty
    }

    /// Parse a scanned or pasted lndhub URL into the manual fields so
    /// the user can sanity-check before saving. Trims surrounding
    /// whitespace, accepts the optional `?tls` query suffix some
    /// exporters add, and surfaces a clear error when parsing fails.
    @MainActor
    private func applyImport(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = LightningAccountStore.parseImportURL(trimmed) else {
            lastError = "Could not parse the URL. Expected lndhub://user:password@host[:port][/path]."
            return
        }
        lastError = nil
        manualServer = parsed.account.serverURL
        manualUsername = parsed.account.username
        manualPassword = parsed.password
        if manualLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            manualLabel = parsed.account.label
        }
    }

    @MainActor
    private func save() {
        lastError = nil
        do {
            let trimmedServer = manualServer.trimmingCharacters(in: .whitespaces)
            guard URL(string: trimmedServer) != nil else {
                lastError = "Server URL is not a valid URL."
                return
            }
            let label = manualLabel.trimmingCharacters(in: .whitespaces).isEmpty
                ? (URL(string: trimmedServer)?.host ?? "Lightning")
                : manualLabel
            let acc = LightningAccount(
                label: label,
                serverURL: trimmedServer,
                username: manualUsername.trimmingCharacters(in: .whitespaces),
                allowInsecureTLS: allowInsecureTLS
            )
            let added = try store.lightningAccountStore.add(acc, password: manualPassword)
            onAdded(added)
            dismiss()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

private struct ScanLNDHubSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onCode: onScan)
                .ignoresSafeArea()
                .navigationTitle("Scan lndhub QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}
