// Settings → Address book. List grouped by network; swipe to
// remove; tap to edit. New entries via the "+" toolbar item.

import SwiftUI

struct AddressBookView: View {
    @Environment(HolderStore.self) private var store

    @State private var editTarget: AddressBookEntry?
    @State private var showAdd: Bool = false

    var body: some View {
        Form {
            if store.addressBook.entries.isEmpty {
                Section {
                    Text("No contacts yet. Tap + to add one.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(AddressBookNetwork.allCases, id: \.self) { net in
                    let entries = store.addressBook.entries(for: net)
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries) { entry in
                                let readOnly = entry.source.isReadOnly
                                let row = HStack(spacing: 12) {
                                    Image(systemName: net.systemImage)
                                        .font(.title3)
                                        .foregroundStyle(networkColor(net))
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(entry.name.isEmpty ? shortAddress(entry.address) : entry.name)
                                                .font(.callout.weight(.semibold))
                                            if readOnly {
                                                Image(systemName: "lock.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        if !entry.name.isEmpty {
                                            Text(shortAddress(entry.address))
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !readOnly {
                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if readOnly {
                                    // System (wallet-mirror) entries are
                                    // managed by the wallet store; the
                                    // user can't edit or delete them here.
                                    row
                                } else {
                                    Button {
                                        editTarget = entry
                                    } label: { row }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            store.addressBook.remove(id: entry.id)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text(net.displayName)
                        }
                    }
                }
            }
        }
        .navigationTitle("Address book")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add contact")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddressBookEntrySheet(initial: nil)
                .environment(store)
        }
        .sheet(item: $editTarget) { entry in
            AddressBookEntrySheet(initial: entry)
                .environment(store)
        }
    }

    private func networkColor(_ net: AddressBookNetwork) -> Color {
        switch net.tint {
        case "orange":   return .orange
        case "indigo":   return .indigo
        case "yellow":   return .yellow
        case "purple":   return .purple
        case "red":      return .red
        default:         return .accentColor
        }
    }

    private func shortAddress(_ s: String) -> String {
        if s.count <= 24 { return s }
        return "\(s.prefix(10))…\(s.suffix(8))"
    }
}

/// Add / edit a single address book entry. Used by both
/// `AddressBookView.+` (new) and tap-on-row (edit).
struct AddressBookEntrySheet: View {
    let initial: AddressBookEntry?
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var address: String = ""
    @State private var network: AddressBookNetwork = .bitcoin

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Network", selection: $network) {
                        ForEach(AddressBookNetwork.allCases, id: \.self) { net in
                            Label(net.displayName, systemImage: net.systemImage).tag(net)
                        }
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Pick the chain this contact lives on. Different chains have different address formats.")
                        .font(.caption)
                }
                Section {
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("Name")
                }
                Section {
                    HStack {
                        TextField(addressPlaceholder, text: $address, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2...5)
                        Button {
                            if let s = UIPasteboard.general.string {
                                address = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text(addressFooter).font(.caption)
                }
                Section {
                    Button(initial == nil ? "Save contact" : "Save changes") {
                        save()
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(initial == nil ? "New contact" : "Edit contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let initial {
                    name = initial.name
                    address = initial.address
                    network = initial.network
                }
            }
        }
    }

    private var addressPlaceholder: String {
        switch network {
        case .bitcoin:   return "bc1q… / bc1p… / 3… / 1…"
        case .ethereum:  return "0x… or vitalik.eth"
        case .lightning: return "user@domain.com (LNURL address)"
        case .solana:    return "Base58 32-byte address"
        case .tron:      return "T… (base58check)"
        }
    }

    private var addressFooter: String {
        switch network {
        case .bitcoin:
            return "Any valid Bitcoin address. Works on mainnet, testnet3, and signet, the address itself encodes which."
        case .ethereum:
            return "Either a 0x hex address or an ENS name like vitalik.eth. ENS names are resolved on demand each time you send, using the ENS gateway configured in Ethereum settings. EVM addresses are chain-agnostic and work on Mainnet, Sepolia, every L2, and any custom chain you've added."
        case .lightning:
            return "Use LUD-16 lightning addresses (e.g. you@walletofsatoshi.com). BOLT11 invoices aren't stored here because they're single-use."
        case .solana:
            return "Solana addresses are base58 32-byte Ed25519 public keys. Cluster-agnostic: the same address works on Mainnet, Devnet, and Testnet."
        case .tron:
            return "Tron addresses are base58check, prefixed with T. Network-agnostic: works on Mainnet, Shasta, and Nile."
        }
    }

    private func save() {
        let trimmedAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let entry = AddressBookEntry(
            id: initial?.id ?? UUID(),
            name: trimmedName,
            address: trimmedAddr,
            network: network,
            createdAt: initial?.createdAt ?? Date()
        )
        if initial != nil {
            store.addressBook.update(entry)
        } else {
            store.addressBook.add(entry)
        }
        dismiss()
    }
}
