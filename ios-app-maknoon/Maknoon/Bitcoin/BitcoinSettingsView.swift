// Per-network Electrum + mempool.space + CoinGecko + fiat settings.
// Lives as a NavigationLink from the existing SettingsView Form.

import SwiftUI

struct BitcoinSettingsView: View {
    @Environment(HolderStore.self) private var store

    @State private var selectedNetwork: BitcoinNetwork = .mainnet
    @State private var electrumURL: String = ""
    @State private var pinnedCertSHA: String = ""
    @State private var mempoolURL: String = ""
    @State private var explorerURL: String = ""
    @State private var fiatCode: String = "usd"

    var body: some View {
        Form {
            Section("Network for these settings") {
                Picker("Network", selection: $selectedNetwork) {
                    ForEach(BitcoinNetwork.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .onChange(of: selectedNetwork) { _, _ in loadFromStore() }
            }

            Section {
                TextField(selectedNetwork.defaultElectrumURL, text: $electrumURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Pinned cert SHA-256 (optional)", text: $pinnedCertSHA)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.caption, design: .monospaced))
                Button("Use public default") {
                    electrumURL = ""
                    pinnedCertSHA = ""
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("Electrum")
            } footer: {
                Text("Leave empty to use the default public endpoint at \(selectedNetwork.defaultElectrumURL).")
                    .font(.caption)
            }

            Section {
                TextField(selectedNetwork.defaultMempoolURL, text: $mempoolURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Use mempool.space default") {
                    mempoolURL = ""
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("Mempool / fee oracle")
            } footer: {
                Text("Where Maknoon pulls recommended fees and block projection. Defaults to mempool.space; a self-hosted Esplora-compatible instance works too.")
                    .font(.caption)
            }

            Section {
                TextField("Same as mempool URL (default)", text: $explorerURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Use mempool.space default") {
                    explorerURL = ""
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("Block explorer")
            } footer: {
                Text("HTML explorer that the Addresses + Transactions screens link out to. Leave blank to mirror the mempool URL above. Point at a local mempool.space install (e.g. http://192.168.1.10:8999) or any explorer that serves /address/<bech32> and /tx/<txid> pages.")
                    .font(.caption)
            }

            Section {
                Picker("Fiat currency", selection: $fiatCode) {
                    ForEach(commonFiats, id: \.self) {
                        Text($0.uppercased()).tag($0)
                    }
                }
                Button("Reset to default") {
                    fiatCode = "usd"
                    save()
                }
                .foregroundStyle(.blue)
            } header: {
                Text("Fiat currency")
            } footer: {
                // The spot-price + FX endpoints moved to a single global override
                // under Settings > Currency > Price data sources (#63); the
                // legacy per-Bitcoin CoinGecko field + BitcoinPriceCache are
                // retired. All chains now price through the shared AssetPriceCache.
                Text("The display currency and price sources are set globally under Settings, Currency.")
                    .font(.caption)
            }

            Section {
                Button("Save changes") { save() }
                Button(role: .destructive) {
                    store.bitcoinSettings.resetToDefaults()
                    loadFromStore()
                } label: {
                    Text("Reset all Bitcoin settings")
                }
            }
        }
        .navigationTitle("Bitcoin settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadFromStore() }
    }

    private let commonFiats: [String] = [
        "usd", "eur", "gbp", "jpy", "aed", "sar", "cny", "inr", "cad", "aud", "chf"
    ]

    // MARK: -- hardware wallets section
    //
    // Lists every registered Bitcoin-capable device (Ledger, Trezor)
    // and gives the user an "Add wallet from <device>" entry point.
    // Tapping the entry connects to the device, confirms its serial,
    // asks the user to open the Bitcoin app on the device, fetches
    // the BIP84 account xpub, builds a watch-only BDK wallet, and
    // adds it to BitcoinWalletStore tagged with the device id.

    private func loadFromStore() {
        let cfg = store.bitcoinSettings.electrumByNetwork[selectedNetwork]
            ?? BitcoinSettings.ElectrumConfig.empty
        electrumURL = cfg.url
        pinnedCertSHA = cfg.pinnedCertSHA256
        mempoolURL = store.bitcoinSettings.mempoolURLByNetwork[selectedNetwork] ?? ""
        explorerURL = store.bitcoinSettings.explorerURLByNetwork[selectedNetwork] ?? ""
        fiatCode = store.bitcoinSettings.fiatCode
    }

    private func save() {
        store.bitcoinSettings.setElectrum(
            BitcoinSettings.ElectrumConfig(
                url: electrumURL,
                pinnedCertSHA256: pinnedCertSHA
            ),
            for: selectedNetwork
        )
        store.bitcoinSettings.setMempool(mempoolURL, for: selectedNetwork)
        store.bitcoinSettings.setExplorerURL(explorerURL, for: selectedNetwork)
        store.bitcoinSettings.fiatCode = fiatCode
        store.bitcoinSettings.persist()
    }
}
