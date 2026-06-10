// Network picker for the Ethereum wallet. Replaces the old `Menu`, which
// always opened at the top with no way to reveal the current selection
// (a real problem once the list grew past a screen — picking a testnet low
// in the list, then reopening, started back at the top). A List inside a
// ScrollViewReader lets us scroll to and highlight the currently-selected
// chain on open.

import SwiftUI

struct EthereumNetworkPickerSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let walletId: UUID
    let selected: EthereumNetworkID

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section("Mainnets") {
                        ForEach(EthereumNetwork.displayOrdered.filter { !$0.isTestnet }, id: \.self) { net in
                            row(net.displayName, id: .builtin(net)) {
                                store.ethereumWalletStore.setCurrentNetwork(net, for: walletId)
                            }
                        }
                    }
                    Section("Testnets") {
                        ForEach(EthereumNetwork.displayOrdered.filter { $0.isTestnet }, id: \.self) { net in
                            row(net.displayName, id: .builtin(net)) {
                                store.ethereumWalletStore.setCurrentNetwork(net, for: walletId)
                            }
                        }
                    }
                    if !store.ethereumCustomNetworks.networks.isEmpty {
                        Section("Custom") {
                            ForEach(store.ethereumCustomNetworks.networks) { custom in
                                row(custom.name, id: .custom(custom.id)) {
                                    store.ethereumWalletStore.setCurrentNetworkID(.custom(custom.id), for: walletId)
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    // Defer one runloop so the List has laid out before we
                    // scroll, otherwise scrollTo can no-op on first present.
                    DispatchQueue.main.async {
                        proxy.scrollTo(selected.stableId, anchor: .center)
                    }
                }
            }
            .navigationTitle("Select network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, id: EthereumNetworkID, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if id == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .id(id.stableId)
    }
}
