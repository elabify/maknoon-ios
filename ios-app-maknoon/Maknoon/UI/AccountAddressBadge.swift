// Shared identity badge for every account-based blockchain dashboard
// (Ethereum, Solana today; Tron and future EVM chains tomorrow).
// Renders "Account #N · 7XmK…3Y4f" with a copy button that
// shows a transient checkmark when the address is on the pasteboard.
//
// Lives in `Maknoon/UI/` rather than under any per-chain folder so
// the convention is obvious: any new account-based chain should drop
// `AccountAddressBadge(accountIndex:, address:)` directly under its
// balance card and inherit the same look + copy behaviour without
// reinventing the shorten/copy/feedback dance.

import SwiftUI
import UIKit

struct AccountAddressBadge: View {
    /// BIP44-style account index. Kept on the API for source compat
    /// with existing call sites, but no longer rendered, the
    /// wallet picker above the badge already shows the account
    /// number (e.g. "Account 0") in its subtitle.
    let accountIndex: UInt32?
    /// Full address. Rendered in full here so the user can read
    /// (and visually verify) the whole string at a glance; the
    /// copy button puts the same full string on the pasteboard.
    let address: String

    /// Brief "Copied" affordance after a successful tap. Self-resets
    /// after 1.5s so a second tap is unambiguous.
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(address)
                .font(.caption.monospaced())
                // Primary instead of tertiary so the address is
                // actually legible in dark mode without
                // squinting. The container's thin-material
                // background carries the visual hierarchy already.
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: copyToClipboard) {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(justCopied ? .green : Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(justCopied ? "Address copied" : "Copy address")
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = address
        // Light haptic so the user gets a physical "yep, it copied"
        // confirmation even before looking at the icon flip.
        UISelectionFeedbackGenerator().selectionChanged()
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            justCopied = false
        }
    }
}
