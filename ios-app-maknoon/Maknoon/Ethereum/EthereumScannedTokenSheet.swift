// Asked when a scanned EIP-681 payment code requests an ERC-20 this wallet does
// not have on this chain. Before 0.6.9 that was a dead end ("that QR requests a
// token this wallet does not have added on this network"), which is wrong in the
// common real case: a Coinbase Arbitrum deposit QR names bridged USDC.e while
// the wallet holds native USDC, and the payee accepts either.
//
// So: probe the requested contract on chain (symbol / name / decimals + this
// wallet's balance), show it next to any token already held under the same
// symbol, and make the user choose. Two contracts sharing a symbol are still
// different tokens and a payee may credit only the one it asked for, so nothing
// here substitutes silently.

import SwiftUI

/// What the send view hands to this sheet: the token contract the code asked
/// for, plus the recipient and amount to apply once an asset is settled on.
struct ScannedTokenRequest: Identifiable {
    let id = UUID()
    let contract: String
    let recipient: String
    let amountBaseUnits: String?
}

/// What the code asked for, carried back so the send view can warn about a
/// substitution and decide whether the requested amount is still meaningful.
struct RequestedTokenInfo {
    let contract: String
    let symbol: String
    let name: String
    let decimals: Int
}

/// The user's answer: which token to send, and (when they picked a different
/// contract than the code named) what the code had actually requested.
struct ScannedTokenChoice {
    let token: EthereumToken
    let substitutedFrom: RequestedTokenInfo?
}

struct EthereumScannedTokenSheet: View {
    let request: ScannedTokenRequest
    let wallet: EthereumWallet
    /// Built-in chain the send form is on. Tokens are keyed by it.
    let network: EthereumNetwork
    /// Same chain resolved (RPC URL + display name).
    let resolved: ResolvedNetwork
    /// Every token this wallet already has on this chain.
    let added: [EthereumToken]
    let onChoose: (ScannedTokenChoice) -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Candidate: Identifiable {
        let token: EthereumToken
        let balance: EthereumWeiValue?
        var id: String { token.id }
    }

    @State private var probing: Bool = true
    @State private var meta: ERC20Metadata?
    @State private var requestedBalance: EthereumWeiValue?
    @State private var candidates: [Candidate] = []
    @State private var probeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This payment code asks for a token that is not in this wallet on \(resolved.displayName).")
                        .font(.callout)
                }

                Section("Requested") {
                    if probing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the contract on \(resolved.displayName)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let meta {
                        LabeledContent("Token", value: "\(meta.symbol) · \(meta.name)")
                        LabeledContent("Contract") {
                            Text(shortContract(request.contract))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Chain", value: resolved.displayName)
                        LabeledContent(
                            "Your balance",
                            value: balanceText(requestedBalance, decimals: meta.decimals, symbol: meta.symbol)
                        )
                    } else {
                        LabeledContent("Contract") {
                            Text(shortContract(request.contract))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(probeError ?? "Could not read this contract.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !candidates.isEmpty {
                    Section("You already hold") {
                        ForEach(candidates) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.token.symbol) · \(c.token.name)")
                                    .font(.callout)
                                Text(shortContract(c.token.contractAddress))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(balanceText(c.balance, decimals: c.token.decimals, symbol: c.token.symbol))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if let meta {
                        Button {
                            addRequestedAndUse(meta: meta)
                        } label: {
                            Text("Add \(meta.symbol) (\(meta.name)) and use it")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(candidates) { c in
                        Button {
                            use(candidate: c.token)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Send my \(c.token.symbol) instead")
                                Text("\(shortContract(c.token.contractAddress)) · \(balanceText(c.balance, decimals: c.token.decimals, symbol: c.token.symbol))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } footer: {
                    if candidates.isEmpty {
                        Text("Check the contract against the payee's deposit instructions before adding it.")
                            .font(.caption)
                    } else {
                        Text("Two tokens can share a symbol and still be different contracts. A payee may credit only the contract it asked for, so confirm its deposit instructions before sending a different one.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Token requested")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await probe() }
        }
    }

    // MARK: -- actions

    /// Persist the probed contract to this wallet on this chain, then use it.
    /// `curated: false` so it stays removable in the wallet's token list.
    private func addRequestedAndUse(meta: ERC20Metadata) {
        let token = EthereumToken(
            network: network,
            contractAddress: request.contract,
            symbol: meta.symbol,
            name: meta.name,
            decimals: meta.decimals,
            curated: false
        )
        store.ethereumTokenStore.add(token, walletId: wallet.descriptor.id)
        onChoose(ScannedTokenChoice(token: token, substitutedFrom: nil))
        dismiss()
    }

    /// Send a contract the wallet already holds instead of the one requested.
    /// Reports what was asked for so the send form can keep warning about it.
    private func use(candidate: EthereumToken) {
        let from = meta.map {
            RequestedTokenInfo(
                contract: request.contract,
                symbol: $0.symbol,
                name: $0.name,
                decimals: $0.decimals
            )
        }
        onChoose(ScannedTokenChoice(token: candidate, substitutedFrom: from))
        dismiss()
    }

    // MARK: -- data

    @MainActor
    private func probe() async {
        probing = true
        probeError = nil
        let rpcURL = resolved.rpcURL
        guard let m = await EthereumTokenLookup.fetch(contract: request.contract, rpcURL: rpcURL) else {
            probeError = "That contract did not answer symbol() or decimals() on \(resolved.displayName). It may not be an ERC-20, or it may live on a different chain."
            probing = false
            return
        }
        meta = m
        // Balances are informational: a failed read shows "unknown" rather than
        // blocking a decision the user can still make.
        let probeToken = EthereumToken(
            network: network,
            contractAddress: request.contract,
            symbol: m.symbol,
            name: m.name,
            decimals: m.decimals,
            curated: false
        )
        requestedBalance = try? await wallet.tokenBalance(token: probeToken, rpcURL: rpcURL)
        if case .sameSymbolCandidates(let list) = EthereumScannedToken.resolve(
            requestedContract: request.contract,
            requestedSymbol: m.symbol,
            added: added
        ) {
            var out: [Candidate] = []
            for t in list {
                out.append(Candidate(token: t, balance: try? await wallet.tokenBalance(token: t, rpcURL: rpcURL)))
            }
            candidates = out
        }
        probing = false
    }

    // MARK: -- formatting

    private func shortContract(_ contract: String) -> String {
        let display = EIP55.checksum(contract)
        guard display.count > 12 else { return display }
        return "\(display.prefix(6))…\(display.suffix(4))"
    }

    private func balanceText(_ value: EthereumWeiValue?, decimals: Int, symbol: String) -> String {
        guard let value else { return "unknown" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = decimals
        let units = NSDecimalNumber(decimal: value.units(decimals: decimals))
        return "\(f.string(from: units) ?? "0") \(symbol)"
    }
}
