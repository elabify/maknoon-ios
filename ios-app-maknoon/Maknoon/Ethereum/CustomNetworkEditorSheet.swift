// Add / edit a user-defined EVM network. Reached from Settings →
// Networks → Ethereum → Custom networks. Save validates that the
// chain ID is non-zero, the RPC URL is parseable, and the ticker
// isn't empty.

import SwiftUI

struct CustomNetworkEditorSheet: View {
    let initial: CustomEthereumNetwork?
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var chainIdString: String = ""
    @State private var ticker: String = ""
    @State private var rpcURL: String = ""
    @State private var explorerURL: String = ""
    @State private var explorerAPIURL: String = ""
    @State private var explorerAPIKey: String = ""
    @State private var isTestnet: Bool = false
    @State private var error: String?

    private var isEdit: Bool { initial != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chain") {
                    TextField("Name (e.g. Aurora Mainnet)", text: $name)
                    HStack {
                        Text("Chain ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("1313161554", text: $chainIdString)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    HStack {
                        Text("Ticker").foregroundStyle(.secondary)
                        Spacer()
                        TextField("ETH", text: $ticker)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    Toggle("Testnet", isOn: $isTestnet)
                }

                Section {
                    TextField("https://mainnet.aurora.dev", text: $rpcURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                } header: {
                    Text("JSON-RPC endpoint")
                }

                Section {
                    TextField("https://aurorascan.dev", text: $explorerURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                } header: {
                    Text("Block explorer (HTML)")
                } footer: {
                    Text("Used by 'View on explorer' links on addresses and transactions.")
                        .font(.caption)
                }

                Section {
                    TextField("https://api.aurorascan.dev/api (optional)", text: $explorerAPIURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.caption, design: .monospaced))
                    SecureField("API key (optional)", text: $explorerAPIKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Explorer API (tx history)")
                } footer: {
                    Text("If your chain has an Etherscan-style or Blockscout API, paste the base URL here. Leave blank to fall back to RPC-only history.")
                        .font(.caption)
                }

                if let err = error {
                    Section { Text(err).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    Button(isEdit ? "Save changes" : "Add chain") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(isEdit ? "Edit chain" : "Add custom chain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let initial {
                    name = initial.name
                    chainIdString = "\(initial.chainId)"
                    ticker = initial.ticker
                    rpcURL = initial.rpcURL
                    explorerURL = initial.explorerURL
                    explorerAPIURL = initial.explorerAPIURL ?? ""
                    explorerAPIKey = initial.explorerAPIKey ?? ""
                    isTestnet = initial.isTestnet
                }
            }
        }
    }

    private var canSave: Bool {
        guard let id = UInt64(chainIdString), id > 0 else { return false }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !ticker.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard URL(string: rpcURL) != nil, !rpcURL.isEmpty else { return false }
        return true
    }

    private func save() {
        guard let chainId = UInt64(chainIdString), chainId > 0 else {
            error = "Chain ID must be a positive integer."
            return
        }
        guard URL(string: rpcURL) != nil else {
            error = "RPC URL is not a valid URL."
            return
        }
        let network = CustomEthereumNetwork(
            id: initial?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            chainId: chainId,
            ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
            rpcURL: rpcURL.trimmingCharacters(in: .whitespaces),
            explorerURL: explorerURL.trimmingCharacters(in: .whitespaces),
            explorerAPIURL: explorerAPIURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : explorerAPIURL,
            explorerAPIKey: explorerAPIKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : explorerAPIKey,
            isTestnet: isTestnet
        )
        if isEdit {
            store.ethereumCustomNetworks.update(network)
        } else {
            store.ethereumCustomNetworks.add(network)
        }
        dismiss()
    }
}
