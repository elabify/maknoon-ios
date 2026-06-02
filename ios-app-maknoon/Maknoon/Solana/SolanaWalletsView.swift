// Solana wallet list management: add, rename, remove, set-active.
// Mirrors BitcoinWalletsView at a smaller scale. Hardware-paired
// wallet creation lands in Phase C; this view exposes software
// wallets only.

import SwiftUI

struct SolanaWalletsView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd: Bool = false
    @State private var renameTarget: SolanaWalletDescriptor?
    @State private var renameDraft: String = ""

    var body: some View {
        Form {
            if store.solanaWalletStore.wallets.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "circle.hexagongrid")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.tertiary)
                        Button {
                            showAdd = true
                        } label: {
                            Label("Add a Solana wallet", systemImage: "plus.circle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section("Wallets") {
                    ForEach(store.solanaWalletStore.wallets) { w in
                        walletRow(w)
                    }
                    .onMove { offsets, dest in
                        store.solanaWalletStore.move(
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
        .navigationTitle("Solana wallets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !store.solanaWalletStore.wallets.isEmpty {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddSolanaWalletSheet { _ in showAdd = false }
                .environment(store)
        }
        .alert("Rename wallet", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Label", text: $renameDraft)
            Button("Save") {
                if let t = renameTarget, !renameDraft.isEmpty {
                    store.solanaWalletStore.rename(id: t.id, to: renameDraft)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Enter a new label for this Solana wallet.")
        }
    }

    private func walletRow(_ w: SolanaWalletDescriptor) -> some View {
        let isActive = store.solanaWalletStore.activeWallet?.id == w.id
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
        // allowsFullSwipe: false prevents a continued right-swipe from
        // auto-firing Delete. The user has to tap the exposed Delete
        // button explicitly.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.solanaWalletStore.remove(id: w.id)
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

    private func subtitle(for w: SolanaWalletDescriptor) -> String {
        switch w.kind {
        case .software(let a):
            return "Software - account \(a)"
        case .hardware(_, let a, _):
            return "Hardware - account \(a)"
        }
    }
}
