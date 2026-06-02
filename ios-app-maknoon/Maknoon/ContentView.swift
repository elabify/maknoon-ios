import SwiftUI

struct ContentView: View {
    @Environment(HolderStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        TabView(selection: $bindableStore.selectedTab) {
            NavigationStack(path: $bindableStore.identityNavigationPath) {
                IdentityView()
            }
                .tabItem { Label("Identity", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(HolderStore.Tab.identity)

            NavigationStack { WalletView() }
                .tabItem { Label("Wallet", systemImage: "creditcard") }
                .tag(HolderStore.Tab.wallet)

            NavigationStack { AppsView() }
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
                        Text("Nothing to unlock — your identity is already loaded.")
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
