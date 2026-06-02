// Shared building blocks for the per-chain Send views. Every
// account-based chain (Bitcoin, Ethereum, Solana, Tron, future) drops
// the same set of widgets at the top of its send screen so the user
// gets a consistent shape:
//
//   On: [NetworkChipLabel]
//   Recipient (with ChainScanSheet for QR)
//   Amount
//   Review (one ReviewRow per line; Network highlighted via the
//           chip variant)
//   Primary action (PulseBroadcastButton at the "signed, awaiting
//                   broadcast" state on the hardware path)
//
// Originally lived inside `TronSendView` as fileprivate types while
// the pattern was being road-tested; promoted here so Solana +
// Ethereum send views can adopt the same shape without duplicating
// hundreds of lines.

import SwiftUI
import UIKit

/// Dismiss the on-screen keyboard. Used by the send-view hardware
/// flows: after the user taps Continue on `DeviceReadyConfirmationSheet`
/// the amount-input text field is still first responder, so iOS
/// would otherwise yank the scroll position back to the amount
/// row when the keyboard reappears. Calling this immediately before
/// the state transition lets the ScrollViewReader land on the
/// "Signing on <device>" / Broadcast button area cleanly.
@MainActor
func dismissSendViewKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}

/// "On: [network]" chip. Background-tinted by the chain's accent.
/// Used both standalone at the top of a send view and inside
/// `ReviewRow` for the Network field.
struct NetworkChipLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

/// One row of a Review section. Highlights via a `NetworkChipLabel`
/// when `highlightTint` is non-nil (used by the Network row);
/// otherwise renders the value in a plain monospaced style with an
/// optional fiat caption beneath.
struct ReviewRow: View {
    let label: String
    let value: String
    var subValue: String? = nil
    var highlightTint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let tint = highlightTint {
                    NetworkChipLabel(text: value, tint: tint)
                } else {
                    Text(value)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if let subValue {
                    Text(subValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Broadcast button that subtly pulses to flag the user that they
/// need to tap. Pulses the shadow + a soft glow so the motion is
/// noticeable without being jittery. Use at the "signed, awaiting
/// broadcast" interstitial state on hardware send flows.
struct PulseBroadcastButton: View {
    let title: String
    let action: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "paperplane.fill")
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .shadow(color: .accentColor.opacity(pulse ? 0.6 : 0.0), radius: pulse ? 14 : 0)
        .scaleEffect(pulse ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/// Minimal QR scanner sheet for the Send view. Wraps the existing
/// `QRScannerView` (used by the credential receive flow) in a
/// dismissable navigation stack with a Cancel button. `onScan` is
/// invoked with the decoded payload; the caller dismisses by
/// clearing whatever state drives the `.sheet(isPresented:)`.
struct ChainScanSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onCode: onScan)
                .ignoresSafeArea()
                .navigationTitle("Scan address")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}
