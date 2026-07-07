// Temporarily ramps the screen to full brightness while a QR code is shown, so
// a scanner can read it reliably (especially the dense multi-frame QR frames),
// then restores the user's previous brightness once no QR view remains. Apply
// with `.maxBrightnessWhilePresented()` to any view that displays a QR the user
// holds up to another device or reader. See ADR (QR display conventions).
//
// Implemented as a reference-counted controller (mirroring the Android
// BrightnessController) rather than a bare onAppear/onDisappear pair. A SwiftUI
// view inside a NavigationStack presented in a sheet can fire a spurious
// onDisappear immediately followed by onAppear; the naive approach restored the
// prior brightness in that gap, so on iOS the screen never visibly brightened.
// The controller (a) captures the user's brightness only when the FIRST holder
// acquires, (b) keeps it at 1.0 while any holder is active, and (c) debounces
// the restore so an appear-disappear-appear churn nets out to "stay bright".

import SwiftUI
import UIKit

@MainActor
final class ScreenBrightnessController {
    static let shared = ScreenBrightnessController()

    private var holders = 0
    private var savedBrightness: CGFloat?
    private var restoreWork: DispatchWorkItem?

    func acquire() {
        // Cancel any pending restore: a new holder means we stay bright.
        restoreWork?.cancel()
        restoreWork = nil
        if holders == 0 {
            savedBrightness = UIScreen.main.brightness
        }
        holders += 1
        UIScreen.main.brightness = 1.0
    }

    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        // Debounce the restore so a transient disappear (SwiftUI NavigationStack
        // / sheet quirk) that is followed by a re-appear does not flicker the
        // brightness back down.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.holders == 0, let prev = self.savedBrightness else { return }
            UIScreen.main.brightness = prev
            self.savedBrightness = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

private struct MaxBrightnessModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { ScreenBrightnessController.shared.acquire() }
            .onDisappear { ScreenBrightnessController.shared.release() }
    }
}

extension View {
    /// Ramp the screen to full brightness while this view is on screen and
    /// restore the prior brightness when the last such view disappears.
    func maxBrightnessWhilePresented() -> some View {
        modifier(MaxBrightnessModifier())
    }
}
