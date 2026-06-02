// End-to-end PSBT round-trip with a SeedSigner.
//
// Step 1: Show the unsigned PSBT as an animated UR-PSBT QR. The
//         user holds their SeedSigner camera up to the phone and
//         lets it ingest frames at its own pace.
// Step 2: When SeedSigner is happy with the transaction, it signs
//         and shows its own animated QR.
// Step 3: User taps "Scan signed transaction"; the phone's camera
//         collects fragments until a complete PSBT is reassembled.
// Step 4: We hand the signed PSBT back to the caller for finalize
//         + broadcast (handled by the existing BDK code path).

import SwiftUI
import URKit

struct SeedSignerSignFlow: View {
    let unsignedPSBT: Data
    /// Fires when the user has a signed PSBT in hand. Caller is
    /// responsible for BDK finalize + Electrum broadcast.
    let onSigned: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var encoder: UREncoder?
    @State private var showScanner = false
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // QR fills the entire frame including under the
                // bottom controls; the controls float on top with
                // a small darkening layer so the QR underneath is
                // never compressed by competing layout.
                if let encoder {
                    AnimatedQRView(encoder: encoder, frameInterval: 0.3)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Color(uiColor: .systemBackground)
                    ProgressView()
                }

                VStack(spacing: 8) {
                    if let lastError {
                        Text(lastError).foregroundStyle(.red).font(.caption)
                    }
                    Text("Hold the SeedSigner camera 6-10 inches from the phone")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan signed transaction", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            }
            .navigationTitle("Sign on SeedSigner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { buildEncoder() }
            .fullScreenCover(isPresented: $showScanner) {
                URPSBTScannerView(
                    onDecoded: { bytes in
                        showScanner = false
                        onSigned(bytes)
                        dismiss()
                    },
                    onCancel: { showScanner = false }
                )
            }
        }
    }

    private func buildEncoder() {
        do {
            // 70-byte fragments keep each QR at QR-version ~9-10
            // (about 50 modules per side). At a full-screen render
            // of ~390-430pt, that's ~8 pixels per module — well
            // above the 4-pixel-per-module floor SeedSigner's
            // fixed-focus camera needs. Going to 100 bytes per
            // fragment shoved each QR up to version 13-14 (70+
            // modules) which is at the edge of what SeedSigner
            // can pick up consistently.
            encoder = try URPSBTCodec.makeEncoder(psbt: unsignedPSBT, maxFragmentLen: 70)
        } catch {
            lastError = "Couldn't prepare the QR sequence. \(error.localizedDescription)"
        }
    }
}
