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
        .sheet(item: $renameTarget) { target in
            renameSheet(target: target)
                .environment(store)
        }
    }

    private func walletRow(_ w: SolanaWalletDescriptor) -> some View {
        Button {
            store.solanaWalletStore.setActive(w.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.label).font(.headline)
                    Text(subtitle(for: w)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.solanaWalletStore.activeWallet?.id == w.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        // allowsFullSwipe: false prevents a continued right-swipe from
        // auto-firing Remove. The user has to tap the exposed Remove
        // button explicitly.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.solanaWalletStore.remove(id: w.id)
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
    private func renameSheet(target: SolanaWalletDescriptor) -> some View {
        NavigationStack {
            Form {
                Section("Wallet label") {
                    TextField("e.g. Daily", text: $renameDraft)
                }
                Section {
                    Button("Save") {
                        if !renameDraft.isEmpty {
                            store.solanaWalletStore.rename(id: target.id, to: renameDraft)
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

    private func subtitle(for w: SolanaWalletDescriptor) -> String {
        switch w.kind {
        case .software(let a):
            return "Software - account \(a)"
        case .hardware(_, let a, _):
            return "Hardware - account \(a)"
        }
    }
}
