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
        store.bitcoinSettings.persist()
    }
}
