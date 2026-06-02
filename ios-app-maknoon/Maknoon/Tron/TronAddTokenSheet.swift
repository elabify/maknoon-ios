// Add a TRC-20 token to the dashboard. Lookup order: cached
// catalog → manual entry. Mirrors `SolanaAddTokenSheet`.

import SwiftUI

struct TronAddTokenSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let network: TronNetwork
    let prefilledContract: String?
    let onAdded: () -> Void

    @State private var contractInput: String = ""
    @State private var symbolInput: String = ""
    @State private var nameInput: String = ""
    @State private var decimalsInput: String = ""
    @State private var catalogHit: TronTokenCatalog.Entry?
    @State private var error: String?
    /// Result of the on-chain auto-lookup via `name()`, `symbol()`,
    /// `decimals()`. Populated when the contract responds to all
    /// three; left nil when the contract is a non-TRC-20 or
    /// unreachable, in which case the user falls through to manual.
    @State private var probedMetadata: TRC20Metadata?
    /// Whether an on-chain lookup is in flight. The chain lookup is
    /// debounced so quick edits don't fire dozens of requests; this
    /// flag is just for the UI spinner.
    @State private var probing: Bool = false
    /// Debounce token. Bumped on every contract change so a stale
    /// in-flight lookup notices and exits before mutating state.
    @State private var probeEpoch: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                contractSection
                if probing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading symbol, name, decimals on chain…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let hit = catalogHit {
                    verifiedSection(hit)
                } else if let meta = probedMetadata {
                    detectedSection(meta)
                } else if !trimmedContract.isEmpty && parsedContractIsValid && !probing {
                    customSection
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(action: addToken) {
                        Label("Add token", systemImage: "plus.circle.fill")
                    }
                    .disabled(!canAdd)
                } footer: {
                    Text("Verified tokens use the metadata from your configured catalog (TronScan verified list by default). Custom additions are your responsibility, double-check the contract address against a trusted source before sending value to it.")
                        .font(.caption)
                }
            }
            .navigationTitle("Add TRC-20 token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let c = prefilledContract { contractInput = c }
                refreshCatalogHit()
                scheduleProbeIfNeeded()
            }
            .onChange(of: contractInput) { _, _ in
                refreshCatalogHit()
                scheduleProbeIfNeeded()
            }
        }
    }

    private var contractSection: some View {
        Section {
            TextField("Contract address (T-prefixed)", text: $contractInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .monospaced))
            Text("Network: \(network.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Contract")
        } footer: {
            if network != .mainnet {
                Text("\(network.displayName) is a Tron testnet. The catalog covers mainnet contracts only, so testnet tokens always land in the custom path. Get the testnet-specific contract address from \(network.displayName)'s explorer (mainnet USDT / USDC contracts do not exist on \(network.displayName)).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func verifiedSection(_ hit: TronTokenCatalog.Entry) -> some View {
        Section {
            HStack {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            LabeledContent("Symbol", value: hit.symbol)
            LabeledContent("Name", value: hit.name)
            LabeledContent("Decimals", value: "\(hit.decimals)")
        } header: {
            Text("Catalog entry")
        } footer: {
            Text("Metadata loaded from the configured token catalog.")
                .font(.caption)
        }
    }

    /// Section shown when the on-chain probe succeeded but the
    /// catalog had no entry. The user can edit each value before
    /// saving; defaults come from the contract's own `name()`,
    /// `symbol()`, `decimals()` returns.
    private func detectedSection(_ meta: TRC20Metadata) -> some View {
        Section {
            HStack {
                Label("Detected on chain", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            TextField("Symbol", text: $symbolInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
            TextField("Name", text: $nameInput)
            TextField("Decimals", text: $decimalsInput)
                .keyboardType(.numberPad)
        } header: {
            Text("Token details")
        } footer: {
            Text("Symbol \"\(meta.symbol)\", name \"\(meta.name)\", \(meta.decimals) decimals read from the contract. You can edit before adding if any look wrong.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var customSection: some View {
        Section {
            TextField("Symbol (e.g. USDT)", text: $symbolInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
            TextField("Name", text: $nameInput)
            TextField("Decimals (typically 6 or 18)", text: $decimalsInput)
                .keyboardType(.numberPad)
        } header: {
            HStack {
                Label("Not in catalog", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
            }
        } footer: {
            Text("This contract isn't in the verified catalog. Enter metadata manually only after confirming the contract address against a trusted source. Decimals are particularly easy to misread, getting them wrong will make balances and amounts display incorrectly.")
                .font(.caption)
        }
    }

    private var trimmedContract: String {
        contractInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedContractIsValid: Bool {
        TronDescriptors.parseAddress(trimmedContract) != nil
    }

    private var canAdd: Bool {
        guard parsedContractIsValid else { return false }
        if catalogHit != nil { return true }
        guard !symbolInput.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let d = UInt8(decimalsInput), d <= 18 else { return false }
        return true
    }

    private func refreshCatalogHit() {
        guard parsedContractIsValid else { catalogHit = nil; return }
        catalogHit = store.tronTokenCatalog.find(contract: trimmedContract)
    }

    /// Fire an on-chain probe with a small debounce so quick typing
    /// doesn't issue dozens of requests. The probe reads name(),
    /// symbol(), decimals() in parallel; on success the form auto-
    /// fills with the contract's own declared metadata. On miss the
    /// user falls through to the manual entry section.
    @MainActor
    private func scheduleProbeIfNeeded() {
        probeEpoch += 1
        let myEpoch = probeEpoch
        // Drop a prior probed-state when the contract changes so a
        // stale "Detected" section doesn't linger over the new
        // address.
        probedMetadata = nil
        guard parsedContractIsValid, catalogHit == nil else {
            probing = false
            return
        }
        let contractAtEntry = trimmedContract
        probing = true
        let rpcURL = store.tronSettings.rpcURL(for: network)
        Task { @MainActor in
            // Debounce window: ignore intermediate keystrokes.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard myEpoch == probeEpoch else { return }
            let meta = await TronTokenLookup.fetch(
                contract: contractAtEntry,
                rpcURL: rpcURL
            )
            guard myEpoch == probeEpoch else { return }
            probing = false
            if let meta {
                probedMetadata = meta
                if symbolInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    symbolInput = meta.symbol
                }
                if nameInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    nameInput = meta.name
                }
                if decimalsInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    decimalsInput = "\(meta.decimals)"
                }
            }
        }
    }

    private func addToken() {
        guard parsedContractIsValid else {
            error = "Contract address is not valid."
            return
        }
        let token: TronTRC20Token
        if let hit = catalogHit {
            token = TronTRC20Token(
                network: network,
                contract: trimmedContract,
                symbol: hit.symbol,
                name: hit.name,
                decimals: hit.decimals,
                logoURI: hit.logoURI,
                source: .tronscan
            )
        } else {
            guard let d = UInt8(decimalsInput) else {
                error = "Decimals must be an integer between 0 and 18."
                return
            }
            token = TronTRC20Token(
                network: network,
                contract: trimmedContract,
                symbol: symbolInput.trimmingCharacters(in: .whitespaces),
                name: nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                    ? symbolInput.trimmingCharacters(in: .whitespaces)
                    : nameInput.trimmingCharacters(in: .whitespaces),
                decimals: d,
                logoURI: nil,
                source: .custom
            )
        }
        store.tronTRC20TokenStore.add(token)
        onAdded()
        dismiss()
    }
}
