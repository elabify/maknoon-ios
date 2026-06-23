// Offline PSBT signing flow. Universal hardware-wallet path: works
// with any signer that speaks BIP174 PSBT (Sparrow, Trezor Suite,
// Ledger Live's PSBT import, Specter, BlueWallet, etc.). Also works
// for software wallets if the user wants to sign on an air-gapped
// machine.
//
// Two phases in one sheet:
//   1. Export: build the unsigned PSBT, present as base64 + QR +
//      "Share" + Save-as-file.
//   2. Import: paste the signed PSBT back in (or read from the
//      Share sheet), finalize via BDK, broadcast via Electrum.
//
// The two phases are separate sections so the user can come back
// later to import without losing place. The unsigned PSBT is
// recomputed deterministically from the form inputs, so the user
// can dismiss and reopen safely.

import SwiftUI
import BitcoinDevKit
import UniformTypeIdentifiers

struct BitcoinOfflinePSBTSheet: View {
    let wallet: BitcoinWallet
    let recipient: String
    let amountSat: UInt64
    let feeRateSatsPerVb: UInt64
    let enableRbf: Bool
    let onBroadcast: (String) -> Void

    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var unsignedBase64: String?
    @State private var buildError: String?
    @State private var building = false
    @State private var copiedUnsigned = false

    @State private var signedInput: String = ""
    @State private var importError: String?
    @State private var broadcasting = false
    @State private var broadcastedTxid: String?

    @State private var showSeedSignerFlow: Bool = false
    @State private var showSignedScanner: Bool = false

    /// True when the wallet was created from a SeedSigner pairing.
    /// Surfaces the animated-QR sign path in addition to the
    /// universal paste-base64 flow that already works.
    private var isSeedSigner: Bool {
        guard case .hardware(let deviceId, _, _) = wallet.descriptor.kind else { return false }
        return store.devices.find(id: deviceId)?.kind == .seedsigner
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                exportSection
                importSection
            }
            .navigationTitle("Sign offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await buildUnsigned() }
            .sheet(isPresented: $showSeedSignerFlow) {
                if let psbtData = currentUnsignedPSBTData {
                    SeedSignerSignFlow(unsignedPSBT: psbtData) { signedBytes in
                        // Populate the signed-PSBT field but DO NOT
                        // broadcast yet. The user reviews + taps
                        // the Broadcast button explicitly. Avoids
                        // accidentally pushing a transaction the
                        // moment the QR scan completes.
                        signedInput = signedBytes.base64EncodedString()
                    }
                }
            }
            .fullScreenCover(isPresented: $showSignedScanner) {
                // Universal scanner: accepts SeedSigner's animated
                // UR-PSBT response AND any single-frame base64 PSBT
                // QR a desktop signer (Sparrow, Specter, Trezor
                // Suite) might emit. URPSBTScannerView assembles UR
                // fragments; non-UR payloads pass through the
                // single-frame branch. As with the SeedSigner sheet
                // path above, we populate but do not broadcast.
                // User confirms via the Broadcast button.
                URPSBTScannerView(
                    onDecoded: { bytes in
                        showSignedScanner = false
                        signedInput = bytes.base64EncodedString()
                    },
                    onCancel: { showSignedScanner = false }
                )
            }
        }
    }

    /// Raw PSBT bytes derived from the base64 string the build step
    /// produced. Used by the SeedSigner sign flow to UR-encode.
    private var currentUnsignedPSBTData: Data? {
        guard let b64 = unsignedBase64,
              let data = Data(base64Encoded: b64) else { return nil }
        return data
    }

    // MARK: -- details

    private var detailsSection: some View {
        Section {
            row("Recipient", recipient, mono: true)
            row("Amount", "\(amountSat) sats")
            row("Fee rate", "\(feeRateSatsPerVb) sats/vB")
            row("RBF", enableRbf ? "Enabled" : "Disabled")
        } header: {
            Text("Transaction")
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    // MARK: -- export

    private var exportSection: some View {
        Section {
            if building {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Building unsigned PSBT…")
                }
            } else if let psbt = unsignedBase64 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(psbt)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(6)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = psbt
                            copiedUnsigned = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                copiedUnsigned = false
                            }
                        } label: {
                            Label(copiedUnsigned ? "Copied" : "Copy", systemImage: copiedUnsigned ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: psbt, preview: SharePreview("Unsigned PSBT", image: Image(systemName: "doc"))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    // SeedSigner wallets skip the static QR (wrong
                    // format) and go straight to the animated UR
                    // sheet, which we auto-present in
                    // buildUnsigned(). Keep a button so the user
                    // can re-open it if they swiped away.
                    if isSeedSigner {
                        Button {
                            showSeedSignerFlow = true
                        } label: {
                            Label("Open SeedSigner QR signer", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Hold your SeedSigner camera up to the phone when the animated QR appears. Maknoon collects the signed transaction back through this phone's camera.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        qrSection(payload: psbt)
                    }
                }
            } else if let buildError {
                Text(buildError).foregroundStyle(.red).font(.callout)
                Button("Retry") { Task { await buildUnsigned() } }
            }
        } header: {
            Text("1. Unsigned PSBT")
        } footer: {
            Text("Take this base64 (or the QR) to your signing device. Sparrow / Trezor Suite / Ledger Live / Specter all accept BIP174 PSBT. The signer adds signatures and gives you back a signed PSBT.")
                .font(.caption)
        }
    }

    private func qrSection(payload: String) -> some View {
        // BIP174 base64 PSBTs commonly exceed a single QR's payload
        // capacity. Show one QR as a convenience for short PSBTs and
        // fall back to copy/share for long ones.
        VStack(spacing: 6) {
            if payload.count > 800 {
                Text("PSBT too long for a single QR (\(payload.count) chars). Use Copy or Share instead, or split with Animated QR / BBQr in your signer.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let img = BadgeQR.render(Data(payload.utf8), scale: 6) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: -- import

    private var importSection: some View {
        Section {
            TextField("Paste signed PSBT (base64)…", text: $signedInput, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(3...8)
            HStack {
                Button {
                    if let s = UIPasteboard.general.string { signedInput = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                Button {
                    showSignedScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    Task { await broadcast() }
                } label: {
                    HStack {
                        if broadcasting { ProgressView().controlSize(.small) }
                        Label(broadcasting ? "Broadcasting…" : "Broadcast", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(signedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || broadcasting)
            }
            if let importError {
                Text(importError).foregroundStyle(.red).font(.callout)
            }
            if let txid = broadcastedTxid {
                Label("Broadcast \(txid.prefix(12))…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        } header: {
            Text("2. Signed PSBT")
        } footer: {
            Text("Paste the signed PSBT base64 from your signer, or tap Scan QR to capture an animated UR-PSBT (SeedSigner) or single-frame base64 QR (Sparrow / Specter). Maknoon finalizes the signatures with BDK and broadcasts via the configured Electrum endpoint.")
                .font(.caption)
        }
    }

    // MARK: -- actions

    @MainActor
    private func buildUnsigned() async {
        building = true
        buildError = nil
        defer { building = false }
        do {
            let s = try await wallet.buildUnsignedPSBT(
                toAddressString: recipient,
                amountSat: amountSat,
                feeRateSatsPerVb: feeRateSatsPerVb,
                enableRbf: enableRbf,
                selectedUtxoOutpoints: nil
            )
            unsignedBase64 = s
            // SeedSigner wallets jump straight into the animated
            // UR-PSBT scanner, the static base64 QR above can't
            // be parsed by the SeedSigner camera (wrong format).
            // Auto-present so the user doesn't have to scroll to
            // find the "Sign on SeedSigner via QR" button.
            if isSeedSigner {
                showSeedSignerFlow = true
            }
        } catch {
            buildError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @MainActor
    private func broadcast() async {
        guard let descriptor = store.bitcoinWalletStore.activeWallet else { return }
        let url = store.bitcoinSettings.electrumURL(for: descriptor.network)
        broadcasting = true
        importError = nil
        defer { broadcasting = false }
        do {
            // Pass the original unsigned PSBT so BDK can combine
            // it with the signed one. SeedSigner / Coldcard strip
            // witness-UTXO + bip32 derivation fields to keep their
            // QR small, leaving us with just signatures; without
            // the combine step BDK fails with "PSBT is missing
            // both witness and non-witness utxo".
            let txid = try await wallet.importSignedPSBTAndBroadcast(
                signedPSBTBase64: signedInput.trimmingCharacters(in: .whitespacesAndNewlines),
                originalUnsignedBase64: unsignedBase64,
                electrumURL: url
            )
            broadcastedTxid = txid
            onBroadcast(txid)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
