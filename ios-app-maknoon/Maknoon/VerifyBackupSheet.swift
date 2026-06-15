// "Verify encrypted backup" sheet (Settings, Local Key, Recovery).
//
// Lets the user confirm that a saved encrypted backup file opens with
// their passphrase, WITHOUT restoring anything. Decryption (and the
// v3 ML-DSA-65 signature check) happen entirely on this phone via
// EncryptedBackup.verify, which discards the decrypted payload. This
// is the safe way to answer "did I write the passphrase down
// correctly, and is this file intact?" before relying on it.

import SwiftUI

struct VerifyBackupSheet: View {
    let onDismiss: () -> Void

    private enum Status: Equatable {
        case idle
        case working
        case ok
        case failed(String)
    }

    @State private var passphrase: String = ""
    @State private var status: Status = .idle
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter the passphrase you used for this backup, then pick the file. Maknoon decrypts it on this phone to confirm it opens. Nothing on this device is changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Passphrase").font(.caption).foregroundStyle(.secondary)
                        SecureField("", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    Button(action: { showImporter = true }) {
                        HStack {
                            if status == .working { ProgressView().tint(.white) }
                            Text(status == .working ? "Verifying…" : "Pick backup file and verify")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(status == .working || passphrase.isEmpty)

                    switch status {
                    case .ok:
                        Label("Backup verified. This file opens with that passphrase.", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    case .failed(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    case .idle, .working:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("Verify encrypted backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                Task { await verify(result) }
            }
        }
    }

    @MainActor
    private func verify(_ pick: Result<[URL], Error>) async {
        status = .working
        let url: URL
        switch pick {
        case .success(let urls):
            guard let first = urls.first else {
                status = .failed("No file picked.")
                return
            }
            url = first
        case .failure(let err):
            status = .failed("File pick failed: \(err.localizedDescription)")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let blob = try Data(contentsOf: url)
            try EncryptedBackup.verify(blob, passphrase: passphrase)
            status = .ok
        } catch {
            status = .failed("Could not open this backup with that passphrase: \(error.localizedDescription)")
        }
    }
}
