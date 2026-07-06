// Temporarily ramps the screen to full brightness while a QR code is shown, so
// a scanner can read it reliably (especially the dense multi-frame QR frames),
// then restores the user's previous brightness on disappear. Apply with
// `.maxBrightnessWhilePresented()` to any view that displays a QR the user holds
// up to another device or reader. See ADR (QR display conventions).

import SwiftUI
import UIKit

private struct MaxBrightnessModifier: ViewModifier {
    @State private var previousBrightness: CGFloat?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Capture once so re-appear (or a redraw) never stacks up and
                // loses the real prior value.
                if previousBrightness == nil {
                    previousBrightness = UIScreen.main.brightness
                }
                UIScreen.main.brightness = 1.0
            }
            .onDisappear {
                if let prev = previousBrightness {
                    UIScreen.main.brightness = prev
                    previousBrightness = nil
                }
            }
    }
}

extension View {
    /// Ramp the screen to full brightness while this view is on screen and
    /// restore the prior brightness when it disappears.
    func maxBrightnessWhilePresented() -> some View {
        modifier(MaxBrightnessModifier())
    }
}
