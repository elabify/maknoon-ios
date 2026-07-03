// WalletConnect UI (ADR-0049): the Connections screen (scan / paste a wc: URI
// and list/disconnect active sessions) plus the approval surfaces for an
// incoming session proposal and an incoming sign request.
//
// Presentation routing: the approval sheets are attached at the app root via
// `.walletConnectSheets()` so a request can surface no matter which screen the
// user is on. BUT when the WalletConnect screen is itself open (it is a sheet),
// iOS cannot present another sheet on top of it, so the proposal/sign sheet
// would silently fail to appear. To avoid that, the WalletConnect screen sets
// `wc.screenVisible` and presents the approval sheets ITSELF while it is up; the
// root modifier stands down whenever `screenVisible` is true.

import SwiftUI
import PhotosUI
import CoreImage
import UIKit
import ReownWalletKit

// MARK: Connections screen (reached from the EVM "+" menu)

struct WalletConnectView: View {
    @ObservedObject private var wc = WalletConnectManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var pastedURI = ""
    @State private var diag: [LogStore.Entry] = []
    @State private var photoItem: PhotosPickerItem?

    private func refreshDiag() { diag = LogStore.shared.recent(category: "walletconnect", limit: 25) }

    /// Decode a WalletConnect QR from a picked screenshot and pair with it.
    private func connectFromPickedImage(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let code = Self.decodeQRString(from: data) else {
            showScanner = false
            wc.lastError = "No WalletConnect QR code was found in that image."
            return
        }
        showScanner = false
        await wc.pair(uriString: code)
        refreshDiag()
    }

    /// Pull the first QR payload out of a still image (a saved screenshot).
    private static func decodeQRString(from data: Data) -> String? {
        guard let image = UIImage(data: data), let ciImage = CIImage(image: image) else { return nil }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        for case let qr as CIQRCodeFeature in features {
            if let message = qr.messageString, !message.isEmpty { return message }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan WalletConnect QR", systemImage: "qrcode.viewfinder")
                    }
                    HStack {
                        TextField("or paste wc: link", text: $pastedURI)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect") {
                            let uri = pastedURI.trimmingCharacters(in: .whitespacesAndNewlines)
                            pastedURI = ""
                            Task { await wc.pair(uriString: uri); refreshDiag() }
                        }
                        .disabled(pastedURI.isEmpty)
                    }
                } header: {
                    Text("Connect to an app")
                } footer: {
                    Text("Connects this wallet to an external app over the WalletConnect relay. EVM (Ethereum) only. You approve every request.")
                }

                Section {
                    if wc.sessions.isEmpty {
                        Text("No active connections.").foregroundStyle(.secondary)
                    } else {
                        ForEach(wc.sessions, id: \.topic) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.peer.name.isEmpty ? "Connected app" : session.peer.name)
                                    .font(.callout).fontWeight(.medium)
                                if let url = URL(string: session.peer.url), let host = url.host {
                                    Text(host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await wc.disconnect(topic: session.topic) }
                                } label: { Label("Disconnect", systemImage: "xmark.circle") }
                            }
                        }
                    }
                } header: {
                    Text("Active connections")
                }

                Section {
                    DisclosureGroup("Advanced") {
                        HStack {
                            Image(systemName: wc.relayConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(wc.relayConnected ? .green : .secondary)
                            Text("Relay")
                            Spacer()
                            Text(wc.relayConnected ? "Connected" : "Not connected")
                                .foregroundStyle(wc.relayConnected ? .green : .secondary)
                        }
                        if !diag.isEmpty {
                            ForEach(Array(diag.enumerated()), id: \.offset) { _, entry in
                                Text(entry.message)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(entry.level == .error || entry.level == .warn ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Button {
                            refreshDiag()
                        } label: {
                            Label("Refresh diagnostics", systemImage: "arrow.clockwise")
                        }
                        Text("Relay must read Connected to pair or sign. Tap Refresh after an attempt; share the full log from About if you need help.")
                            .font(.caption).foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            Task { await wc.resetAllConnections(); refreshDiag() }
                        } label: {
                            Label("Reset WalletConnect", systemImage: "arrow.counterclockwise")
                        }
                        Text("Disconnects everything and clears stored connection state. Use this if a connection is stuck or signing with the wrong wallet, then scan a fresh QR.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("WalletConnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { refreshDiag(); wc.screenVisible = true }
            .onDisappear { wc.screenVisible = false }
            // Keep the diagnostics feed live as proposals/requests arrive.
            .onChange(of: wc.pendingProposal == nil) { _, _ in refreshDiag() }
            .onChange(of: wc.pendingRequest == nil) { _, _ in refreshDiag() }
            .onChange(of: wc.relayConnected) { _, _ in refreshDiag() }
            // A new session means a connection just succeeded: return to the
            // wallet so the user lands back where they started.
            .onChange(of: wc.sessions.count) { old, new in
                if new > old { dismiss() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await connectFromPickedImage(item) }
            }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView(onCode: { code in
                        showScanner = false
                        Task { await wc.pair(uriString: code); refreshDiag() }
                    })
                    .ignoresSafeArea()
                    .navigationTitle("Scan QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("Photos", systemImage: "photo")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showScanner = false } }
                    }
                }
            }
            // This screen presents the approval surfaces itself (see file header).
            .sheet(isPresented: Binding(
                get: { wc.pendingProposal != nil },
                set: { if !$0 { Task { await wc.rejectProposal() } } }
            )) {
                if let proposal = wc.pendingProposal { WCProposalSheet(proposal: proposal) }
            }
            .sheet(isPresented: Binding(
                get: { wc.pendingRequest != nil },
                set: { if !$0 { Task { await wc.rejectPendingRequest() } } }
            )) {
                if let request = wc.pendingRequest { WCRequestSheet(pending: request) }
            }
            .alert("WalletConnect", isPresented: Binding(
                get: { wc.lastError != nil && wc.pendingRequest == nil && wc.pendingProposal == nil },
                set: { if !$0 { wc.lastError = nil } }
            )) {
                Button("OK") { wc.lastError = nil }
            } message: { Text(wc.lastError ?? "") }
        }
    }
}

// MARK: Approval surfaces (shared by the root modifier and the WC screen)

struct WCProposalSheet: View {
    @ObservedObject private var wc = WalletConnectManager.shared
    let proposal: Session.Proposal

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(proposal.proposer.name.isEmpty ? "An app" : proposal.proposer.name)
                    .font(.title3).fontWeight(.semibold)
                if let url = URL(string: proposal.proposer.url), let host = url.host {
                    Text(host).font(.callout).foregroundStyle(.secondary)
                }
                Text("wants to connect to your Ethereum wallet. It will be able to request signatures and transactions, which you approve one at a time.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await wc.approveProposal() }
                } label: { Text("Connect").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button(role: .cancel) {
                    Task { await wc.rejectProposal() }
                } label: { Text("Reject").frame(maxWidth: .infinity) }
            }
            .padding(20)
            .navigationTitle("Connection request")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

struct WCRequestSheet: View {
    @ObservedObject private var wc = WalletConnectManager.shared
    let pending: WalletConnectManager.PendingRequest
    @State private var working = false
    @State private var pendingDeviceOp: PendingHardwareOperation?
    /// Host-typed hidden-wallet passphrase, handed in by the device popup and
    /// read by the sign task. Never stored.
    @State private var typedPassphrase = ""

    /// Resolved by the app and carried on the request, so this sheet needs no
    /// store/environment access (a root-presented sheet has neither).
    private var hardwareDevice: RegisteredDevice? { pending.hardwareDevice }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(pending.methodLabel).font(.title3).fontWeight(.semibold)
                Text(walletLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                ScrollView {
                    Text(pending.preview)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if working {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(hardwareDevice != nil ? "Confirm on your device…" : "Signing…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button {
                        startSign()
                    } label: { Text("Sign").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button(role: .cancel) {
                        Task { await wc.rejectPendingRequest() }
                    } label: { Text("Reject").frame(maxWidth: .infinity) }
                }
            }
            .padding(20)
            .navigationTitle("Signature request")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // Hardware wallets get the same prepare-device popup the send flows use:
        // it carries the per-device unlock hint and the hidden-wallet passphrase
        // field (with reveal), instead of baking those into this sheet.
        .sheet(item: $pendingDeviceOp) { op in
            DeviceReadyConfirmationSheet(
                device: op.device,
                purpose: op.purpose,
                requiresPassphrase: pending.requiresHostPassphrase,
                onContinue: { runSign() },
                onCancel: { typedPassphrase = "" },
                onPassphrase: { typedPassphrase = $0 }
            )
        }
    }

    private var walletLine: String {
        let short = pending.address.count > 12
            ? "\(pending.address.prefix(6))…\(pending.address.suffix(4))"
            : pending.address
        if let label = pending.walletLabel { return "\(label)  ·  \(short)" }
        return short
    }

    private func startSign() {
        if let device = hardwareDevice {
            pendingDeviceOp = PendingHardwareOperation(device: device, purpose: .ethereumSign)
        } else {
            runSign()
        }
    }

    /// Run after the popup's Continue (hardware) or directly (software). Reads
    /// `typedPassphrase` inside the Task so the popup's state write has settled.
    private func runSign() {
        working = true
        Task {
            let pass = pending.requiresHostPassphrase ? typedPassphrase : nil
            await wc.approvePendingRequest(hostPassphrase: pass)
            working = false
            typedPassphrase = ""
        }
    }
}

// MARK: Global approval sheets (attach at the app root)

struct WalletConnectSheetsModifier: ViewModifier {
    @ObservedObject private var wc = WalletConnectManager.shared

    func body(content: Content) -> some View {
        content
            .alert("WalletConnect", isPresented: Binding(
                get: { wc.lastError != nil && wc.pendingRequest == nil && wc.pendingProposal == nil && !wc.screenVisible },
                set: { if !$0 { wc.lastError = nil } }
            )) {
                Button("OK") { wc.lastError = nil }
            } message: { Text(wc.lastError ?? "") }
            // Session proposal: a dApp wants to connect. The WalletConnect screen
            // presents these itself while it is up (it covers the root), so the
            // root only presents when that screen is not visible.
            .sheet(isPresented: Binding(
                get: { wc.pendingProposal != nil && !wc.screenVisible },
                set: { if !$0 { Task { await wc.rejectProposal() } } }
            )) {
                if let proposal = wc.pendingProposal { WCProposalSheet(proposal: proposal) }
            }
            // Sign request: a connected dApp wants a signature.
            .sheet(isPresented: Binding(
                get: { wc.pendingRequest != nil && !wc.screenVisible },
                set: { if !$0 { Task { await wc.rejectPendingRequest() } } }
            )) {
                if let request = wc.pendingRequest { WCRequestSheet(pending: request) }
            }
    }
}

extension View {
    func walletConnectSheets() -> some View { modifier(WalletConnectSheetsModifier()) }
}
