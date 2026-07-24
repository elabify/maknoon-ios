import SwiftUI
import UIKit

/// Tracks whether the screen is being captured, i.e. a screen recording is
/// running or the display is mirrored (AirPlay / QuickTime). Identity views
/// observe this and force sensitive values to stay masked while a capture is
/// active.
///
/// iOS cannot block a screen recording or a screenshot outright, so masking on
/// capture is the strongest response available on this platform. (Android uses
/// FLAG_SECURE, which hard-blocks both.) A one-off screenshot is deliberately
/// NOT surfaced to the user: it has already been taken by the time the system
/// notifies us, so a toast would be noise. ADR-0069.
private struct ScreenCaptureTracking: ViewModifier {
    @Binding var captured: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { captured = UIScreen.main.isCaptured }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = UIScreen.main.isCaptured
            }
    }
}

extension View {
    /// Keeps `captured` in sync with the live screen-capture state (recording
    /// or mirroring). Bind it and OR it into a view's mask condition so
    /// sensitive values re-blur for the duration of the capture.
    func trackingScreenCapture(_ captured: Binding<Bool>) -> some View {
        modifier(ScreenCaptureTracking(captured: captured))
    }
}
