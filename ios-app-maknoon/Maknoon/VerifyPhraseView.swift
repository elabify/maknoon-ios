// Phrase-verification view, reused by the onboarding flow and by the
// weekly reminder banner.
//
// Picks three non-adjacent word positions (one each from the top, middle,
// and bottom thirds of the phrase) and asks the user to type the
// matching word. On success: invokes the `onVerified` callback (caller
// records the verifiedAt timestamp). On failure: shows a brief error
// and lets the user re-attempt. A Skip button is shown when the
// `allowSkip` flag is set (true at onboarding, false in the
// weekly-reminder flow where the user really should verify).

import SwiftUI

struct VerifyPhraseView: View {
    let words: [String]
    let allowSkip: Bool
    let onVerified: () -> Void
    let onSkipped: () -> Void
    let onReReveal: () -> Void

    private struct Challenge {
        let positions: [Int]   // 1-based for display, 0-based for lookup
    }

    @State private var challenge: Challenge = Challenge(positions: [])
    @State private var inputs: [String] = ["", "", ""]
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Confirm your recovery phrase")
                    .font(.title3.weight(.semibold))

                Text("Enter the word at each position. We pick three positions at random so you can prove you copied the phrase correctly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 14) {
                    ForEach(Array(challenge.positions.enumerated()), id: \.offset) { idx, pos in
                        wordRow(index: idx, position: pos)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Button(action: verify) {
                    Text("Verify")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputs.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }))

                // "Back" returns to the reveal screen so the user can
                // re-read their 24 words. Replaces the older "Show
                // phrase again" label which testers found ambiguous
                // (sometimes read as "show me the answers").
                Button(action: onReReveal) {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if allowSkip {
                    Button(action: onSkipped) {
                        Text("Skip for now (we will remind you in 7 days)")
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            if challenge.positions.isEmpty { challenge = newChallenge() }
        }
    }

    private func wordRow(index: Int, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Word #\(position)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $inputs[index])
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.callout, design: .monospaced))
        }
    }

    private func verify() {
        for (i, pos) in challenge.positions.enumerated() {
            let typed = inputs[i].lowercased().trimmingCharacters(in: .whitespaces)
            let expected = words[pos - 1].lowercased()
            if typed != expected {
                errorMessage = "Word #\(pos) does not match. Tap Back to re-read your recovery phrase."
                return
            }
        }
        errorMessage = nil
        onVerified()
    }

    private func newChallenge() -> Challenge {
        // One position from the top third (1-8), middle third (9-16),
        // bottom third (17-24). Ensures coverage across the phrase
        // (memorising just the first three words won't pass).
        let a = Int.random(in: 1...8)
        let b = Int.random(in: 9...16)
        let c = Int.random(in: 17...24)
        return Challenge(positions: [a, b, c])
    }
}

