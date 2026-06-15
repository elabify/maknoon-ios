// Trezor hidden (BIP39 passphrase) wallet support, app-side model.
//
// On a Trezor the passphrase is a PER-SESSION value, not a device-
// stored, PIN-protected secret. Each distinct passphrase yields a
// different seed, hence different addresses, hence a distinct "hidden"
// wallet that coexists with the standard (empty-passphrase) wallet.
// Ledger has no analog: its passphrase lives on the device and is
// opaque to the host, so Ledger wallets are always "standard" and
// these types never touch the Ledger path.
//
// We intentionally NEVER persist a host-typed passphrase. A hidden
// wallet only records HOW its passphrase is entered, and the secret is
// supplied fresh at every signing:
//
//   * `PassphraseChoice` is the transient in-memory value handed to
//     `TrezorBLE.applyPassphraseMode(_:)` for one operation.
//   * `HardwarePassphraseRef` is what gets persisted on a descriptor:
//     `nil` = standard wallet, `.onDevice` = passphrase entered on the
//     Trezor each time, `.hostEntry` = passphrase re-typed on the phone
//     each time (no secret is stored anywhere).

import Foundation

/// The passphrase mode chosen for a single operation. In-memory only.
enum PassphraseChoice: Equatable, Sendable {
    /// Standard wallet, empty passphrase. Identical to Ledger behavior.
    case standard
    /// User types the passphrase on the Trezor; the phone never sees it.
    case onDevice
    /// User typed the passphrase on the host for this operation.
    case hostTyped(String)
}

/// Persisted on a hardware wallet descriptor. `nil` (absent) means the
/// standard wallet. It records only the ENTRY METHOD for a hidden
/// wallet, never the passphrase itself.
enum HardwarePassphraseRef: Codable, Hashable, Sendable {
    /// Passphrase is re-entered on the Trezor each session.
    case onDevice
    /// Passphrase is re-typed on the phone at each signing (not stored).
    case hostEntry

    /// Whether signing this wallet needs a host-typed passphrase entered
    /// up front (the send UI shows a passphrase field; on-device entry
    /// and standard wallets don't need one).
    var needsHostPassphrase: Bool { self == .hostEntry }

    /// Resolve a persisted binding to the in-memory passphrase choice a
    /// signing op opens its session with. `hostEntered` is the
    /// passphrase the user just typed for THIS signing (never stored);
    /// it is required for `.hostEntry` and ignored otherwise.
    static func resolveChoice(
        _ hidden: HardwarePassphraseRef?,
        hostEntered: String? = nil
    ) throws -> PassphraseChoice {
        switch hidden {
        case .none:
            return .standard
        case .onDevice:
            return .onDevice
        case .hostEntry:
            let pass = hostEntered?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !pass.isEmpty else {
                throw HardwareWalletError.transport(
                    "Enter this hidden wallet's passphrase to sign."
                )
            }
            return .hostTyped(pass)
        }
    }

    /// The persisted binding for a wallet being added under `selection`.
    /// Records only the entry method; no secret is written anywhere.
    static func persist(selection: HiddenWalletSelection) -> HardwarePassphraseRef? {
        switch selection {
        case .standard:  return nil
        case .onDevice:  return .onDevice
        case .hostTyped: return .hostEntry
        }
    }
}

// Custom Codable: encode as a simple discriminator string and decode
// tolerantly. This keeps wallets created by the earlier build (which
// persisted `.onDevice` / `.hostStored(keychainId:)`) loading cleanly —
// a legacy `hostStored` maps to `.hostEntry` (its Keychain copy is just
// abandoned), so descriptors never fail to decode.
extension HardwarePassphraseRef {
    private enum LegacyKey: String, CodingKey {
        case onDevice, hostEntry, hostStored
    }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = (s == "onDevice") ? .onDevice : .hostEntry
            return
        }
        // Legacy synthesized-enum object form: {"onDevice":{}} /
        // {"hostStored":{...}} / {"hostEntry":{}}.
        let c = try decoder.container(keyedBy: LegacyKey.self)
        self = c.contains(.onDevice) ? .onDevice : .hostEntry
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .onDevice:  try c.encode("onDevice")
        case .hostEntry: try c.encode("hostEntry")
        }
    }
}

/// The hidden-wallet selector shown in the Trezor add / discovery flows.
/// `.standard` reproduces exact Ledger behavior (empty passphrase) and
/// is the default everywhere.
enum HiddenWalletSelection: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case onDevice = "On device"
    case hostTyped = "Type here"
    var id: String { rawValue }

    /// Transient choice handed to `TrezorBLE.applyPassphraseMode(_:)`
    /// for one operation, carrying the typed passphrase in memory only.
    func choice(hostPassphrase: String) -> PassphraseChoice {
        switch self {
        case .standard:  return .standard
        case .onDevice:  return .onDevice
        case .hostTyped: return .hostTyped(hostPassphrase)
        }
    }

    /// Whether the choice is actionable yet (host-typed needs text).
    func isReady(hostPassphrase: String) -> Bool {
        self != .hostTyped || !hostPassphrase.isEmpty
    }

    /// Human-readable explanation for the selector footer.
    var footer: String {
        switch self {
        case .standard:
            return "The standard wallet, no passphrase. This is what you normally use."
        case .onDevice:
            return "Open a hidden wallet by typing its passphrase on the Trezor. The phone never sees it. A different passphrase is a different wallet."
        case .hostTyped:
            return "Type the hidden-wallet passphrase here. It is never saved: you re-enter it on this phone for every signing. A different passphrase is a different wallet."
        }
    }
}
