// Modal picker presented from any Send view. Filtered to a
// single network so a Bitcoin Send only shows Bitcoin contacts.
// Tapping a row hands the entry's address back via the
// `onPick` callback and dismisses.
//
// The list groups wallet-mirror "system" entries ("Your wallets")
// above user-entered contacts so users sending between their own
// wallets pick from a curated set, not their memory. A small Edit
// button in the toolbar dismisses the picker and navigates to
// Settings → Address book for full CRUD on user entries.

import SwiftUI

struct AddressBookPickerSheet: View {
    let network: AddressBookNetwork
    let onPick: (AddressBookEntry) -> Void
    /// Fired when the user taps the toolbar Edit button. The
    /// parent dismisses the picker and pushes
    /// `AddressBookView` so edits feel like a normal navigation,
    /// not a sheet-on-sheet stack.
    var onEdit: (() -> Void)? = nil

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var grouped: (system: [AddressBookEntry], user: [AddressBookEntry]) {
        store.addressBook.entriesGrouped(for: network)
    }

    var body: some View {
        NavigationStack {
            List {
                let g = grouped
                if g.system.isEmpty && g.user.isEmpty {
                    Section {
                        Text("No \(network.displayName) contacts yet. Add some in Settings → Address book.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !g.system.isEmpty {
                    Section("Your wallets") {
                        ForEach(g.system) { entry in
                            row(entry)
                        }
                    }
                }
                if !g.user.isEmpty {
                    Section("Contacts") {
                        ForEach(g.user) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .navigationTitle("\(network.displayName) contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let onEdit {
                        Button {
                            dismiss()
                            onEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AddressBookEntry) -> some View {
        Button {
            onPick(entry)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                if entry.source.isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name.isEmpty ? entry.address : entry.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(entry.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
