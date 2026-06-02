// Backup reminder banner + the verify-from-banner sheet it opens.
//
// Shown at the top of the Identity tab when the user has not yet
// verified their 24-word recovery phrase and the weekly reminder window
// has elapsed. Tapping the banner opens a sheet that walks them through
// the verification flow with `allowSkip: false` so they cannot dismiss
// the reminder by skipping.

import SwiftUI

struct BackupReminderBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verify your recovery phrase")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("You skipped phrase verification at setup. Tap here to confirm your offline backup is correct.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct VerifyFromBannerSheet: View {
    let store: HolderStore
    let onClose: () -> Void

    @State private var words: [String]?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let words {
                    VerifyPhraseView(
                        words: words,
                        allowSkip: false,
                        onVerified: {
                            try? BackupState.markVerified()
                            onClose()
                        },
                        onSkipped: { onClose() },
                        onReReveal: { /* phrase reveal lives in Settings */ }
                    )
                    .padding(.horizontal, 16)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Button("Close") { onClose() }
                    }
                    .padding()
                } else {
                    ProgressView().task { await load() }
                }
            }
            .navigationTitle("Verify recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    @MainActor
    private func load() async {
        guard let sandwich = store.sandwich else {
            errorMessage = "Wallet not loaded"
            return
        }
        do {
            let material = try sandwich.recoveryMaterial(localizedReason: "Verify recovery phrase")
            words = material.words
        } catch {
            errorMessage = "Could not load recovery phrase: \(error)"
        }
    }
}
