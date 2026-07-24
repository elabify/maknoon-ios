import SwiftUI

/// A small "?" info affordance for progressive disclosure. Tapping it shows a
/// popover with a plain-language explanation of a term, so a non-expert is
/// never forced to decode jargon inline while an interested user can still see
/// the detail on demand. ADR-0069.
struct HelpChip: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let accessibilityTitle: String

    @State private var showing = false

    init(_ title: LocalizedStringKey, accessibilityTitle: String, message: LocalizedStringKey) {
        self.title = title
        self.accessibilityTitle = accessibilityTitle
        self.message = message
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 300)
            .presentationCompactAdaptation(.popover)
        }
    }
}
