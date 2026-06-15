// A pre-tap "is your device actually ready" sheet, shown before
// Maknoon opens BLE to a Ledger or Trezor. The friction trade is
// deliberate: a single extra tap up front saves the user from the
// cryptic `0x6E00 CLA not supported` (wrong on-device app) or
// `Ledger disconnected` (device asleep) errors that the actual APDU
// path surfaces, and gives them a clear chance to unlock the device
// and open the right app before the BLE timer starts.
//
// YubiKey is intentionally not gated by this sheet: tap-to-NFC with a
// FIDO2 PIN already is the gating action, and adding a confirmation
// sheet on top would make every YubiKey flow two-tap.
//
// The sheet itself is pure UI. Call sites own the state machine: set
// `pendingReadiness` to a `PendingHardwareOperation` value (which is
// Identifiable) and the sheet appears via `.sheet(item:)`. On
// Continue, the sheet dismisses and the existing async hardware work
// runs unchanged.

import SwiftUI

/// What the device is about to be asked to do. Drives the on-device
/// app name the user should open and the per-purpose hint copy.
enum HardwareOperationPurpose: Hashable, Sendable {
    case bitcoinWallet(network: BitcoinNetwork)
    case bitcoinDiscover(network: BitcoinNetwork)
    case ethereumWallet
    case ethereumDiscover
    case ethereumSign
    case solanaWallet
    case solanaDiscover
    case solanaSign
    case tronWallet
    case tronDiscover
    case tronSign
    case identitySandwichUnlock
    case identitySandwichEnroll
    case identitySandwichDemote
}

/// Carries the device + purpose into the sheet via `.sheet(item:)`.
/// A fresh `id` per presentation so re-presenting the sheet for the
/// same device + purpose still triggers SwiftUI to redisplay.
struct PendingHardwareOperation: Identifiable, Hashable {
    let id = UUID()
    let device: RegisteredDevice
    let purpose: HardwareOperationPurpose
}

extension HardwareOperationPurpose {
    /// Whether the pre-tap sheet should run for a given device kind.
    /// YubiKey is gated by NFC tap + PIN already; SeedSigner is
    /// air-gapped and never reaches BLE.
    static func shouldPresent(for kind: DeviceKind) -> Bool {
        switch kind {
        case .ledger, .trezor: return true
        case .yubikey, .seedsigner: return false
        }
    }
}

struct DeviceReadyConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let device: RegisteredDevice
    let purpose: HardwareOperationPurpose
    /// When true, a hidden (host-entry) wallet is being signed: show the
    /// passphrase field here and require it before Continue. The typed
    /// value is handed back via `onPassphrase` and never stored.
    var requiresPassphrase: Bool = false
    let onContinue: () -> Void
    let onCancel: () -> Void
    /// Called with the passphrase the user typed, just before
    /// `onContinue`, when `requiresPassphrase` is set. Nil otherwise.
    var onPassphrase: ((String) -> Void)? = nil

    /// Re-typed each presentation; the sheet is rebuilt by
    /// `.sheet(item:)` so this never carries over between signings.
    @State private var passphrase: String = ""

    private var passphraseMissing: Bool {
        requiresPassphrase
            && passphrase.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: device.kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(.indigo)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.label).font(.callout.weight(.semibold))
                            Text("\(device.kind.displayName) · \(device.serialDisplay)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text(instructions)
                        .font(.callout)
                }
                if requiresPassphrase {
                    Section {
                        SecureField("Hidden-wallet passphrase", text: $passphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                    } header: {
                        Text("Hidden wallet")
                    } footer: {
                        Text("Re-enter this hidden wallet's passphrase to sign. It is never saved.")
                            .font(.caption)
                    }
                }
                Section {
                    Text(timeoutHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Prepare Device")
            .navigationBarTitleDisplayMode(.inline)
            // Half-sheet popup so this feels closer to an alert than
            // a full-screen takeover, while still preserving the
            // device serial + per-purpose app reminder. On iPad / in
            // landscape SwiftUI falls back to a normal sheet, which
            // is fine.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Continue") {
                        if requiresPassphrase { onPassphrase?(passphrase) }
                        onContinue()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(passphraseMissing)
                }
            }
        }
    }

    private var instructions: String {
        switch device.kind {
        case .ledger:
            switch purpose {
            case .bitcoinWallet(let network), .bitcoinDiscover(let network):
                let appName = network == .mainnet ? "Bitcoin" : "Bitcoin Test"
                return "Unlock your Ledger and open the \(appName) app. The device should show the BTC home screen. Tap Continue when ready."
            case .ethereumWallet, .ethereumDiscover, .ethereumSign:
                return "Unlock your Ledger and open the Ethereum app. Tap Continue when ready."
            case .solanaWallet, .solanaDiscover, .solanaSign:
                return "Unlock your Ledger and open the Solana app. The device should show the SOL home screen. Tap Continue when ready."
            case .tronWallet, .tronDiscover, .tronSign:
                return "Unlock your Ledger and open the Tron app. The device should show the TRX home screen. Tap Continue when ready."
            case .identitySandwichUnlock, .identitySandwichEnroll, .identitySandwichDemote:
                return "Unlock your Ledger and open the Ethereum app. The wrap signature uses Ethereum personal_sign, so the Ethereum app is what Maknoon talks to. Tap Continue when ready."
            }
        case .trezor:
            return "Unlock your Trezor. Tap Continue when ready."
        case .yubikey:
            return "Tap the YubiKey to the top of the phone when iOS shows the NFC sheet."
        case .seedsigner:
            return "SeedSigner is air-gapped and does not connect over BLE."
        }
    }

    private var timeoutHint: String {
        switch device.kind {
        case .ledger, .trezor:
            return "The device has ~30 seconds to respond once Maknoon connects. If the BLE link drops or the app times out, you can retry."
        case .yubikey:
            return "iOS holds the NFC session open for ~60 seconds."
        case .seedsigner:
            return ""
        }
    }
}
