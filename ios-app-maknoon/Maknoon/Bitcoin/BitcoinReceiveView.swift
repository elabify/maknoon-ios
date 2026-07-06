// Sparrow-style Receive screen. Shows the next unused external
// address as a tap-to-copy bech32 string, an optional label and
// amount, and a QR for the resulting bitcoin: URI.

import SwiftUI
import BitcoinDevKit

struct BitcoinReceiveView: View {
    let wallet: BitcoinWallet
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var addressInfo: AddressInfo?
    @State private var amountBtc: String = ""
    @State private var label: String = ""
    @State private var copied: Bool = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let info = addressInfo {
                        qrSection(info: info)
                        addressSection(info: info)
                        formSection
                    } else {
                        ProgressView().padding(.top, 40)
                    }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .task { await loadAddress() }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .maxBrightnessWhilePresented()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func qrSection(info: AddressInfo) -> some View {
        let uri = bitcoinURI(info: info)
        let image = BadgeQR.render(Data(uri.utf8), scale: 8)
        return VStack(spacing: 10) {
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
            Text("Scan or copy. Anything sent will arrive in this wallet.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func addressSection(info: AddressInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address (index \(info.index))").font(.caption).foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = String(describing: info.address)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                HStack {
                    Text(String(describing: info.address))
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

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. From Alice", text: $label)
                .textFieldStyle(.roundedBorder)

            Text("Amount in BTC (optional)").font(.caption).foregroundStyle(.secondary)
            TextField("0.00", text: $amountBtc)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func bitcoinURI(info: AddressInfo) -> String {
        let address = String(describing: info.address)
        var uri = "bitcoin:\(address)"
        var query: [String] = []
        if let amt = Double(amountBtc), amt > 0 {
            query.append("amount=\(amt)")
        }
        if !label.trimmingCharacters(in: .whitespaces).isEmpty {
            let escaped = label.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? label
            query.append("label=\(escaped)")
        }
        if !query.isEmpty {
            uri += "?" + query.joined(separator: "&")
        }
        return uri
    }

    @MainActor
    private func loadAddress() async {
        do {
            addressInfo = try await wallet.nextReceiveAddress()
        } catch {
            self.error = "Could not derive address: \(error)"
        }
    }
}
