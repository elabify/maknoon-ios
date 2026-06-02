// Full-screen lock overlay. Renders on top of the entire app
// (sheets, alerts, navigation) when AutoLockManager.isLocked is
// true. Auto-presents the LAContext biometric prompt on appear;
// if the user cancels or the prompt fails, a Try Again button
// re-issues the prompt.

import SwiftUI

struct LockScreen: View {
    @Environment(AutoLockManager.self) private var autoLock
    @State private var attemptInFlight = false
    @State private var lastFailed = false

    var body: some View {
        ZStack {
            // Solid background so nothing behind us bleeds through
            // even at the system-background corners.
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)

                VStack(spacing: 6) {
                    Text("Maknoon is locked")
                        .font(.title2.weight(.semibold))
                    if lastFailed {
                        Text("Authentication needed to continue.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Re-authenticate to continue.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await tryUnlock() }
                } label: {
                    HStack(spacing: 8) {
                        if attemptInFlight {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Label(lastFailed ? "Try again" : "Unlock", systemImage: "faceid")
                            .font(.headline)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .disabled(attemptInFlight)
                .accessibilityLabel(lastFailed ? "Try again" : "Unlock")

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .task {
            // First tap of the lock screen auto-issues the prompt;
            // .task is a fresh attempt every time the screen appears.
            await tryUnlock()
        }
    }

    private func tryUnlock() async {
        guard !attemptInFlight else { return }
        attemptInFlight = true
        let ok = await autoLock.attemptUnlock()
        attemptInFlight = false
        if !ok { lastFailed = true }
    }
}
