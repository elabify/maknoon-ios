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
    /// When true (Trezor ADD / DISCOVER, ADR-0033), this sheet is the
    /// connection step that collects the hidden-wallet passphrase choice
    /// (None / On Device / Type Here + masked field). The ONE choice
    /// applies to BOTH adding and discovering; it is handed back via
    /// `onPassphraseSelection` just before `onContinue`. Continue is
    /// disabled until a Type-Here passphrase is non-empty. Ledger never
    /// sets this (its passphrase lives on the device).
    var showsPassphraseSelector: Bool = false
    /// When true, the user has confirmed and a BLE signature is in flight: the
    /// sheet shows a "waiting for your device" spinner instead of the form and
    /// cannot be dismissed. Used by the mini-app hardware-sign flow to keep the
    /// sheet up across the device sign; other call sites leave it false.
    var signing: Bool = false
    /// When true (default), Continue dismisses the sheet itself. The mini-app
    /// hardware-sign flow passes false so its coordinator keeps the sheet up
    /// (switching it to the signing phase) until the sign completes.
    var dismissesOnContinue: Bool = true
    let onContinue: () -> Void
    let onCancel: () -> Void
    /// Called with the passphrase the user typed, just before
    /// `onContinue`, when `requiresPassphrase` is set. Nil otherwise.
    var onPassphrase: ((String) -> Void)? = nil
    /// Called with the chosen hidden-wallet selection + host-typed
    /// passphrase, just before `onContinue`, when `showsPassphraseSelector`
    /// is set. Nil otherwise. The secret is never stored.
    var onPassphraseSelection: ((HiddenWalletSelection, String) -> Void)? = nil

    /// Re-typed each presentation; the sheet is rebuilt by
    /// `.sheet(item:)` so this never carries over between signings.
    @State private var passphrase: String = ""
    /// Trezor connection-step hidden-wallet choice + masked passphrase.
    @State private var selection: HiddenWalletSelection = .standard
    @State private var selectionPassphrase: String = ""
    @State private var revealSelectionPassphrase: Bool = false

    private var passphraseMissing: Bool {
        requiresPassphrase
            && passphrase.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectionNotReady: Bool {
        showsPassphraseSelector
            && !selection.isReady(hostPassphrase: selectionPassphrase)
    }

    var body: some View {
        if signing {
            signingBody
        } else {
            readyBody
        }
    }

    /// Shown while the BLE signature is in flight (mini-app flow only). The sheet
    /// stays up and non-dismissable so the mini-app's own progress text is not
    /// revealed until the signature is done.
    private var signingBody: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Waiting for your \(device.kind.displayName)…")
                    .font(.callout.weight(.medium))
                Text(signingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Signing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    private var signingHint: String {
        switch device.kind {
        case .ledger: return "Confirm the request on your Ledger."
        case .trezor: return "Confirm the request on your Trezor. Enter the PIN if it asks."
        default: return "Confirm the request on your device."
        }
    }

    private var readyBody: some View {
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
                        RevealableSecureField(placeholder: "Hidden-wallet passphrase", text: $passphrase)
                    } header: {
                        Text("Hidden wallet")
                    } footer: {
                        Text("Re-enter this hidden wallet's passphrase to sign. It is never saved.")
                            .font(.caption)
                    }
                }
                if showsPassphraseSelector {
                    Section {
                        Picker("Passphrase", selection: $selection) {
                            ForEach(HiddenWalletSelection.allCases) { mode in
                                Text(selectorLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if selection == .hostTyped {
                            HStack {
                                Group {
                                    if revealSelectionPassphrase {
                                        TextField("Passphrase", text: $selectionPassphrase)
                                    } else {
                                        SecureField("Passphrase", text: $selectionPassphrase)
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                Button {
                                    revealSelectionPassphrase.toggle()
                                } label: {
                                    Image(systemName: revealSelectionPassphrase ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text("Wake your \(device.kind.displayName) and approve the prompt when it appears, then tap Continue. A hidden-wallet passphrase opens a different wallet, so it applies to both adding and discovering.")
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
            // is fine. When a passphrase field is shown, open fully
            // (.large) so the "type here" field + copy below the picker
            // are not hidden under a medium detent.
            .presentationDetents(
                (showsPassphraseSelector || requiresPassphrase) ? [.large] : [.medium, .large]
            )
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
                        if showsPassphraseSelector {
                            onPassphraseSelection?(selection, selectionPassphrase)
                        }
                        onContinue()
                        // The mini-app hardware-sign flow keeps the sheet up
                        // (switching it to the signing phase) and dismisses it
                        // itself once the sign finishes.
                        if dismissesOnContinue { dismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(passphraseMissing || selectionNotReady)
                }
            }
        }
    }

    /// ADR-0033 UI-layer labels for the hidden-wallet selector chips:
    /// None / On Device / Type Here (the SDK enum's Standard / On device /
    /// Type here, remapped for the agreed copy without touching semantics).
    private func selectorLabel(_ mode: HiddenWalletSelection) -> String {
        switch mode {
        case .standard:  return "None"
        case .onDevice:  return "On Device"
        case .hostTyped: return "Type Here"
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
