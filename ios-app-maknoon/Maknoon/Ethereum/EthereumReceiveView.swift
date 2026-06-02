// Receive screen: shows the EOA address as text + QR + copy. The
// same address is used across every EVM chain because EVM addresses
// are chain-agnostic at the EOA level (chainId only matters for
// transaction signing). The "view on explorer" link routes through
// `EthereumSettings.explorerAddressURL`, which honours any per-
// network override the user has configured under Settings →
// Networks → Ethereum.

import SwiftUI

struct EthereumReceiveView: View {
    let address: String
    let network: ResolvedNetwork
    let walletLabel: String
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    qrSection
                    addressSection
                    explorerLink
                    Text("Your private key owns this address across every Ethereum compatible chain.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .navigationTitle("Receive \(network.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var qrSection: some View {
        let image = BadgeQR.render(Data(address.utf8), scale: 8)
        return VStack(spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable().scaledToFit()
                } else {
                    Image(systemName: "qrcode").resizable().scaledToFit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 240, height: 240)
            .padding(8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(walletLabel).font(.callout.weight(.semibold))
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address").font(.caption).foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = address
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                HStack {
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .accentColor)
                }
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private var explorerLink: some View {
        if let url = explorerAddressURL {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on \(explorerHostLabel(url))")
                }
                .font(.callout.weight(.medium))
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(.thinMaterial)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var explorerAddressURL: URL? {
        let base = network.explorerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/address/\(address)")
    }

    /// "etherscan.io" rather than the full URL. Honours the user's
    /// override (e.g. their own Blockscout) automatically because we
    /// derive the label from whatever URL EthereumSettings returned.
    private func explorerHostLabel(_ url: URL) -> String {
        url.host ?? "explorer"
    }
}
