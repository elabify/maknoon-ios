// Create a BOLT11 invoice on the active LNDHub account. User
// supplies amount (sats; 0 = amountless invoice) and optional
// memo. The returned payment_request is shown as a QR + copyable
// text.

import SwiftUI

struct LightningReceiveView: View {
    var onCreated: () -> Void = {}
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var amountSat: String = ""
    @State private var memo: String = ""
    @State private var creating: Bool = false
    @State private var invoice: String?
    @State private var lastError: String?

    private var activeAccount: LightningAccount? {
        store.lightningAccountStore.activeAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                if let invoice {
                    invoiceSection(invoice)
                } else {
                    inputSection
                }
                if let lastError {
                    Section { Text(lastError).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Receive Lightning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var inputSection: some View {
        Group {
            Section {
                HStack {
                    TextField("0 (any)", text: $amountSat)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    Text("sat").foregroundStyle(.secondary)
                }
                TextField("Memo (optional)", text: $memo)
            } header: {
                Text("Invoice")
            } footer: {
                Text("Leave amount as 0 for an amountless invoice, the payer chooses the amount when paying.")
                    .font(.caption)
            }
            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        if creating { ProgressView().controlSize(.small) }
                        Text(creating ? "Creating…" : "Create invoice")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(creating || activeAccount == nil)
            }
        }
    }

    @ViewBuilder
    private func invoiceSection(_ pr: String) -> some View {
        Section {
            if let image = BadgeQR.render(Data(pr.utf8), scale: 6) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } header: {
            Text("Scan to pay")
        }
        Section {
            Text(pr)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = pr
            } label: {
                Label("Copy invoice", systemImage: "doc.on.doc")
            }
        } header: {
            Text("BOLT11")
        }
        Section {
            Button("Done") {
                onCreated()
                dismiss()
            }
        }
    }

    @MainActor
    private func create() async {
        guard let account = activeAccount,
              let password = (try? store.lightningAccountStore.password(for: account.id)) ?? nil
        else {
            lastError = "No active account."
            return
        }
        let sats = Int64(amountSat) ?? 0
        creating = true
        lastError = nil
        do {
            let client = LNDHubClient(account: account, password: password)
            let pr = try await client.addInvoice(amountSat: sats, memo: memo)
            invoice = pr
            LogStore.shared.info("lightning.receive", "invoice created: sats=\(sats)")
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        creating = false
    }
}
