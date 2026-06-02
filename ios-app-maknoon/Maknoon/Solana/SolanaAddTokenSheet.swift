// Add an SPL token to the dashboard. Lookup order:
//
//   1. Cached Jupiter catalog: a mint that's already verified gets
//      installed with the catalog's metadata in one tap.
//   2. Manual entry: if the mint isn't in the catalog, the sheet
//      exposes symbol + name + decimals fields so the user can fill
//      them in. This is the "I know what I'm doing" path; we don't
//      query Metaplex on-chain metadata in v1 because that requires
//      a separate Solana account decode for each lookup, doable but
//      not table stakes.
//
// The sheet can be pre-populated with a mint (used by the dashboard's
// "Unknown token detected" affordance, which carries the mint over so
// the user doesn't have to copy-paste it).

import SwiftUI

struct SolanaAddTokenSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Cluster the new token is added to. Solana SPL mints are per-
    /// cluster (the USDC mint on mainnet differs from devnet's USDC).
    let network: SolanaNetwork
    /// Pre-populate the mint field. The dashboard banner sets this
    /// when the user taps "Add as custom" on an unverified mint.
    let prefilledMint: String?
    /// Fired after a successful add so the dashboard can refresh.
    let onAdded: () -> Void

    @State private var mintInput: String = ""
    @State private var symbolInput: String = ""
    @State private var nameInput: String = ""
    @State private var decimalsInput: String = ""
    /// Catalog lookup result for the current `mintInput`. Drives the
    /// "verified" badge + auto-fills the fields when found.
    @State private var catalogHit: SolanaTokenCatalog.Entry?
    @State private var error: String?
    /// Result of the on-chain auto-lookup against the SPL Mint
    /// account. Populates `decimals` automatically (the most error-
    /// prone field to type by hand); symbol + name aren't on the
    /// mint and stay manual unless the catalog had them.
    @State private var probedMint: SPLMintMetadata?
    @State private var probing: Bool = false
    @State private var probeEpoch: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                mintSection
                if probing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading mint decimals on chain…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let hit = catalogHit {
                    verifiedSection(hit)
                } else if !trimmedMint.isEmpty && parsedMintIsValid && !probing {
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
                    Text("Verified tokens use the metadata from your configured catalog (Jupiter strict list by default). Custom additions are your responsibility, double-check the mint address against a trusted source before sending value to it.")
                        .font(.caption)
                }
            }
            .navigationTitle("Add SPL token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let m = prefilledMint { mintInput = m }
                refreshCatalogHit()
                scheduleProbeIfNeeded()
            }
            .onChange(of: mintInput) { _, _ in
                refreshCatalogHit()
                scheduleProbeIfNeeded()
            }
        }
    }

    private var mintSection: some View {
        Section {
            TextField("Mint address (base58)", text: $mintInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .monospaced))
            Text("Cluster: \(network.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Mint")
        }
    }

    private func verifiedSection(_ hit: SolanaTokenCatalog.Entry) -> some View {
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

    @ViewBuilder
    private var customSection: some View {
        Section {
            TextField("Symbol (e.g. USDC)", text: $symbolInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
            TextField("Name", text: $nameInput)
            TextField("Decimals (typically 6 or 9)", text: $decimalsInput)
                .keyboardType(.numberPad)
        } header: {
            HStack {
                Label("Not in catalog", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
            }
        } footer: {
            if let probed = probedMint {
                Text("Mint exists on \(network.displayName) (\(probed.decimals) decimals, read from the SPL Mint account on chain). The symbol and name aren't on the mint account, so enter those manually. Verify against a trusted source before sending value.")
                    .font(.caption)
            } else {
                Text("This mint isn't in the verified catalog and didn't respond to the on-chain probe. Enter metadata manually only after confirming the mint address against a trusted source. Decimals are particularly easy to misread, getting them wrong will make balances and amounts display incorrectly.")
                    .font(.caption)
            }
        }
    }

    // MARK: -- derived state

    private var trimmedMint: String {
        mintInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedMintIsValid: Bool {
        SolanaDescriptors.parseAddress(trimmedMint) != nil
    }

    private var canAdd: Bool {
        guard parsedMintIsValid else { return false }
        if catalogHit != nil { return true }
        guard !symbolInput.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let d = UInt8(decimalsInput), d <= 18 else { return false }
        return true
    }

    private func refreshCatalogHit() {
        guard parsedMintIsValid else { catalogHit = nil; return }
        catalogHit = store.solanaTokenCatalog.find(mint: trimmedMint)
    }

    /// Auto-probe the SPL Mint account for decimals. Solana's mint
    /// account doesn't carry symbol or name (those live in a
    /// separate Metaplex metadata account, which v1 doesn't decode),
    /// but `decimals` is the easiest field to type wrong by hand, so
    /// auto-filling that alone is a meaningful win.
    @MainActor
    private func scheduleProbeIfNeeded() {
        probeEpoch += 1
        let myEpoch = probeEpoch
        probedMint = nil
        guard parsedMintIsValid, catalogHit == nil else {
            probing = false
            return
        }
        let mintAtEntry = trimmedMint
        probing = true
        let rpcURL = store.solanaSettings.rpcURL(for: network)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard myEpoch == probeEpoch else { return }
            let meta = await SolanaTokenLookup.fetch(mint: mintAtEntry, rpcURL: rpcURL)
            guard myEpoch == probeEpoch else { return }
            probing = false
            if let meta {
                probedMint = meta
                if decimalsInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    decimalsInput = "\(meta.decimals)"
                }
            }
        }
    }

    // MARK: -- actions

    private func addToken() {
        guard parsedMintIsValid else {
            error = "Mint address is not valid."
            return
        }
        let token: SolanaSPLToken
        if let hit = catalogHit {
            token = SolanaSPLToken(
                network: network,
                mint: trimmedMint,
                symbol: hit.symbol,
                name: hit.name,
                decimals: hit.decimals,
                logoURI: hit.logoURI,
                source: .jupiter
            )
        } else {
            guard let d = UInt8(decimalsInput) else {
                error = "Decimals must be an integer between 0 and 18."
                return
            }
            token = SolanaSPLToken(
                network: network,
                mint: trimmedMint,
                symbol: symbolInput.trimmingCharacters(in: .whitespaces),
                name: nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                    ? symbolInput.trimmingCharacters(in: .whitespaces)
                    : nameInput.trimmingCharacters(in: .whitespaces),
                decimals: d,
                logoURI: nil,
                source: .custom
            )
        }
        store.solanaSPLTokenStore.add(token)
        onAdded()
        dismiss()
    }
}
