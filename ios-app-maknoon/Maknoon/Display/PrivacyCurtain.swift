// Privacy curtain — covers the UI when the app is inactive so the
// iOS task switcher snapshot doesn't expose wallet balances /
// credential cards / passport photos. Stays neutral (logo + name)
// so users can still recognise the app in the switcher.

import SwiftUI

struct PrivacyCurtain: View {
    var body: some View {
        ZStack {
            // Match the launch-screen tone so the transition from
            // a foregrounded task back to the running app is visually
            // continuous.
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Maknoon")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
