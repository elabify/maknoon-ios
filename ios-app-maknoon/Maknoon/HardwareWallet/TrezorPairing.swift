// Bridges the Rust `PairingCodeProvider` callback to a SwiftUI prompt.
//
// During CodeEntry pairing the Trezor shows a 6-digit code on its
// screen and the Rust pairing flow calls `requestCode()` to get it.
// The coordinator flips `awaitingCode`, a sheet appears, and the
// user's input resumes the suspended async call.

import SwiftUI

final class TrezorPairingCoordinator: ObservableObject, PairingCodeProvider, @unchecked Sendable {
    @Published var awaitingCode = false

    private var continuation: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    /// Called by the Rust pairing flow (off the main actor) when the
    /// device displays its code. Suspends until the user submits.
    func requestCode() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            DispatchQueue.main.async { self.awaitingCode = true }
        }
    }

    /// Resume pairing with the entered code.
    func submit(_ code: String) {
        DispatchQueue.main.async { self.awaitingCode = false }
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: code.trimmingCharacters(in: .whitespaces))
    }

    /// User dismissed the prompt; an empty code tells Rust to abort.
    func cancel() { submit("") }
}

struct TrezorCodeEntrySheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the 6-digit pairing code shown on your Trezor.")
                        .font(.callout)
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.title, design: .monospaced))
                } header: {
                    Text("Pairing code")
                }
            }
            .navigationTitle("Pair Trezor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair") { onSubmit(code) }
                        .disabled(code.filter(\.isNumber).count < 6)
                }
            }
            .interactiveDismissDisabled(true)
        }
    }
}
