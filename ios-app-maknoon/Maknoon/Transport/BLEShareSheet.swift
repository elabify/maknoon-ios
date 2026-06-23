// Default Share-as-QR path. Renders the holder's BLE engagement
// payload as a single static QR (sub-2 kB, fits comfortably). When the
// verifier scans + connects, the BLE handshake completes, the sealed
// Presentation flows over the radio, and the sheet shows "Done."
//
// Multi-frame QR remains available as a fallback (button at the
// bottom) for any scenario where BLE is denied or unavailable, but
// the rotating-frame path is no longer the default share UX.

import SwiftUI

struct BLEShareSheet: View {
    let presentation: Presentation
    let onClose: () -> Void

    @StateObject private var host = BLEPeripheralHost()
    @State private var qrImage: UIImage?
    @State private var fallbackToFrames: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if fallbackToFrames {
                    // The user explicitly switched to the multi-frame
                    // QR. Re-use LocalShareQrSheet's content view by
                    // presenting it inline.
                    LocalShareQrSheet(presentation: presentation, onClose: onClose)
                } else {
                    bleContent
                }
            }
            .navigationTitle("Verifier scans this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        host.stop()
                        onClose()
                    }
                }
            }
            .task { startHost() }
            .onDisappear { host.stop() }
        }
    }

    @ViewBuilder
    private var bleContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 360)
                        .padding(20)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ProgressView()
                        .padding(.vertical, 80)
                }

                statusBlock

                Text("One scan kicks off a Bluetooth session. The Presentation flows directly between the two phones, encrypted with a fresh post-quantum key. No server in the middle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Divider().padding(.vertical, 4)

                Button(role: .none) {
                    fallbackToFrames = true
                } label: {
                    Label("Show rotating QR instead", systemImage: "square.stack.3d.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                Text("Use rotating QR if the verifier's device has Bluetooth turned off or doesn't support it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        let (icon, color, label): (String, Color, String) = {
            switch host.phase {
            case .idle:                       return ("circle.dotted", .secondary, "Starting Bluetooth…")
            case .unsupported(let reason):    return ("exclamationmark.triangle.fill", .orange, reason)
            case .advertising:                return ("dot.radiowaves.left.and.right", .green, "Waiting for verifier to scan")
            case .handshakeReceived:          return ("arrow.left.arrow.right", .blue, "Handshake, exchanging keys")
            case .payloadDelivered:           return ("checkmark.shield.fill", .green, "Delivered. Verifier has your credential.")
            case .error(let reason):          return ("xmark.shield.fill", .red, reason)
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    // MARK: -- host setup

    private func startHost() {
        do {
            try host.setPresentation(presentation)
        } catch {
            return
        }
        host.start()
        // Wait one frame for the engagement to populate, then render.
        Task { @MainActor in
            // Poll briefly until engagement is set (after CB delegate
            // fires). At ~60 fps a few iterations is plenty.
            for _ in 0..<60 {
                if host.engagement != nil { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard let eng = host.engagement else { return }
            do {
                let data = try JSONEncoder().encode(eng)
                qrImage = BadgeQR.render(data)
            } catch {
                // Fall back to LocalShareQrSheet, at least the user
                // gets a working path.
                fallbackToFrames = true
            }
        }
    }
}
