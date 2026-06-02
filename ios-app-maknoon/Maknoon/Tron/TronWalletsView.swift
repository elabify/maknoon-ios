// Manage Tron wallets. Mirrors `SolanaWalletsView` (Form-style list
// with EditButton + drag-to-reorder + swipe Rename/Remove + Add
// wallet entry pointing at AddTronWalletSheet).

import SwiftUI

struct TronWalletsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd = false
    @State private var renameTarget: TronWalletDescriptor?
    @State private var renameDraft: String = ""

    var body: some View {
        Form {
            if store.tronWalletStore.wallets.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "circle.hexagongrid")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.tertiary)
                        Button {
                            showAdd = true
                        } label: {
                            Label("Add a Tron wallet", systemImage: "plus.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section("Wallets") {
                    ForEach(store.tronWalletStore.wallets) { w in
                        walletRow(w)
                    }
                    .onMove { offsets, dest in
                        store.tronWalletStore.move(
                            fromOffsets: offsets, toOffset: dest
                        )
                    }
                }
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add wallet", systemImage: "plus.circle")
                    }
                }
            }
        }
        .navigationTitle("Tron wallets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !store.tronWalletStore.wallets.isEmpty {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTronWalletSheet { _ in showAdd = false }
                .environment(store)
        }
        .alert("Rename wallet", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Label", text: $renameDraft)
            Button("Save") {
                if let t = renameTarget, !renameDraft.isEmpty {
                    store.tronWalletStore.rename(id: t.id, to: renameDraft)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Enter a new label for this Tron wallet.")
        }
    }

    private func walletRow(_ w: TronWalletDescriptor) -> some View {
        let isActive = store.tronWalletStore.activeWallet?.id == w.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(w.label).font(.callout.weight(.semibold))
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                Text(subtitle(for: w)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.tronWalletStore.remove(id: w.id)
                store.devices.scrubWalletId(w.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameDraft = w.label
                renameTarget = w
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func subtitle(for w: TronWalletDescriptor) -> String {
        switch w.kind {
        case .software(let a):           return "Software - account \(a)"
        case .hardware(_, let a, _):     return "Hardware - account \(a)"
        }
    }
}
