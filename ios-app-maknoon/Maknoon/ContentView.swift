import SwiftUI

struct ContentView: View {
    @Environment(HolderStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        // Re-tapping the already-selected tab pops that tab's stack back to
        // root. SwiftUI's TabView does not fire onChange when the selection
        // is unchanged, so we detect the re-tap inside the selection binding's
        // setter and clear the matching navigation path.
        TabView(selection: Binding(
            get: { store.selectedTab },
            set: { newTab in
                if newTab == store.selectedTab {
                    switch newTab {
                    case .identity: store.identityNavigationPath = NavigationPath()
                    case .wallet:   store.walletNavigationPath = NavigationPath()
                    case .apps:     store.appsNavigationPath = NavigationPath()
                    }
                }
                store.selectedTab = newTab
            }
        )) {
            NavigationStack(path: $bindableStore.identityNavigationPath) {
                IdentityView()
            }
                .tabItem { Label("Identity", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(HolderStore.Tab.identity)

            NavigationStack(path: $bindableStore.walletNavigationPath) {
                WalletView()
                    // Programmatic deep-link into a chain's wallet (e.g. after a
                    // Verify & Pay) via walletNavigationPath.append(WalletChain).
                    .navigationDestination(for: WalletChain.self) { chain in
                        switch chain {
                        case .bitcoin:   BitcoinWalletView().environment(store)
                        case .lightning: LightningWalletView().environment(store)
                        case .ethereum:  EthereumWalletView().environment(store)
                        case .solana:    SolanaWalletView().environment(store)
                        case .tron:      TronWalletView().environment(store)
                        }
                    }
            }
                .tabItem { Label("Wallet", systemImage: "creditcard") }
                .tag(HolderStore.Tab.wallet)

            NavigationStack(path: $bindableStore.appsNavigationPath) { AppsView() }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(HolderStore.Tab.apps)
        }
        .tint(.purple)
        // Hardware-unlock sheet hosted at the root so any tab can
        // present it via `store.showHardwareUnlock = true`. The
        // sandwich loads inside the sheet's success path and the
        // sheet auto-dismisses (its own logic clears the binding).
        .sheet(isPresented: $bindableStore.showHardwareUnlock) {
            if !store.pendingHardwareUnlock.isEmpty {
                HardwareUnlockView(enrollments: store.pendingHardwareUnlock)
                    .environment(store)
            } else {
                // Defensive: if some race calls show=true when there's
                // nothing to unlock, render an empty dismissable view
                // rather than crashing.
                NavigationStack {
                    Form {
                        Text("Nothing to unlock, your identity is already loaded.")
                    }
                    .navigationTitle("Identity")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(HolderStore())
        .preferredColorScheme(.dark)
}
