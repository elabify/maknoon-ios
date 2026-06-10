// Receive credential sheet. Opened from the Identity tab's "+" toolbar
// menu. Default mode is live QR scanning. The user can switch to manual
// URL paste at any time, or — if they have denied camera permission —
// is shown a clear remediation path with an "Open Settings" deep link.
//
// Polling handles the `pending_anchor` window from ADR-0022 (batch
// anchoring) by retrying every 10 s up to ~5 minutes, surfacing a status
// banner so the user sees progress.

import SwiftUI

struct ReceiveSheet: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    enum Mode: Equatable { case scan, manual }

    enum Phase: Equatable {
        case idle
        case fetching
        case pending(attempt: Int, etaSeconds: Int?)
        case error(String)
    }

    @State private var mode: Mode = .scan
    @State private var permission: CameraPermissionState = CameraPermission.current
    @State private var pickupURL: String = ""
    @State private var phase: Phase = .idle
    @State private var pollTask: Task<Void, Never>?
    /// Trust-prompt sheet state. When the user attempts to fetch
    /// from an issuer not in the known list, we stash the parsed
    /// URL here and pop a confirmation. On approve, we proceed
    /// once (without persisting the issuer to the known list).
    @State private var pendingUntrustedURL: URL?
    @State private var showUntrustedPrompt: Bool = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Receive credential")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            pollTask?.cancel()
                            dismiss()
                        }
                    }
                }
                .confirmationDialog(
                    untrustedPromptTitle,
                    isPresented: $showUntrustedPrompt,
                    titleVisibility: .visible
                ) {
                    Button("Trust once and fetch") {
                        if let url = pendingUntrustedURL {
                            startFetch(url: url)
                        }
                        pendingUntrustedURL = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingUntrustedURL = nil
                    }
                } message: {
                    Text("Maknoon doesn't recognise \(pendingUntrustedURL?.host ?? "this host") as a trusted issuer. Anything served from this URL is delivered to your identity. Only continue if you initiated this issuance and trust the operator. To trust an issuer permanently, add it under Settings → Identity → Known issuers.")
                }
        }
        .task {
            if permission == .notDetermined {
                permission = await CameraPermission.request()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check permission when the user returns from Settings.
            if newPhase == .active { permission = CameraPermission.current }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: -- root content router

    @ViewBuilder
    private var content: some View {
        switch (mode, phase) {
        case (.scan, .idle):
            scanScreen
        case (.manual, .idle), (.manual, .error):
            manualScreen
        default:
            statusScreen
        }
    }

    // MARK: -- scan screen

    private var scanScreen: some View {
        VStack(spacing: 0) {
            Group {
                switch permission {
                case .notDetermined:
                    permissionLoading
                case .authorized:
                    scannerWithOverlay
                case .denied:
                    permissionDenied
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Button(action: { mode = .manual }) {
                Label("Paste a URL instead", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.black.ignoresSafeArea(edges: .top))
    }

    private var permissionLoading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Requesting camera access…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var scannerWithOverlay: some View {
        ZStack {
            QRScannerView(onCode: handleScannedCode)
                .ignoresSafeArea(edges: .top)

            // Translucent rule-of-thirds reticle to give the user a
            // target. The scanner accepts QRs anywhere in the frame —
            // this is purely a visual cue.
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.65), lineWidth: 3)
                    .frame(width: 240, height: 240)
                Spacer()
                Text("Point at the issuer's QR code")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                QRPhotoPickerButton(onCode: handleScannedCode, onNoQR: noQRFound)
                    .padding(.bottom, 24)
            }
        }
    }

    private func noQRFound() {
        phase = .error("No QR code found in that image.")
        mode = .manual
    }

    private var permissionDenied: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("QR scanning is disabled")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Maknoon does not have permission to use the camera. Open Settings, enable Camera for Maknoon, then return to (or relaunch) the app.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            QRPhotoPickerButton(onCode: handleScannedCode, onNoQR: noQRFound) {
                Label("Choose a QR photo instead", systemImage: "photo.on.rectangle")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 32)
        }
    }

    // MARK: -- manual screen

    private var manualScreen: some View {
        Form {
            Section {
                TextField("https://issuer.example.com/v1/issuance/pickup/…",
                          text: $pickupURL, axis: .vertical)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...6)

                Button(action: startManualFetch) {
                    Text("Fetch credential").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickupURL.isEmpty)
            } header: {
                Text("Paste a pickup URL")
            } footer: {
                Text("Pickup URLs from trusted issuers fetch silently. Unknown hosts will ask for one-time trust before any network call. Manage the trusted list under Settings → Identity.")
                    .font(.caption)
            }

            if case .error(let message) = phase {
                Section("Receive error") {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    phase = .idle
                    pickupURL = ""
                    mode = .scan
                } label: {
                    Label("Scan a QR code instead", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            // On entering the manual paste screen, auto-fill from
            // the clipboard if the user hasn't typed anything yet.
            // iOS shows a brief "Maknoon pasted from clipboard"
            // banner, which is the expected affordance.
            if pickupURL.isEmpty, let clip = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !clip.isEmpty {
                pickupURL = clip
            }
        }
    }

    // MARK: -- status screen (fetching / pending)

    private var statusScreen: some View {
        Form {
            switch phase {
            case .fetching:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Fetching from issuer…")
                    }
                    .padding(.vertical, 4)
                }
            case .pending(let attempt, let etaSeconds):
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            // M2 / ADR-0030: networks are now per-credential and
                            // multi-chain (PickupResponse.networkAvailability is
                            // decodable for a future per-network list); avoid the
                            // hardcoded chain name.
                            Text("Waiting for the issuer to anchor this credential…")
                                .font(.callout.weight(.medium))
                            Text(pendingDetail(attempt: attempt, etaSeconds: etaSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button(role: .destructive, action: cancelPolling) {
                        Text("Cancel waiting").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            case .error(let message):
                Section("Receive error") {
                    Text(message).font(.callout).foregroundStyle(.red)
                    Button("Try again") {
                        phase = .idle
                        mode = .scan
                    }
                    .buttonStyle(.bordered)
                }
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: -- actions

    private func handleScannedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            phase = .error("Scanned code is not a pickup URL.")
            mode = .manual
            pickupURL = trimmed
            return
        }
        pickupURL = trimmed
        attemptFetch(url: url)
    }

    private func startManualFetch() {
        let trimmed = pickupURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            phase = .error("Invalid URL")
            return
        }
        attemptFetch(url: url)
    }

    /// Trust gate. Known issuers fetch immediately; unknown hosts
    /// pop the one-time-trust confirmation before any network call.
    private func attemptFetch(url: URL) {
        if store.knownIssuers.isTrusted(url) {
            startFetch(url: url)
        } else {
            pendingUntrustedURL = url
            showUntrustedPrompt = true
        }
    }

    private func startFetch(url: URL) {
        pollTask?.cancel()
        phase = .fetching
        pollTask = Task { await runPolling(url: url) }
    }

    private var untrustedPromptTitle: String {
        "Trust \(pendingUntrustedURL?.host ?? "this issuer")?"
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
        mode = .scan
    }

    private func pendingDetail(attempt: Int, etaSeconds: Int?) -> String {
        if let etaSeconds, etaSeconds > 0 {
            return "Batch flushes every \(etaSeconds)s. Attempt \(attempt), retrying automatically."
        }
        return "Attempt \(attempt). Retrying every 10s until the batch flushes."
    }

    private func runPolling(url: URL) async {
        let maxAttempts = 30
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }
            do {
                let outcome = try await IssuerClient.pickup(url: url)
                if Task.isCancelled { return }
                switch outcome {
                case .ready(let cred):
                    await onReady(cred)
                    return
                case .pending(let eta):
                    let etaSeconds = eta.map { max(0, Int($0 - Int64(Date().timeIntervalSince1970))) }
                    phase = .pending(attempt: attempt, etaSeconds: etaSeconds)
                }
            } catch {
                if Task.isCancelled { return }
                phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
        phase = .error("Timed out after \(maxAttempts) attempts. The issuer's batch may be stuck — try `curl -X POST <issuer>/v1/admin/anchor/flush` to force a flush.")
    }

    @MainActor
    private func onReady(_ cred: Credential) async {
        store.addCredential(cred)
        pickupURL = ""
        phase = .idle
        try? await Task.sleep(nanoseconds: 250_000_000)
        dismiss()
    }
}
