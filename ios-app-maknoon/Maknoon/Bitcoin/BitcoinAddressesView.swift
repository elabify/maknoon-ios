// Sparrow-style Addresses tab. Segmented control toggles between
// receive (external, chain=0) and change (internal, chain=1)
// keychains. Each row shows:
//
//   - Derivation index
//   - Bech32 address
//   - Current balance (sum of unspent outputs at this address)
//   - Total received (sum of all outputs, spent + unspent)
//   - UTXO count
//
// Balance / received are populated from BDK's listOutput + listUnspent,
// which only return data the wallet has actually seen on chain. A
// fresh wallet that has not yet been funded will show zero for every
// row, which is the correct expectation.

import SwiftUI
import BitcoinDevKit

struct BitcoinAddressesView: View {
    let wallet: BitcoinWallet
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case receive = "Receive"
        case change  = "Change"
        var id: String { rawValue }
        var keychain: KeychainKind { self == .receive ? .external : .internal }
    }

    /// One row per derivation index. Stats keyed off BDK's
    /// listOutput / listUnspent for the matching keychain + index.
    struct Row: Identifiable {
        let id: UInt32
        let address: String
        let balanceSat: UInt64
        let totalReceivedSat: UInt64
        let utxoCount: Int
    }

    @State private var kind: Kind = .receive
    @State private var rows: [Row] = []
    @State private var loading: Bool = false
    @State private var copiedAddress: String?
    @State private var showHardwareDescriptor: Bool = false
    /// Address whose QR is shown full-screen so another person can scan it to
    /// pay (Android parity: the per-row QR button + sheet).
    @State private var qrAddress: QRAddress?

    private struct QRAddress: Identifiable { let id: String }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Keychain", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                List(rows) { row in
                    rowView(row)
                }
                .listStyle(.plain)
                .overlay {
                    if loading { ProgressView() }
                    else if rows.isEmpty {
                        ContentUnavailableView("No addresses yet", systemImage: "tray")
                    }
                }
            }
            .task(id: kind) { await reload() }
            .navigationTitle("Addresses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .hardware = wallet.descriptor.kind {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showHardwareDescriptor = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel("Show hardware wallet descriptor")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showHardwareDescriptor) {
                HardwareDescriptorSheet(wallet: wallet)
            }
            .sheet(item: $qrAddress) { target in
                AddressQRSheet(address: target.id)
            }
        }
    }

    // MARK: -- row

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(row.id)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if row.balanceSat > 0 {
                    Text(formatSats(row.balanceSat))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                } else if row.totalReceivedSat > 0 {
                    Text(formatSats(row.totalReceivedSat))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("-")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Text(row.address)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    qrAddress = QRAddress(id: row.address)
                } label: {
                    Image(systemName: "qrcode")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Show QR")
                Button {
                    UIPasteboard.general.string = row.address
                    copiedAddress = row.address
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if copiedAddress == row.address { copiedAddress = nil }
                    }
                } label: {
                    Image(systemName: copiedAddress == row.address ? "checkmark" : "doc.on.doc")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copiedAddress == row.address ? Color.green : Color.accentColor)
                .accessibilityLabel("Copy address")
                if let url = explorerURL(for: row.address), row.totalReceivedSat > 0 {
                    // Only surface the explorer chevron when there's
                    // something to look at. Unused addresses don't
                    // need a link; they're not yet on chain.
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 12) {
                if row.utxoCount > 0 {
                    Label("\(row.utxoCount) UTXO\(row.utxoCount == 1 ? "" : "s")", systemImage: "circle.grid.2x2.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if row.totalReceivedSat > 0 && row.totalReceivedSat != row.balanceSat {
                    Text("Received \(formatSats(row.totalReceivedSat))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if row.balanceSat == 0 && row.totalReceivedSat == 0 {
                    Text("Unused")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func explorerURL(for address: String) -> URL? {
        let net = store.bitcoinWalletStore.activeWallet?.network ?? .mainnet
        return store.bitcoinSettings.explorerAddressURL(address, on: net)
    }

    // MARK: -- load

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }

        let infos = await wallet.revealedAddresses(keychain: kind.keychain, upTo: 25)
        let allOutputs = await wallet.listOutput()
        let unspent = await wallet.listUnspent()

        // Partition outputs by (keychain, derivationIndex) so we can
        // look them up per address row in O(1).
        let kc = kind.keychain
        var receivedByIndex: [UInt32: UInt64] = [:]
        var balanceByIndex:  [UInt32: UInt64] = [:]
        var utxoCountByIndex: [UInt32: Int]   = [:]
        for o in allOutputs where o.keychain == kc {
            receivedByIndex[o.derivationIndex, default: 0] += o.txout.value.toSat()
        }
        for o in unspent where o.keychain == kc && !o.isSpent {
            balanceByIndex[o.derivationIndex, default: 0] += o.txout.value.toSat()
            utxoCountByIndex[o.derivationIndex, default: 0] += 1
        }

        rows = infos.map { info in
            Row(
                id: info.index,
                address: String(describing: info.address),
                balanceSat: balanceByIndex[info.index] ?? 0,
                totalReceivedSat: receivedByIndex[info.index] ?? 0,
                utxoCount: utxoCountByIndex[info.index] ?? 0
            )
        }
    }

    private func formatSats(_ sats: UInt64) -> String {
        let ticker = store.bitcoinWalletStore.activeWallet?.network.ticker ?? "BTC"
        if sats >= 100_000 {
            let btc = Double(sats) / 100_000_000.0
            return String(format: "%.8f %@", btc, ticker)
        }
        return "\(sats) sats"
    }
}

/// Surfaces a hardware-backed wallet's descriptor info (master
/// fingerprint, derivation path, account xpub) with copy buttons.
/// Used by the macOS BLE test harness and by users who want to
/// import the watch-only descriptor into other wallets (Sparrow,
/// Electrum, etc.).
private struct HardwareDescriptorSheet: View {
    let wallet: BitcoinWallet
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    @State private var xpubRevealed = false

    private var hardwareInfo: (fingerprint: String, xpub: String, coinType: UInt32)? {
        guard case let .hardware(_, fingerprintHex, accountXpub) = wallet.descriptor.kind else {
            return nil
        }
        return (fingerprintHex, accountXpub, wallet.descriptor.network == .mainnet ? 0 : 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let info = hardwareInfo {
                    Section {
                        descriptorRow(label: "Master fingerprint", value: info.fingerprint)
                        descriptorRow(label: "Derivation path", value: "m/84'/\(info.coinType)'/0'")
                        descriptorRow(label: "Network", value: wallet.descriptor.network.rawValue)
                        descriptorRow(label: "Account xpub", value: info.xpub, secret: true)
                    } header: {
                        Text("Hardware wallet descriptor")
                    }
                } else {
                    Text("This wallet is not hardware-backed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Descriptor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func descriptorRow(label: String, value: String, secret: Bool = false) -> some View {
        // `secret` values (the account xpub) are masked behind an eye toggle and
        // revealed only on tap.
        let hidden = secret && !xpubRevealed
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if secret {
                    Button {
                        xpubRevealed.toggle()
                    } label: {
                        Image(systemName: xpubRevealed ? "eye.slash" : "eye").font(.callout)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    UIPasteboard.general.string = value
                    copied = label
                } label: {
                    Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied == label ? Color.green : Color.accentColor)
            }
            Text(hidden ? String(repeating: "•", count: 24) : value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
        }
    }
}

/// Full-screen QR for a single address so another person can scan it to pay
/// (Android parity: the per-row QR dialog). Renders the bare address through the
/// shared BadgeQR CoreImage renderer.
private struct AddressQRSheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                let image = BadgeQR.render(Data(address.utf8), scale: 8)
                Group {
                    if let image {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "qrcode")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 240, height: 240)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)

                Button {
                    UIPasteboard.general.string = address
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Text("Anything sent will arrive in this wallet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Receive to this address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
