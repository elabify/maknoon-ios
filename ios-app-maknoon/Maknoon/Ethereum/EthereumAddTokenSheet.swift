// Add Custom Token sheet: paste a contract address, the app reads
// `symbol()` and `decimals()` on-chain, and the entry persists to
// EthereumTokenStore. Used from the EthereumWalletView's tokens
// section "+" affordance.

import SwiftUI

struct EthereumAddTokenSheet: View {
    let wallet: EthereumWallet
    let network: EthereumNetwork
    let onAdded: () -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var contract: String = ""
    @State private var probedSymbol: String?
    @State private var probedDecimals: Int?
    @State private var probedName: String = ""
    @State private var loading: Bool = false
    @State private var lastError: String?
    /// Bumped on every contract edit so the previous in-flight
    /// probe (if any) notices and exits before clobbering newer
    /// state with stale data.
    @State private var probeEpoch: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Token contract") {
                    HStack {
                        TextField("0x… (20-byte hex address)", text: $contract, axis: .vertical)
                            .font(.system(.callout, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(2...4)
                        Button {
                            if let s = UIPasteboard.general.string { contract = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                    }
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading symbol, name, decimals on chain…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if probedSymbol == nil && isValidAddress(contract) && lastError != nil {
                        Button {
                            Task { await probe() }
                        } label: {
                            Label("Retry probe", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .onChange(of: contract) { _, _ in scheduleProbe() }

                if let sym = probedSymbol, let dec = probedDecimals {
                    Section("Detected") {
                        LabeledContent("Symbol", value: sym)
                        LabeledContent("Decimals", value: "\(dec)")
                        TextField("Display name (optional)", text: $probedName)
                    }
                }

                if let lastError {
                    Section { Text(lastError).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Add token").frame(maxWidth: .infinity)
                    }
                    .disabled(probedSymbol == nil || probedDecimals == nil)
                } footer: {
                    Text("Contracts that don't implement ERC-20's `symbol()` / `decimals()` can't be added. Make sure you're on \(network.displayName) and that the contract is the canonical token, not a wrapper or proxy you don't trust.")
                        .font(.caption)
                }
            }
            .navigationTitle("Add token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func isValidAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("0x"), t.count == 42 else { return false }
        return t.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    @MainActor
    private func probe() async {
        loading = true
        lastError = nil
        probedSymbol = nil
        probedDecimals = nil
        let rpcURL = store.ethereumSettings.rpcURL(for: network)
        do {
            let meta = try await wallet.probeTokenMetadata(contract: contract, rpcURL: rpcURL)
            guard let meta else {
                lastError = "Contract did not respond to symbol() or decimals(). Check the address and network, or this contract may not be a standard ERC-20."
                loading = false
                return
            }
            probedSymbol = meta.symbol
            probedDecimals = meta.decimals
            if probedName.isEmpty { probedName = meta.symbol }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Probe failed: \(error)"
        }
        loading = false
    }

    /// Auto-fire the probe on every contract edit with a debounce
    /// so quick typing doesn't issue dozens of RPC calls. The
    /// epoch counter lets a previous in-flight probe notice it has
    /// been superseded and exit before clobbering the new state.
    @MainActor
    private func scheduleProbe() {
        probeEpoch += 1
        let myEpoch = probeEpoch
        probedSymbol = nil
        probedDecimals = nil
        lastError = nil
        guard isValidAddress(contract) else {
            loading = false
            return
        }
        let contractAtEntry = contract.trimmingCharacters(in: .whitespaces)
        loading = true
        let rpcURL = store.ethereumSettings.rpcURL(for: network)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard myEpoch == probeEpoch else { return }
            let meta = await EthereumTokenLookup.fetch(
                contract: contractAtEntry,
                rpcURL: rpcURL
            )
            guard myEpoch == probeEpoch else { return }
            loading = false
            if let meta {
                probedSymbol = meta.symbol
                probedDecimals = meta.decimals
                if probedName.isEmpty { probedName = meta.name }
            } else {
                lastError = "Contract did not respond to symbol() or decimals() on \(network.displayName). Check the network and address, or use Retry probe."
            }
        }
    }

    private func save() {
        guard let sym = probedSymbol, let dec = probedDecimals else { return }
        let token = EthereumToken(
            network: network,
            contractAddress: contract.trimmingCharacters(in: .whitespaces),
            symbol: sym,
            name: probedName.isEmpty ? sym : probedName,
            decimals: dec,
            curated: false
        )
        store.ethereumTokenStore.add(token)
        onAdded()
        dismiss()
    }
}
