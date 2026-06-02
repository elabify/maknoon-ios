// Tron per-network backend settings. Mirrors SolanaSettingsView:
// pick a network, override its TronGrid endpoint + block-explorer URL
// if you want to point at your own infrastructure, configure the
// TRC-20 catalog URL.

import SwiftUI

struct TronSettingsView: View {
    @Environment(HolderStore.self) private var store
    @State private var network: TronNetwork = .mainnet
    @State private var rpcDraft: String = ""
    @State private var explorerDraft: String = ""
    @State private var catalogDraft: String = ""
    @State private var logoDraft: String = ""
    @State private var saved: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Network", selection: $network) {
                    ForEach(TronNetwork.allCases, id: \.self) { n in
                        Text(n.displayName).tag(n)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Network")
            } footer: {
                Text("Each Tron network has its own TronGrid endpoint and TronScan explorer. Wallets are address-compatible across networks; this picker only changes which set of overrides you're editing.")
                    .font(.caption)
            }

            Section {
                TextField("TronGrid URL", text: $rpcDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(network.defaultRpcURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("RPC endpoint")
            } footer: {
                Text("Leave blank to use the default. The public TronGrid endpoint is rate-limited; for production use, sign up for a TronGrid Pro API key and point this at it (or run your own java-tron node).")
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
                Text("Used by the 'View on explorer' link after a send. Leave blank for the TronScan default.")
                    .font(.caption)
            }

            Section {
                TextField("Catalog URL", text: $catalogDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(TronTokenCatalog.defaultCatalogURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = store.tronTokenCatalog.lastFetched {
                    Text("Last refreshed \(last, style: .relative) ago, \(store.tronTokenCatalog.entriesByContract.count) verified tokens cached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet fetched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = store.tronTokenCatalog.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    let url = catalogDraft.isEmpty
                        ? TronTokenCatalog.defaultCatalogURL
                        : catalogDraft
                    Task { await store.tronTokenCatalog.refresh(catalogURL: url) }
                } label: {
                    HStack {
                        if store.tronTokenCatalog.refreshing {
                            ProgressView().controlSize(.small)
                        }
                        Label(store.tronTokenCatalog.refreshing ? "Refreshing…" : "Refresh now",
                              systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.tronTokenCatalog.refreshing)
            } header: {
                Text("Token catalog")
            } footer: {
                Text("Maknoon does not ship a built-in token list. Verified token metadata is fetched from the configured catalog at runtime, cached locally, and refreshed weekly. Override the URL to point at a self-hosted mirror or a frozen snapshot. Contracts not in the catalog will surface as Unknown rather than auto-installing, to keep airdrop spam off your dashboard.")
                    .font(.caption)
            }

            Section {
                TextField("Logo base URL", text: $logoDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .monospaced))
                Text("Default: \(TronSettings.defaultLogoBaseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Token logos")
            } footer: {
                Text("Per-token logo URL is built as `\\(base)/\\(contract)/logo.png`. Default points at Trust Wallet's assets repo. Tokens without a logo fall back to a circle showing the first four characters of the symbol.")
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
        .navigationTitle("Tron")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDrafts() }
        .onChange(of: network) { _, _ in loadDrafts() }
    }

    private func loadDrafts() {
        rpcDraft = store.tronSettings.rpcOverridesByNetwork[network.rawValue] ?? ""
        explorerDraft = store.tronSettings.explorerOverridesByNetwork[network.rawValue] ?? ""
        let savedCatalog = store.tronSettings.tokenCatalogURL
        catalogDraft = savedCatalog == TronTokenCatalog.defaultCatalogURL ? "" : savedCatalog
        let savedLogo = store.tronSettings.logoBaseURL
        logoDraft = savedLogo == TronSettings.defaultLogoBaseURL ? "" : savedLogo
        saved = false
    }

    private func save() {
        store.tronSettings.setRPCOverride(rpcDraft.isEmpty ? nil : rpcDraft, for: network)
        store.tronSettings.setExplorerOverride(explorerDraft.isEmpty ? nil : explorerDraft, for: network)
        store.tronSettings.setTokenCatalogURL(catalogDraft)
        store.tronSettings.setLogoBaseURL(logoDraft)
        saved = true
    }
}
