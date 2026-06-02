// Animated QR display for fountain-encoded UR sequences. Each tick
// pulls the next frame off the encoder and re-renders the QR. The
// SeedSigner camera buffer reassembles frames as it sees them; the
// user just holds the camera up to the phone until done.
//
// The view sizes the QR to whatever square fits the available
// width and pins screen brightness to full while it's on-screen
// (restored on disappear) so the SeedSigner's camera has enough
// contrast in dim lighting. Both are the difference between a
// 2-second scan and the user fighting it for a minute.

import SwiftUI
import CoreImage.CIFilterBuiltins
import URKit
import UIKit

struct AnimatedQRView: View {
    let encoder: UREncoder
    var frameInterval: TimeInterval = 0.2  // 5 fps; SeedSigner reads this comfortably

    @State private var currentFragment: String = ""
    @State private var tickCount: Int = 0
    /// Original screen brightness, restored when the view goes
    /// away. We force brightness to 1.0 while the QR is on screen.
    @State private var savedBrightness: CGFloat?

    var body: some View {
        GeometryReader { geo in
            // Take the SMALLER axis to keep the QR square, but
            // don't subtract padding here — let the parent layout
            // do the trimming. Bigger = more pixels per module =
            // scannable from further away.
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if let image = render(currentFragment, side: side) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .background(Color.white)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: side, height: side)
                        .overlay(ProgressView())
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .task {
            // Render the first frame immediately, then advance on a
            // fixed cadence until the view is torn down. Using
            // Task.sleep keeps the loop fully Swift-concurrency
            // native; Timer would force an @Sendable capture that
            // Timer can't satisfy.
            advance()
            let nanos = UInt64(frameInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                advance()
            }
        }
        .onAppear { boostBrightness() }
        .onDisappear { restoreBrightness() }
    }

    private func advance() {
        currentFragment = encoder.nextPart()
        tickCount += 1
    }

    private func render(_ string: String, side: CGFloat) -> UIImage? {
        guard !string.isEmpty, side > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "L"   // SeedSigner's camera prefers L; smaller QR, easier read
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.size.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    @MainActor
    private func boostBrightness() {
        guard let screen = currentScreen() else { return }
        if savedBrightness == nil {
            savedBrightness = screen.brightness
        }
        screen.brightness = 1.0
    }

    @MainActor
    private func restoreBrightness() {
        if let saved = savedBrightness, let screen = currentScreen() {
            screen.brightness = saved
        }
        savedBrightness = nil
    }

    /// iOS 26 deprecates `UIScreen.main` in favour of looking up
    /// the screen through the active window scene. Single-scene
    /// apps like Maknoon take the foreground-active scene.
    @MainActor
    private func currentScreen() -> UIScreen? {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene,
               ws.activationState == .foregroundActive {
                return ws.screen
            }
        }
        // Fall back to any window scene if none is "active" right
        // now (e.g. just-launched state).
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
    }
}
