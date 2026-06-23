// User override for the presentation relay / drop host (the verifier origin
// that sealed presentation payloads transit when shared over the network, and
// the registry host for commerce request validation). Default is the public
// elabify verifier; a self-hoster can repoint it, and the privacy-conscious can
// turn network sharing off entirely (#61). Mirrors Android RelaySettings.
//
// The drop QR carries only the drop id, not the host, so the sender and the
// verifier must use the SAME relay. When disabled, PresentationDrop upload /
// fetch refuse and only the rotating privacy QR (tiny payloads) remains.
//
// The @Observable instance (on HolderStore) drives the Settings UI; the static
// readers serve the non-observable call sites (PresentationDrop, HolderStore.
// elabifyDropHost). Both hit the same UserDefaults keys.

import Foundation
import Observation

@Observable
final class RelaySettings: @unchecked Sendable {
    var host: String { didSet { persist() } }
    var enabled: Bool { didSet { persist() } }

    static let defaultHost = "https://musnad-verifier.elabify.com"
    private static let hostKey = "app.relayHost"
    private static let enabledKey = "app.relayEnabled"

    init() {
        self.host = UserDefaults.standard.string(forKey: Self.hostKey) ?? Self.defaultHost
        self.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) != nil
            ? UserDefaults.standard.bool(forKey: Self.enabledKey)
            : true
    }

    func reload() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? Self.defaultHost
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) != nil
            ? UserDefaults.standard.bool(forKey: Self.enabledKey)
            : true
    }

    private func persist() {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    // -- static readers for non-observable call sites --

    /// The configured relay origin as a URL, falling back to the default when
    /// the override is empty or unparseable. Always returns a host (the
    /// `enabled` flag, not this, gates whether the drop is used).
    static var hostURL: URL {
        let s = (UserDefaults.standard.string(forKey: hostKey) ?? defaultHost)
            .trimmingCharacters(in: .whitespaces)
        return URL(string: s.isEmpty ? defaultHost : s) ?? URL(string: defaultHost)!
    }

    /// Whether the network relay may be contacted for a presentation drop.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) != nil
            ? UserDefaults.standard.bool(forKey: enabledKey)
            : true
    }
}
