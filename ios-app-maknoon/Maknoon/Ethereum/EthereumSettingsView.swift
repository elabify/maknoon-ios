// Per-network Ethereum backend overrides: RPC URL, explorer URL +
// optional Etherscan-family API key. Mirrors BitcoinSettingsView.

import SwiftUI

struct EthereumSettingsView: View {
    @Environment(HolderStore.self) private var store

    @State private var selectedNetwork: EthereumNetwork = .mainnet
    @State private var rpcURL: String = ""
    @State private var explorerURL: String = ""
    @State private var explorerAPIURL: String = ""
    @State private var explorerAPIKey: String = ""
    @State private var ensRPCURL: String = ""
    @State private var catalogDraft: String = ""
    @State private var logoDraft: String = ""
    @State private var editingCustomNetwork: CustomEthereumNetwork?
    @State private var showAddCustomNetwork: Bool = false

    var body: some View {
        Form {
            Section("Chain for these settings") {
                Picker("Chain", selection: $selectedNetwork) {
                    Section {
                        ForEach(EthereumNetwork.displayOrdered.filter { !$0.isTestnet }, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Section("Testnets") {
                        ForEach(EthereumNetwork.displayOrdered.filter { $0.isTestnet }, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                .onChange(of: selectedNetwork) { _, _ in loadFromStore() }
                HStack {
                    Text("Chain ID").foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Text("\(selectedNetwork.chainId)").font(.caption.monospaced())
                }
            }

            Section {
                TextField(selectedNetwork.defaultRPCURL, text: $rpcURL)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(.caption, design: .monospaced))
                Button("Use default") {
                    rpcURL = ""
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("JSON-RPC endpoint")
            } footer: {
                Text("Leave empty to use the public default at \(selectedNetwork.defaultRPCURL). Hitting rate caps? Plug in an Alchemy / Infura / Ankr / QuickNode URL.")
                    .font(.caption)
            }

            Section {
                TextField(selectedNetwork.defaultExplorerURL, text: $explorerURL)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(.caption, design: .monospaced))
                Button("Use default") {
                    explorerURL = ""
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("Block explorer (HTML)")
            } footer: {
                Text("Used by 'open in explorer' affordances on addresses + transactions.")
                    .font(.caption)
            }

            Section {
                if let apiDefault = selectedNetwork.defaultExplorerAPIURL {
                    TextField(apiDefault, text: $explorerAPIURL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                    SecureField("API key (optional)", text: $explorerAPIKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                    Button("Use default URL") {
                        explorerAPIURL = ""
                        save()
                    }
                    .foregroundStyle(.blue)
                } else {
                    Text("This chain does not expose an Etherscan-style API. Maknoon falls back to RPC-only history fetching here, which is more limited.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Explorer API (tx history)")
            } footer: {
                Text("Most Etherscan-family endpoints serve unkeyed traffic at a low rate cap. Heavy users add a free API key from etherscan.io / arbiscan.io / etc.")
                    .font(.caption)
            }

            customNetworksSection

            ensSection

            tokenCatalogSection

            tokenLogoSection

            Section {
                Button("Save changes") { save() }
                Button(role: .destructive) {
                    store.ethereumSettings.resetToDefaults()
                    loadFromStore()
                } label: {
                    Text("Reset all Ethereum settings")
                }
            }
        }
        .navigationTitle("Ethereum settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadFromStore() }
        .sheet(isPresented: $showAddCustomNetwork) {
            CustomNetworkEditorSheet(initial: nil)
                .environment(store)
        }
        .sheet(item: $editingCustomNetwork) { net in
            CustomNetworkEditorSheet(initial: net)
                .environment(store)
        }
    }

    /// User-defined EVM networks. Listed alongside the built-in
    /// catalog in the wallet's network picker.
    @ViewBuilder
    private var customNetworksSection: some View {
        Section {
            ForEach(store.ethereumCustomNetworks.networks) { net in
                Button {
                    editingCustomNetwork = net
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .foregroundStyle(Color.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(net.name).font(.callout.weight(.semibold))
                            Text("chain \(net.chainId) · \(net.ticker)\(net.isTestnet ? " · testnet" : "")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.ethereumCustomNetworks.remove(id: net.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            Button {
                showAddCustomNetwork = true
            } label: {
                Label("Add a custom chain", systemImage: "plus.circle")
            }
        } header: {
            Text("Custom chains")
        } footer: {
            Text("Add an arbitrary EVM chain by pasting its chain ID, RPC URL, ticker, and explorer URL. Custom chains appear in the wallet's chain picker alongside built-ins, but auto-discover and the reputable-token list only cover built-in chains.")
                .font(.caption)
        }
    }

    /// ENS resolution endpoint. Decoupled from the per-network
    /// "RPC URL" block above because ENS lives on mainnet
    /// regardless of which network the user is currently sending
    /// on; we want the user to set this once.
    private var ensSection: some View {
        Section {
            TextField("Leave blank to use the mainnet RPC URL above", text: $ensRPCURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.caption, design: .monospaced))
        } header: {
            Text("ENS gateway")
        } footer: {
            Text("JSON-RPC endpoint Maknoon uses to look up ENS names like vitalik.eth. ENS lives on Ethereum mainnet only, so this URL should always point to a mainnet node. Run your own at home, or use any public mainnet RPC. Empty = reuse the Ethereum mainnet RPC URL from this screen.")
                .font(.caption)
        }
    }

    private var tokenCatalogSection: some View {
        Section {
            TextField("Catalog URL", text: $catalogDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .monospaced))
            Text("Default: \(EthereumTokenRegistry.defaultCatalogURL)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let last = store.ethereumTokenRegistry.lastFetched {
                Text("Last refreshed \(last, style: .relative) ago, \(store.ethereumTokenRegistry.totalEntries) verified tokens cached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet fetched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = store.ethereumTokenRegistry.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                let url = catalogDraft.isEmpty
                    ? EthereumTokenRegistry.defaultCatalogURL
                    : catalogDraft
                Task { await store.ethereumTokenRegistry.refresh(catalogURL: url) }
            } label: {
                HStack {
                    if store.ethereumTokenRegistry.refreshing {
                        ProgressView().controlSize(.small)
                    }
                    Label(store.ethereumTokenRegistry.refreshing ? "Refreshing…" : "Refresh now",
                          systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.ethereumTokenRegistry.refreshing)
        } header: {
            Text("Token catalog")
        } footer: {
            Text("Maknoon does not ship a built-in token list. Verified token metadata is fetched from the configured catalog at runtime, cached locally, and refreshed weekly. Override the URL to point at a self-hosted mirror or a frozen snapshot. Contracts not in the catalog will surface as Unknown rather than auto-installing, to keep airdrop spam off your dashboard.")
                .font(.caption)
        }
    }

    private var tokenLogoSection: some View {
        Section {
            TextField("Logo template", text: $logoDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .monospaced))
            Text("Default: \(EthereumSettings.defaultLogoTemplate)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Token logos")
        } footer: {
            Text("Per-token URL substitutes `{chain}` (the network's Trust Wallet slug, e.g. ethereum, polygon, arbitrum) and `{address}` (checksummed contract). Default points at Trust Wallet's assets repo. Tokens without a logo fall back to a circle showing the first four characters of the symbol.")
                .font(.caption)
        }
    }

    private func loadFromStore() {
        rpcURL = store.ethereumSettings.rpcURLByNetwork[selectedNetwork] ?? ""
        explorerURL = store.ethereumSettings.explorerURLByNetwork[selectedNetwork] ?? ""
        explorerAPIURL = store.ethereumSettings.explorerAPIURLByNetwork[selectedNetwork] ?? ""
        explorerAPIKey = store.ethereumSettings.explorerAPIKeyByNetwork[selectedNetwork] ?? ""
        ensRPCURL = store.ethereumSettings.ensRPCURL
        let savedCatalog = store.ethereumSettings.tokenCatalogURL
        catalogDraft = savedCatalog == EthereumTokenRegistry.defaultCatalogURL ? "" : savedCatalog
        let savedLogo = store.ethereumSettings.logoTemplate
        logoDraft = savedLogo == EthereumSettings.defaultLogoTemplate ? "" : savedLogo
    }

    private func save() {
        store.ethereumSettings.setRPC(rpcURL, for: selectedNetwork)
        store.ethereumSettings.setExplorer(explorerURL, for: selectedNetwork)
        store.ethereumSettings.setExplorerAPI(explorerAPIURL, key: explorerAPIKey, for: selectedNetwork)
        store.ethereumSettings.ensRPCURL = ensRPCURL.trimmingCharacters(in: .whitespaces)
        store.ethereumSettings.setTokenCatalogURL(catalogDraft)
        store.ethereumSettings.setLogoTemplate(logoDraft)
        store.ethereumSettings.persist()
    }
}
