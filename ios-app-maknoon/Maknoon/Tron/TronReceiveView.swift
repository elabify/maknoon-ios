// QR + address + copy for a Tron wallet. Mirrors SolanaReceiveView.
// QR payload is the bare T-prefixed base58check address; Tron has no
// standardized payment-URI scheme analogous to BIP21.

import SwiftUI
import UIKit

struct TronReceiveView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let walletId: UUID

    @State private var address: String?
    @State private var loading: Bool = true
    @State private var copied: Bool = false
    @State private var error: String?

    private var descriptor: TronWalletDescriptor? {
        store.tronWalletStore.wallets.first(where: { $0.id == walletId })
    }

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
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy address",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    if let explorerURL = explorerURL(for: address) {
                        Link(destination: explorerURL) {
                            Label("View on \(explorerHost ?? "explorer")", systemImage: "arrow.up.right.square")
                        }
                    }
                    Text("Your private key owns this address across every Tron compatible network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if descriptor != nil {
                Section("Wallet") {
                    LabeledContent("Network", value: store.tronWalletStore.activeNetwork(for: walletId).displayName)
                }
            }
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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

    /// TronScan address URL for the active network. Strips the
    /// trailing slash and appends `/#/address/<addr>` per TronScan's
    /// hash-routed SPA.
    private func explorerURL(for addr: String) -> URL? {
        let net = store.tronWalletStore.activeNetwork(for: walletId)
        let base = store.tronSettings.explorerURL(for: net)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/#/address/\(addr)")
    }

    /// Hostname for the explorer label so the link reads "View on
    /// shasta.tronscan.org" instead of the full URL.
    private var explorerHost: String? {
        let net = store.tronWalletStore.activeNetwork(for: walletId)
        let s = store.tronSettings.explorerURL(for: net)
        return URL(string: s)?.host
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        guard let descriptor, let sandwich = store.sandwich else {
            error = "Wallet not found or identity locked."
            return
        }
        let net = store.tronWalletStore.activeNetwork(for: walletId)
        let rpcURL = store.tronSettings.rpcURL(for: net)
        let wallet = TronWallet(
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
