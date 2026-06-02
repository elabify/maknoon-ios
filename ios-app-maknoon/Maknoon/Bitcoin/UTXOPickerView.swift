// Sheet-presented manual UTXO selector. Powered by BDK's
// `Wallet.listUnspent()`; selected outpoints flow back into
// `BitcoinWallet.buildUnsignedPSBT(selectedUtxoOutpoints:)`
// (BDK's `TxBuilder.addUtxos(...).manuallySelectedOnly()`).
//
// Labels (per `txid:vout`) read from / written to BitcoinLabelStore
// via the shared BitcoinLabelEditSheet.

import SwiftUI
import BitcoinDevKit

struct UTXOPickerView: View {
    let wallet: BitcoinWallet
    let network: BitcoinNetwork
    let amountNeededSat: UInt64
    /// Already-selected outpoints from the parent's prior open of
    /// this sheet. Lets the user re-open without losing state.
    @Binding var selection: Set<UTXOKey>

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var utxos: [LocalOutput] = []
    @State private var labelSheetTarget: BitcoinLabelEditSheet.Scope?
    @State private var loading = true

    /// Hashable key identifying a UTXO by `txid:vout`. Avoids holding
    /// references to BDK's non-Sendable types in `selection`.
    struct UTXOKey: Hashable, Sendable {
        let txid: String
        let vout: UInt32
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                listSection
            }
            .navigationTitle("Select UTXOs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use selection") { dismiss() }
                        .disabled(selection.isEmpty)
                        .bold()
                }
            }
            .task { await load() }
            .sheet(item: $labelSheetTarget) { scope in
                BitcoinLabelEditSheet(scope: scope)
                    .environment(store)
            }
        }
    }

    // MARK: -- sections

    private var summarySection: some View {
        Section {
            LabeledContent("Selected") {
                Text(formatSats(selectedSat))
                    .monospacedDigit()
                    .foregroundStyle(selectedSat >= amountNeededSat ? Color.green : Color.primary)
            }
            LabeledContent("Needed") {
                Text(formatSats(amountNeededSat)).monospacedDigit()
            }
            if selectedSat < amountNeededSat {
                Text("Add \(formatSats(amountNeededSat - selectedSat)) more — fee not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Selection covers the recipient amount. The TxBuilder will deduct the fee from change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Coverage")
        }
    }

    @ViewBuilder
    private var listSection: some View {
        Section {
            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading wallet UTXOs…").font(.callout)
                }
            } else if unspent.isEmpty {
                Text("No spendable UTXOs in this wallet yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(unspent, id: \.uniqueKey) { utxo in
                    row(for: utxo)
                }
            }
        } header: {
            Text("UTXOs")
        }
    }

    private func row(for utxo: LocalOutput) -> some View {
        let key = utxo.uniqueKey
        let isSelected = selection.contains(key)
        let label = store.bitcoinLabels.label(forOutput: key.txid, vout: key.vout)
        return Button {
            if isSelected {
                selection.remove(key)
            } else {
                selection.insert(key)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shortOutpoint(key))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let l = label, !l.isEmpty {
                        Text(l).font(.callout.weight(.medium)).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(confirmationsString(utxo))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatSats(utxo.txout.value.toSat()))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Button {
                        labelSheetTarget = .output(txid: key.txid, vout: key.vout)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit label")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: -- data

    private var unspent: [LocalOutput] {
        utxos.filter { !$0.isSpent }
    }

    private var selectedSat: UInt64 {
        unspent.reduce(0) { acc, u in
            selection.contains(u.uniqueKey) ? acc + u.txout.value.toSat() : acc
        }
    }

    private func load() async {
        loading = true
        utxos = await wallet.listUnspent()
        loading = false
    }

    // MARK: -- formatting

    private func formatSats(_ sats: UInt64) -> String {
        let btc = Double(sats) / 100_000_000
        return String(format: "%.8f %@", btc, network.ticker)
    }

    private func shortOutpoint(_ key: UTXOKey) -> String {
        let s = key.txid
        let short = s.count <= 16 ? s : "\(s.prefix(6))…\(s.suffix(4))"
        return "\(short):\(key.vout)"
    }

    private func confirmationsString(_ utxo: LocalOutput) -> String {
        switch utxo.chainPosition {
        case .confirmed(let bt, _):
            return "Block \(bt.blockId.height)"
        case .unconfirmed:
            return "Mempool"
        }
    }
}

// MARK: -- bridging helpers

extension LocalOutput {
    /// Stable key for use in `Set<UTXOKey>` selection state. We
    /// hold strings rather than the BDK `OutPoint` because the
    /// latter isn't `Hashable`-stable across actor hops.
    fileprivate var uniqueKey: UTXOPickerView.UTXOKey {
        UTXOPickerView.UTXOKey(
            txid: String(describing: outpoint.txid),
            vout: outpoint.vout
        )
    }
}

extension BitcoinLabelEditSheet.Scope: Identifiable {
    public var id: String {
        switch self {
        case .address(let a): return "addr:\(a)"
        case .output(let txid, let vout): return "out:\(txid):\(vout)"
        }
    }
}
