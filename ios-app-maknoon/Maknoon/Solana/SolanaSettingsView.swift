// Solana per-network backend settings. Mirrors BitcoinSettingsView at
// a smaller scale: pick a network, override its RPC endpoint and
// block-explorer URL if you want to point at your own infrastructure.
// Defaults are public endpoints suitable for testing; mainnet usage
// should swap in a paid endpoint to avoid public-RPC rate limits.

import SwiftUI

struct SolanaSettingsView: View {
    @Environment(HolderStore.self) private var store
    @State private var network: SolanaNetwork = .mainnet
    @State private var rpcDraft: String = ""
    @State private var explorerDraft: String = ""
    @State private var catalogDraft: String = ""
    @State private var logoDraft: String = ""
    @State private var saved: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Network", selection: $network) {
                    ForEach(SolanaNetwork.allCases, id: \.self) { n in
                        Text(n.displayName).tag(n)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Network")
            } footer: {
                Text("Each network has its own RPC and explorer. Wallets are bound to the network they were created on; this picker only changes which set of overrides you're editing.")
                    .font(.caption)
            }

            Section {
                TextField("RPC URL", text: $rpcDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(network.defaultRpcURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("RPC endpoint")
            } footer: {
                Text("Leave blank to use the default. Public defaults are rate-limited; for mainnet, point at a Helius / QuickNode / Triton / Alchemy endpoint or your own validator's JSON-RPC.")
                    .font(.caption)
            }

            Section {
                TextField("Explorer URL", text: $explorerDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(network.defaultExplorerURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Block explorer")
            } footer: {
                Text("Used by the 'View on explorer' link after a send. Leave blank for the Solana Explorer default.")
                    .font(.caption)
            }

            Section {
                TextField("Catalog URL", text: $catalogDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(SolanaTokenCatalog.defaultCatalogURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = store.solanaTokenCatalog.lastFetched {
                    Text("Last refreshed \(last, style: .relative) ago, \(store.solanaTokenCatalog.entriesByMint.count) verified tokens cached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet fetched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = store.solanaTokenCatalog.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    let url = catalogDraft.isEmpty
                        ? SolanaTokenCatalog.defaultCatalogURL
                        : catalogDraft
                    Task { await store.solanaTokenCatalog.refresh(catalogURL: url) }
                } label: {
                    HStack {
                        if store.solanaTokenCatalog.refreshing {
                            ProgressView().controlSize(.small)
                        }
                        Label(store.solanaTokenCatalog.refreshing ? "Refreshing…" : "Refresh now",
                              systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.solanaTokenCatalog.refreshing)
            } header: {
                Text("Token catalog")
            } footer: {
                Text("Maknoon does not ship a built-in token list. Verified token metadata is fetched from the configured catalog at runtime, cached locally, and refreshed weekly. Override the URL to point at a self-hosted mirror or a frozen snapshot. Mints not in the catalog will surface as Unknown rather than auto-installing, to keep airdrop spam off your dashboard.")
                    .font(.caption)
            }

            Section {
                TextField("Logo base URL", text: $logoDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(SolanaSettings.defaultLogoBaseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Token logos")
            } footer: {
                Text("Per-token logo URL is built as `\\(base)/\\(mint)/logo.png`. Default points at Trust Wallet's assets repo. Tokens without a logo fall back to a circle showing the first four characters of the symbol.")
                    .font(.caption)
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                }
            }
        }
        .navigationTitle("Solana")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDrafts() }
        .onChange(of: network) { _, _ in loadDrafts() }
    }

    private func loadDrafts() {
        rpcDraft = store.solanaSettings.rpcOverridesByNetwork[network.rawValue] ?? ""
        explorerDraft = store.solanaSettings.explorerOverridesByNetwork[network.rawValue] ?? ""
        let savedCatalog = store.solanaSettings.tokenCatalogURL
        catalogDraft = savedCatalog == SolanaTokenCatalog.defaultCatalogURL ? "" : savedCatalog
        let savedLogo = store.solanaSettings.logoBaseURL
        logoDraft = savedLogo == SolanaSettings.defaultLogoBaseURL ? "" : savedLogo
        saved = false
    }

    private func save() {
        store.solanaSettings.setRPCOverride(rpcDraft.isEmpty ? nil : rpcDraft, for: network)
        store.solanaSettings.setExplorerOverride(explorerDraft.isEmpty ? nil : explorerDraft, for: network)
        store.solanaSettings.setTokenCatalogURL(catalogDraft)
        store.solanaSettings.setLogoBaseURL(logoDraft)
        saved = true
    }
}
