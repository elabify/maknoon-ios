// Sign-message and verify-message sheets for Tron, modelled on the Ethereum
// equivalents. Implements the TIP-191 "TRON Signed Message" format via the
// shared Rust core (ledger-tron-core): keccak256("\u{19}TRON Signed Message:\n"
// + len + message), signed with recoverable secp256k1, returned as the 0x-hex
// r||s||v (v in {27,28}) that TronLink / TronWeb signMessageV2 produce.
//
// Software wallets derive the key locally; Ledger routes over BLE. Trezor
// firmware has no Tron message-sign operation (it signs Tron transactions
// only), so a Trezor-backed Tron wallet shows an unsupported message.
// Verification is keyless: it recovers the signer T-address and compares.

import SwiftUI
import UIKit
import WalletCore

enum TronMessageSigningError: LocalizedError {
    case identityRequired
    case trezorUnsupported
    case noWallet
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityRequired:
            return "Unlock Maknoon first; signing needs your wallet's private key."
        case .trezorUnsupported:
            return "Trezor firmware doesn't support Tron message signing (it signs Tron transactions only). Use a software or Ledger Tron wallet to sign a message."
        case .noWallet:
            return "No active Tron wallet. Pick one in the Tron tab first."
        case .signingFailed(let m):
            return m
        }
    }
}

/// TIP-191 "TRON Signed Message" signing + verification. Signing derives the
/// account key under a biometric prompt; verification is a pure keyless
/// function (recover the signer T-address and compare).
enum TronMessageSigning {
    static func sign(
        message: String,
        account: UInt32,
        sandwich: IdentitySandwich,
        biometricReason: String
    ) throws -> (address: String, signature: String) {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        return try sign(
            message: message,
            account: account,
            mnemonic: material.words.joined(separator: " "),
            passphrase: material.hasPassphrase ? material.passphrase : ""
        )
    }

    /// Pure form: derive the key from a mnemonic + passphrase and sign via the
    /// shared core. No biometric read; exercised by the round-trip tests.
    static func sign(
        message: String,
        account: UInt32,
        mnemonic: String,
        passphrase: String
    ) throws -> (address: String, signature: String) {
        guard let hd = HDWallet(mnemonic: mnemonic, passphrase: passphrase) else {
            throw TronMessageSigningError.signingFailed("HDWallet constructor returned nil")
        }
        let key = hd.getKeyByCurve(curve: .secp256k1, derivationPath: TronDescriptors.derivationPath(account: account))
        let signed = try tronSignMessage(secretKey: key.data, message: message)
        return (signed.address, signed.signature)
    }

    /// Verify a TIP-191 signature. Keyless: any T-address + message + 0x-hex sig.
    static func verify(address: String, message: String, signature: String) -> Bool {
        tronVerifyMessage(address: address, message: message, signature: signature)
    }

    /// Hardware-BLE TIP-191 sign. Ledger only; Trezor firmware has no Tron
    /// message-sign operation.
    static func signOverBLE(
        device: RegisteredDevice,
        account: UInt32,
        message: String
    ) async throws -> (address: String, signature: String) {
        switch device.kind {
        case .ledger:
            let ledger = HardwareWalletFactory.make(kind: .ledger)
            guard let ledger = ledger as? LedgerBLE else {
                throw TronMessageSigningError.signingFailed("Expected LedgerBLE instance, got \(type(of: ledger))")
            }
            ledger.targetPeripheralUUID = device.peripheralUUID
            return try await ledger.signTronMessage(account: account, message: message)
        case .trezor:
            throw TronMessageSigningError.trezorUnsupported
        default:
            throw TronMessageSigningError.signingFailed(
                "\(device.kind.displayName) does not support Tron message signing"
            )
        }
    }
}

struct TronSignMessageSheet: View {
    let activeWallet: TronWalletDescriptor?
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""
    @State private var signedAddress: String?
    @State private var signature: String?
    @State private var errorText: String?
    @State private var signing = false
    @State private var copiedField: String?

    private var account: UInt32? {
        switch activeWallet?.kind {
        case .software(let a):       return a
        case .hardware(_, let a, _): return a
        case .none:                  return nil
        }
    }

    private var hardwareDevice: RegisteredDevice? {
        guard case .hardware(let deviceId, _, _) = activeWallet?.kind else { return nil }
        return store.devices.find(id: deviceId)
    }

    private var isHardware: Bool { hardwareDevice != nil }
    private var trezorUnsupported: Bool { hardwareDevice?.kind == .trezor }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    walletSummary
                } header: {
                    Text("Wallet")
                } footer: {
                    Text("Signs the message with the TIP-191 \"TRON Signed Message\" format (the one TronLink and TronWeb verifyMessageV2 produce). The signature is bound to this wallet's address.")
                        .font(.caption)
                }

                if trezorUnsupported {
                    Section {
                        Text(TronMessageSigningError.trezorUnsupported.errorDescription ?? "")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } else {
                    Section {
                        TextField("Message", text: $message, axis: .vertical)
                            .lineLimit(3...10)
                    } header: {
                        Text("Message")
                    }

                    Section {
                        Button {
                            Task { await sign() }
                        } label: {
                            HStack {
                                if signing { ProgressView().controlSize(.small) }
                                Text(signing ? (isHardware ? "Confirm on your device…" : "Signing…")
                                             : (isHardware ? "Sign on device" : "Sign message"))
                            }
                        }
                        .disabled(signing || account == nil || message.isEmpty)
                        if isHardware {
                            Text("You'll confirm the message on the device screen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let errorText {
                            Text(errorText).foregroundStyle(.red).font(.callout)
                        }
                        if let signature, let signedAddress {
                            VStack(alignment: .leading, spacing: 8) {
                                labeledCopyable("Address", signedAddress)
                                labeledCopyable("Signature", signature)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sign message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var walletSummary: some View {
        if let w = activeWallet {
            HStack {
                Text(w.label).font(.callout.weight(.semibold))
                Spacer()
                if let addr = w.kind.addressBase58CheckOrNil {
                    Text(addr.prefix(6) + "…" + addr.suffix(4))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No active wallet. Pick one in the Tron tab first.").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func labeledCopyable(_ label: String, _ value: String) -> some View {
        let isCopied = copiedField == label
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCopied ? Color.green.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .animation(.easeOut(duration: 0.2), value: isCopied)
            Button {
                UIPasteboard.general.string = value
                copiedField = label
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    if copiedField == label { copiedField = nil }
                }
            } label: {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(isCopied ? Color.green : Color.accentColor)
        }
    }

    @MainActor
    private func sign() async {
        signing = true
        errorText = nil
        signature = nil
        signedAddress = nil
        defer { signing = false }
        do {
            guard let w = activeWallet, let account = account else {
                throw TronMessageSigningError.noWallet
            }
            switch w.kind {
            case .software:
                guard let sandwich = store.sandwich else {
                    throw TronMessageSigningError.identityRequired
                }
                // Require a fresh biometric / passcode before signing (ADR-0045
                // Authorization invariant); refreshes the cache so the sign call
                // below does not prompt again.
                _ = try await sandwich.recoveryMaterialFresh(
                    localizedReason: "Sign a message with your Tron wallet"
                )
                let result = try TronMessageSigning.sign(
                    message: message,
                    account: account,
                    sandwich: sandwich,
                    biometricReason: "Sign a message with your Tron wallet"
                )
                signedAddress = result.address
                signature = result.signature
            case .hardware:
                guard let device = hardwareDevice else {
                    throw TronMessageSigningError.noWallet
                }
                let result = try await TronMessageSigning.signOverBLE(
                    device: device,
                    account: account,
                    message: message
                )
                signedAddress = result.address
                signature = result.signature
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

struct TronVerifyMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var message: String = ""
    @State private var signature: String = ""
    @State private var result: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address (T…)", text: $address, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...10)
                    TextField("Signature (0x…)", text: $signature, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                } header: {
                    Text("Verify")
                } footer: {
                    Text("Verifies a TIP-191 \"TRON Signed Message\" signature (TronLink / TronWeb). Paste the T-address, message, and 0x-hex signature from any source.")
                        .font(.caption)
                }
                Section {
                    Button {
                        result = TronMessageSigning.verify(
                            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                            message: message,
                            signature: signature.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } label: {
                        Text("Verify signature")
                    }
                    .disabled(address.isEmpty || message.isEmpty || signature.isEmpty)
                    if let r = result {
                        if r {
                            Label("Signature valid", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Label("Signature does not match this address and message", systemImage: "xmark.seal.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Verify message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private extension TronWalletKind {
    var addressBase58CheckOrNil: String? {
        if case .hardware(_, _, let addr) = self { return addr }
        return nil
    }
}
