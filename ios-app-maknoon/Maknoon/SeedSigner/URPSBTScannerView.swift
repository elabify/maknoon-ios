// Camera UI for collecting a multi-frame UR-PSBT scan from a
// SeedSigner screen. Wraps the shared continuous QRScannerView and
// hands each detected payload to the streaming UR decoder. Shows
// how many frames have arrived so the user knows it's making
// progress.

import SwiftUI

struct URPSBTScannerView: View {
    /// Fires with the assembled PSBT bytes the moment the decoder
    /// has enough fragments to reassemble.
    let onDecoded: (Data) -> Void
    /// User canceled or scan errored out.
    let onCancel: () -> Void

    @State private var decoder = URPSBTCodec.StreamingDecoder()
    @State private var fragmentsSeen: Int = 0
    @State private var lastError: String?

    var body: some View {
        ZStack {
            QRScannerView(onCode: { payload in
                process(payload)
            }, continuous: true)
            .ignoresSafeArea()
            VStack {
                Spacer()
                statusOverlay
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel scan")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: 6) {
            Text("Scanning signed transaction")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            if let n = decoder.expectedPartCount, n > 0 {
                Text("Captured \(decoder.receivedPartIndexes.count) of \(n) unique frames")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                ProgressView(value: max(0, min(1, decoder.progress)))
                    .tint(.white)
                    .frame(maxWidth: 220)
            } else {
                Text("Looking for the SeedSigner QR…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let lastError {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func process(_ payload: String) {
        guard payload.lowercased().hasPrefix("ur:") else { return }
        let done = decoder.receivePart(payload)
        fragmentsSeen += 1
        if done {
            do {
                let bytes = try decoder.assembledPSBT()
                onDecoded(bytes)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
