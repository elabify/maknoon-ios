// Networks settings hub. Each row drills into one chain's backend
// configuration. Bitcoin is live; Lightning / Ethereum / Solana are
// placeholders that explain the planned shape so users can see the
// roadmap from inside Settings.

import SwiftUI

struct NetworksDestination: View {
    @Environment(HolderStore.self) private var store

    // Global self-hosted WalletConnect relay (EVM-only today, but a single
    // relay across ALL networks) so it lives here under Networks, not inside
    // the Ethereum screen. Storage stays on ethereumSettings.
    @State private var wcRelayHost: String = ""
    @State private var advancedExpanded = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    BitcoinSettingsView()
                        .environment(store)
                } label: {
                    networkRow(
                        title: "Bitcoin",
                        subtitle: "Electrum, mempool.space, block explorer, fiat",
                        systemImage: "bitcoinsign.circle.fill",
                        tint: .orange,
                        live: true
                    )
                }
                NavigationLink {
                    LightningSettingsView()
                        .environment(store)
                } label: {
                    networkRow(
                        title: "Bitcoin Lightning",
                        subtitle: "LNDHub-compatible custodial accounts (manual configuration)",
                        systemImage: "bolt.fill",
                        tint: .yellow,
                        live: true
                    )
                }
                NavigationLink {
                    EthereumSettingsView()
                        .environment(store)
                } label: {
                    networkRow(
                        title: "Ethereum",
                        subtitle: "RPC, Etherscan-family API, explorer (mainnet plus EVM-compatible L2s)",
                        systemImage: "diamond.fill",
                        tint: .indigo,
                        live: true
                    )
                }
                NavigationLink {
                    SolanaSettingsView()
                        .environment(store)
                } label: {
                    networkRow(
                        title: "Solana",
                        subtitle: "RPC endpoint, Solana Explorer",
                        systemImage: "circle.hexagongrid.fill",
                        tint: .purple,
                        live: true
                    )
                }
                NavigationLink {
                    TronSettingsView()
                        .environment(store)
                } label: {
                    networkRow(
                        title: "Tron",
                        subtitle: "TronGrid endpoint, TronScan explorer, TRC-20 catalog",
                        systemImage: "diamond.fill",
                        tint: .red,
                        live: true
                    )
                }
            } header: {
                Text("Networks")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    Text("WalletConnect Relay")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("relay.walletconnect.com", text: $wcRelayHost)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { saveRelay() }
                    Button("Use default") {
                        wcRelayHost = ""
                        saveRelay()
                    }
                    .foregroundStyle(.blue)
                }
            }
        }
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { wcRelayHost = store.ethereumSettings.walletConnectRelayHost }
    }

    /// Normalize (strip scheme + trailing slashes) and persist the relay host.
    private func saveRelay() {
        var h = wcRelayHost.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        wcRelayHost = h
        store.ethereumSettings.walletConnectRelayHost = h
        store.ethereumSettings.persist()
    }

    private func networkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        live: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    if !live {
                        Text("Soon")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tertiary)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

