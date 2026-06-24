// A masked text entry with a trailing eyeball that toggles visibility.
//
// Used for every secret the user types: the onboarding password, and
// every hardware-wallet PIN / passphrase / pairing code (so a typo can
// always be checked before submitting). Mirrors the inline reveal pattern
// the Trezor passphrase selector already shipped, extracted so there is one
// implementation.

import SwiftUI
import UIKit

struct RevealableSecureField: View {
    var placeholder: String = ""
    @Binding var text: String
    /// Numeric PINs/codes use `.numberPad`; passphrases stay `.default`.
    var keyboardType: UIKeyboardType = .default
    /// Submit label + action for single-field forms (optional).
    var onSubmit: (() -> Void)?

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .keyboardType(keyboardType)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit { onSubmit?() }

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide" : "Show")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }
}

/// A small modal for entering a hardware-wallet PIN with a reveal toggle. Used
/// where a PIN prompt would otherwise be a SwiftUI `.alert`, which cannot host an
/// eyeball button. Submit/Cancel mirror the alert's actions.
struct PINEntrySheet: View {
    let title: String
    let message: String
    @Binding var pin: String
    var submitLabel: String = "Continue"
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RevealableSecureField(placeholder: "PIN", text: $pin, keyboardType: .numberPad)
                } footer: {
                    Text(message)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel) { onSubmit(); dismiss() }
                }
            }
        }
        .presentationDetents([.height(240)])
    }
}
