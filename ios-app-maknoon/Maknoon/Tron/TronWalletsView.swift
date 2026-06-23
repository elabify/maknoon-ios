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
        .sheet(item: $renameTarget) { target in
            renameSheet(target: target)
                .environment(store)
        }
    }

    private func walletRow(_ w: TronWalletDescriptor) -> some View {
        Button {
            store.tronWalletStore.setActive(w.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.label).font(.headline)
                    Text(subtitle(for: w)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.tronWalletStore.activeWallet?.id == w.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.tronWalletStore.remove(id: w.id)
                store.devices.scrubWalletId(w.id)
            } label: {
                Label("Remove", systemImage: "trash")
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

    @ViewBuilder
    private func renameSheet(target: TronWalletDescriptor) -> some View {
        NavigationStack {
            Form {
                Section("Wallet label") {
                    TextField("e.g. Daily", text: $renameDraft)
                }
                Section {
                    Button("Save") {
                        if !renameDraft.isEmpty {
                            store.tronWalletStore.rename(id: target.id, to: renameDraft)
                        }
                        renameTarget = nil
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { renameTarget = nil }
                }
            }
        }
    }

    private func subtitle(for w: TronWalletDescriptor) -> String {
        switch w.kind {
        case .software(let a):           return "Software - account \(a)"
        case .hardware(_, let a, _):     return "Hardware - account \(a)"
        }
    }
}
