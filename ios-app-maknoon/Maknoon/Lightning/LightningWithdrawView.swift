// LNURL-withdraw (LUD-03). iOS port of Android's LightningWithdrawScreen, using
// the shared LNURL engine already in LNURL.swift. The user pastes/scans a
// withdraw voucher; we fetch its parameters, create a BOLT11 invoice on the
// active LNDHub account for the chosen amount, then submit that invoice to the
// voucher callback so the issuing service PULLS the funds into this account.

import SwiftUI

struct LightningWithdrawView: View {
    var onWithdrawn: () -> Void = {}
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case input
        case ready(LNURL.WithdrawRequest)
        case submitting
        case done
        case error(String)
    }

    @State private var voucher: String = ""
    @State private var amountSat: String = ""
    @State private var phase: Phase = .input

    private var activeAccount: LightningAccount? {
        store.lightningAccountStore.activeAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .input, .error:
                    inputSection
                    if case .error(let msg) = phase {
                        Section { Text(msg).foregroundStyle(.red).font(.callout) }
                    }
                case .ready(let req):
                    readySection(req)
                case .submitting:
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Submitting…")
                        }
                    }
                case .done:
                    doneSection
                }
            }
            .navigationTitle("Withdraw (LNURL)")
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
                TextField("Paste an LNURL-withdraw voucher (lnurl1…) or a lightning: link.", text: $voucher, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    if let s = UIPasteboard.general.string { voucher = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("Withdraw voucher")
            } footer: {
                Text("Scan or paste a withdraw voucher from a service or another wallet. We create an invoice on your active account and submit it so the funds are pulled here.")
                    .font(.caption)
            }
            Section {
                Button {
                    Task { await resolve() }
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(voucher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeAccount == nil)
            }
        }
    }

    @ViewBuilder
    private func readySection(_ req: LNURL.WithdrawRequest) -> some View {
        let minSat = req.minWithdrawable / 1_000
        let maxSat = req.maxWithdrawable / 1_000
        Section {
            if let desc = req.defaultDescription, !desc.isEmpty {
                Text(desc).font(.callout)
            }
            Text("Min: \(minSat) sat").font(.caption).foregroundStyle(.secondary)
            Text("Max: \(maxSat) sat").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Voucher")
        }
        Section {
            HStack {
                TextField("Amount", text: $amountSat)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                Text("sat").foregroundStyle(.secondary)
            }
        } header: {
            Text("Amount (sat)")
        }
        Section {
            let sat = Int64(amountSat.trimmingCharacters(in: .whitespaces))
            let valid = sat != nil && sat! > 0 &&
                sat! * 1_000 >= req.minWithdrawable && sat! * 1_000 <= req.maxWithdrawable
            Button {
                Task { await submit(req) }
            } label: {
                Text("Withdraw").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!valid)
        }
    }

    private var doneSection: some View {
        Group {
            Section {
                Text("Withdraw submitted").font(.headline).foregroundStyle(.green)
                Text("The service is paying your invoice. Funds will arrive in your active account shortly.")
                    .font(.caption)
            }
            Section {
                Button("Done") { onWithdrawn(); dismiss() }
            }
        }
    }

    @MainActor
    private func resolve() async {
        phase = .submitting
        do {
            let url = try LNURL.decode(voucher.trimmingCharacters(in: .whitespacesAndNewlines))
            let req = try await LNURL.fetchWithdrawRequest(url)
            amountSat = String(req.maxWithdrawable / 1_000)
            phase = .ready(req)
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    @MainActor
    private func submit(_ req: LNURL.WithdrawRequest) async {
        guard let account = activeAccount,
              let password = (try? store.lightningAccountStore.password(for: account.id)) ?? nil else {
            phase = .error("No active account, or its password is missing. Re-import the account.")
            return
        }
        guard let sat = Int64(amountSat.trimmingCharacters(in: .whitespaces)), sat > 0 else { return }
        phase = .submitting
        do {
            let client = LNDHubClient(account: account, password: password)
            let invoice = try await client.addInvoice(amountSat: sat, memo: req.defaultDescription ?? "LNURL withdraw")
            try await LNURL.submitWithdraw(req, bolt11: invoice)
            LogStore.shared.info("lightning.withdraw", "submitted invoice to voucher callback: sats=\(sat)")
            phase = .done
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
