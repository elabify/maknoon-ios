// Tiny edit-label sheet used by:
//   - BitcoinTxRow's long-press context menu ("Label transaction…")
//   - UTXOPickerView's per-row pencil button ("Edit label")
//
// Reads + writes BitcoinLabelStore (already on HolderStore as
// `bitcoinLabels`). The scope (address vs txid:vout output)
// determines which setter we call.

import SwiftUI

struct BitcoinLabelEditSheet: View {
    enum Scope: Equatable, Hashable {
        case address(String)
        case output(txid: String, vout: UInt32)

        var displayName: String {
            switch self {
            case .address(let a):
                // First/last six is enough to identify; the user
                // already chose this in the tx row before they got
                // here.
                if a.count <= 16 { return a }
                return "\(a.prefix(6))…\(a.suffix(6))"
            case .output(let txid, let vout):
                let short = txid.count <= 16
                    ? txid
                    : "\(txid.prefix(6))…\(txid.suffix(6))"
                return "\(short):\(vout)"
            }
        }
    }

    let scope: Scope
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label (e.g. Lunch with Alice)", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text("Label")
                } footer: {
                    Text("Labels are stored on this device only and are not shared with anyone else.")
                        .font(.caption)
                }

                Section {
                    LabeledContent("Applies to", value: scope.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                text = currentLabel ?? ""
                // Auto-focus so the user can start typing
                // immediately without a second tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focused = true
                }
            }
        }
    }

    private var currentLabel: String? {
        switch scope {
        case .address(let a):
            return store.bitcoinLabels.label(forAddress: a)
        case .output(let txid, let vout):
            return store.bitcoinLabels.label(forOutput: txid, vout: vout)
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch scope {
        case .address(let a):
            store.bitcoinLabels.setLabel(trimmed, forAddress: a)
        case .output(let txid, let vout):
            store.bitcoinLabels.setLabel(trimmed, forOutput: txid, vout: vout)
        }
        dismiss()
    }
}
