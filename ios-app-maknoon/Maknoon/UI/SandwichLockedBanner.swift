// Shared "Identity Sandwich is locked" banner. Shown at the top of
// every account-based wallet dashboard (Bitcoin, Ethereum, Solana,
// Tron) when:
//
//   1. The Identity Sandwich is locked (store.sandwich == nil), AND
//   2. The active wallet is software-backed (hardware wallets cache
//      their address + sign via the device, so they don't need the
//      sandwich to operate).
//
// The "Unlock with hardware device" button triggers the existing
// ContentView-level `HardwareUnlockView` sheet via
// `store.showHardwareUnlock = true`, the same affordance the Add-
// wallet sheets already use. Keeping the trigger uniform here means
// any chain that adopts this banner inherits the same unlock flow
// without duplicating sheet plumbing per dashboard.

import SwiftUI

struct SandwichLockedBanner: View {
    @Environment(HolderStore.self) private var store
    /// Whether to render. Callers pass `store.sandwich == nil &&
    /// activeWalletIsSoftware` so the banner stays out of the way on
    /// hardware wallets and on cold-launch states with no wallets.
    let visible: Bool

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text("Identity Sandwich is locked")
                        .font(.subheadline.weight(.semibold))
                }
                Text("This software wallet's seed is sealed by your enrolled hardware devices. Balance is read-only until you unlock; Send fails. Tap below to unlock with any enrolled device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.showHardwareUnlock = true
                } label: {
                    Label("Unlock with hardware device", systemImage: "key.radiowaves.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
    }
}
