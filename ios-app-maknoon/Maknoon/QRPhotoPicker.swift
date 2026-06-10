// Pick a QR code out of the photo library instead of scanning live.
//
// Useful for single-device testing: screenshot a QR shown on another
// screen (a React holder's single QR, a merchant's Verify & Pay request,
// an issuer pickup link), save it, then choose it here. The decoded
// payload is handed to the same `onCode` callback the live camera uses,
// so every downstream flow (receive credential, scan verifier, verify
// someone, Verify & Pay) behaves identically to a live scan.
//
// Limitation: a still image carries ONE QR, so multi-frame / rotating
// (UR fountain) transmissions can't be completed this way — only
// single-QR payloads (pickup URL, request URL, drop envelope, badge,
// or a single-QR presentation). PHPicker runs out-of-process and needs
// no photo-library usage permission.

import SwiftUI
import PhotosUI
import Vision
import UIKit

/// Decodes QR payloads from still-image data via the Vision framework.
enum QRImageDecoder {
    /// First QR payload found in the image, or nil if none decodes.
    static func decodeFirst(_ data: Data) -> String? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
        return payloads.first
    }
}

/// A button that lets the user pick an image from the photo library; on a
/// successful QR decode it calls `onCode` with the payload (mirroring the
/// live scanner), otherwise `onNoQR`.
struct QRPhotoPickerButton<Label: View>: View {
    let onCode: (String) -> Void
    var onNoQR: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            label()
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                let code = data.flatMap { QRImageDecoder.decodeFirst($0) }
                await MainActor.run {
                    item = nil
                    if let code { onCode(code) } else { onNoQR() }
                }
            }
        }
    }
}

extension QRPhotoPickerButton where Label == AnyView {
    /// Convenience initializer with the standard capsule label used over
    /// the camera preview ("Choose photo" with a photo icon).
    init(onCode: @escaping (String) -> Void, onNoQR: @escaping () -> Void = {}) {
        self.init(onCode: onCode, onNoQR: onNoQR) {
            AnyView(
                SwiftUI.Label("Choose photo", systemImage: "photo.on.rectangle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
            )
        }
    }
}
