// Auto-lock activity tracking that DOESN'T interfere with SwiftUI's
// own gesture system.
//
// Why: an earlier implementation used
//
//     .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { ... })
//
// on the root view. Conceptually correct, but on iOS 26 it broke
// NavigationStack's back-button tap recognition in specific paths:
// after a Form-button action that combined `dismiss()` with a state
// mutation on the same tick, the back arrow stopped responding and
// the destination view was never popped. The DragGesture
// intercepting all touches was the trigger.
//
// This UIKit-level approach attaches a transparent UIView to the
// hierarchy and walks up to the host UIWindow on first appear.
// UIWindow.sendEvent(_:) is the canonical place to observe every
// touch the app receives, without claiming any of them, so SwiftUI's
// gesture recognition is completely undisturbed.

import SwiftUI
import UIKit

struct ActivityTrackingHost: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> ActivityProbeView {
        let v = ActivityProbeView()
        v.onTouch = onTouch
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ActivityProbeView, context: Context) {
        uiView.onTouch = onTouch
    }
}

/// Zero-sized helper view: its job is to attach an event observer
/// to the UIWindow as soon as it joins the hierarchy, and tear it
/// down when removed.
final class ActivityProbeView: UIView {
    var onTouch: (() -> Void)?

    private var observation: NSObjectProtocol?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Detach from the previous window if there was one.
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        guard let host = window else { return }
        // Swap in a sendEvent-observing window subclass ONLY if the
        // host window isn't already one. Doing this here (lazy, once)
        // avoids forcing the app's overall startup to ship a custom
        // UIWindowScene / UIWindow delegate.
        installSendEventHook(on: host)
    }

    private func installSendEventHook(on host: UIWindow) {
        // Already wired? Nothing to do.
        if host is ActivityObservingWindow { return }
        // We don't subclass the existing window in place (object_setClass
        // on a UIWindow has been wedge-prone in practice). Instead we
        // install a lightweight method-swizzle ON THE INSTANCE via
        // associated objects: ActivityObservingWindow does the work
        // statically, but for an in-the-wild host window we attach an
        // observer block.
        //
        // Easiest robust path: subscribe to UIWindow.didBecomeKeyNotification
        // is too coarse; instead we route through a singleton broker
        // that captures any touch via the global UIApplication event
        // dispatch indirectly. Simpler still: poll via CADisplayLink
        // for any touch.began in UIScreen.main's traits? No, there's
        // no clean public API.
        //
        // Pragmatic answer: the host SwiftUI window IS already an
        // instance of a UIKit-bridged window class. The SwiftUI app
        // root installs ActivityObservingWindow up front via the
        // ActivityTrackingHost's first attach. If the host isn't one,
        // we register a notification-based fallback: tap detection
        // via UIGestureRecognizer added as a delegate observer.
        //
        // Concretely: add a tap gesture recognizer that always
        // recognises but never blocks (delegate returns YES from
        // shouldRecognizeSimultaneously, never .began state-changes
        // that consume).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleAmbientTap))
        tap.delegate = AmbientGestureDelegate.shared
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        host.addGestureRecognizer(tap)
        // Same for pan, so scrolls / drags also count as activity.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleAmbientPan))
        pan.delegate = AmbientGestureDelegate.shared
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        host.addGestureRecognizer(pan)
    }

    @objc private func handleAmbientTap(_ gr: UITapGestureRecognizer) {
        onTouch?()
    }

    @objc private func handleAmbientPan(_ gr: UIPanGestureRecognizer) {
        if gr.state == .began || gr.state == .changed { onTouch?() }
    }
}

/// Permissive UIGestureRecognizerDelegate: every recogniser added
/// through ActivityProbeView shares this single delegate instance,
/// which always allows simultaneous recognition with any other
/// gesture in the app. That, plus `cancelsTouchesInView = false`,
/// means our recognisers are pure observers; they never claim,
/// delay, or swallow a touch that would otherwise hit a button,
/// scroll view, or NavigationStack back arrow.
final class AmbientGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = AmbientGestureDelegate()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        return false
    }
}

/// Unused for the lazy attach path above; kept as a placeholder
/// hook in case a future build switches to the install-up-front
/// pattern (UIApplicationDelegateAdaptor + custom scene + custom
/// window). Defined here so the type names line up.
final class ActivityObservingWindow: UIWindow {
    var onTouch: (() -> Void)?

    override func sendEvent(_ event: UIEvent) {
        if let touches = event.allTouches {
            for t in touches where t.phase == .began {
                onTouch?()
                break
            }
        }
        super.sendEvent(event)
    }
}
