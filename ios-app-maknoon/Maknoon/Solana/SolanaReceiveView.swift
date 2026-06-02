// Solana receive screen. Mirrors BitcoinReceiveView: QR + copy-to-
// clipboard address + optional memo field for the Solana URI scheme.
// Solana doesn't have a payment URI standard equivalent to BIP21
// (`solana:` URIs are emerging but inconsistently supported), so we
// keep the QR as the bare address; the memo input is captured for
// the sender's benefit at send time, not embedded in the QR.

import SwiftUI
import UIKit

struct SolanaReceiveView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let walletId: UUID

    @State private var address: String?
    @State private var loading: Bool = true
    @State private var copied: Bool = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Deriving address…").foregroundStyle(.secondary)
                    }
                } else if let address {
                    qrSection(address)
                    addressSection(address)
                } else if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            if let address {
                Section {
                    Button {
                        UIPasteboard.general.string = address
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    if let url = explorerURL(for: address) {
                        Link(destination: url) {
                            Label("View on \(explorerHost ?? "explorer")", systemImage: "arrow.up.right.square")
                        }
                    }
                    Text("Your private key owns this address across every Solana cluster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Solana Explorer URL for the active cluster. Handles the
    /// `?cluster=devnet` query-string quirk on non-mainnet.
    private func explorerURL(for addr: String) -> URL? {
        let net = store.solanaWalletStore.activeNetwork(for: walletId)
        let base = store.solanaSettings.explorerURL(for: net)
        let final: String
        if base.contains("?") {
            final = base.replacingOccurrences(of: "?", with: "/address/\(addr)?")
        } else {
            final = "\(base)/address/\(addr)"
        }
        return URL(string: final)
    }

    private var explorerHost: String? {
        let net = store.solanaWalletStore.activeNetwork(for: walletId)
        return URL(string: store.solanaSettings.explorerURL(for: net))?.host
    }

    @ViewBuilder
    private func qrSection(_ address: String) -> some View {
        Section {
            VStack(spacing: 10) {
                Group {
                    if let image = BadgeQR.render(Data(address.utf8), scale: 8) {
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
                Text("Scan or copy. Anything sent to this address arrives in this wallet.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private func addressSection(_ address: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        guard let descriptor = store.solanaWalletStore.wallets.first(where: { $0.id == walletId }),
              let sandwich = store.sandwich
        else {
            error = "Wallet not found or identity locked."
            return
        }
        let net = store.solanaWalletStore.activeNetwork(for: walletId)
        let rpcURL = store.solanaSettings.rpcURL(for: net)
        let wallet = SolanaWallet(
            descriptor: descriptor,
            network: net,
            rpcURL: rpcURL,
            sandwich: sandwich
        )
        do {
            self.address = try await wallet.resolvedAddress(
                biometricReason: "Show receive address for \(descriptor.label)"
            )
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
