// Sign-message and verify-message sheets for Solana, modelled on the Tron /
// Ethereum equivalents. Implements the Solana off-chain message (OCMS,
// SIMD-0048) format via the shared Rust core (ledger-sol-core): the
// "\u{FF}solana offchain" signing domain + a v0 header (application domain,
// format, the signer list, and the message), ed25519-signed. The same envelope
// is signed by software, Ledger (SIGN_OFFCHAIN_MESSAGE), and Trezor
// (SolanaSignMessage), so all three are byte-identical.
//
// Software wallets derive the ed25519 key locally; Ledger AND Trezor route over
// BLE (both vendors support OCMS). Verification is keyless: the address IS the
// base58 ed25519 pubkey. Note: OCMS is NOT Phantom's raw signMessage, so these
// verify in Maknoon + OCMS-aware tooling, not web3.js nacl.verify(rawMsg,...).

import SwiftUI
import UIKit
import WalletCore

enum SolanaMessageSigningError: LocalizedError {
    case identityRequired
    case noWallet
    case trezorFirmwareUnsupported
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityRequired:
            return "Unlock Maknoon first; signing needs your wallet's private key."
        case .noWallet:
            return "No active Solana wallet. Pick one in the Solana tab first."
        case .trezorFirmwareUnsupported:
            return "Your Trezor's firmware doesn't support Solana message signing yet. Update it in Trezor Suite, then try again."
        case .signingFailed(let m):
            return m
        }
    }
}

/// Solana OCMS signing + verification. Signing derives the account key under a
/// biometric prompt; verification is a pure keyless function.
enum SolanaMessageSigning {
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

    /// Pure form: derive the ed25519 key from a mnemonic + passphrase and sign
    /// via the shared core. No biometric read; exercised by the round-trip tests.
    static func sign(
        message: String,
        account: UInt32,
        mnemonic: String,
        passphrase: String
    ) throws -> (address: String, signature: String) {
        guard let hd = HDWallet(mnemonic: mnemonic, passphrase: passphrase) else {
            throw SolanaMessageSigningError.signingFailed("HDWallet constructor returned nil")
        }
        let key = hd.getKeyByCurve(curve: .ed25519, derivationPath: SolanaDescriptors.derivationPath(account: account))
        let signed = try solSignMessage(secretSeed: key.data, message: message)
        return (signed.address, signed.signature)
    }

    /// Verify an OCMS signature. Keyless: any base58 address + message + base58 sig.
    static func verify(address: String, message: String, signature: String) -> Bool {
        solVerifyMessage(address: address, message: message, signature: signature)
    }

    /// Hardware-BLE OCMS sign. Ledger AND Trezor both support it.
    static func signOverBLE(
        device: RegisteredDevice,
        account: UInt32,
        message: String,
        signerPubkeyBase58: String
    ) async throws -> (address: String, signature: String) {
        // Build the OCMS envelope from the wallet's stored pubkey (no on-device
        // get-address round-trip — see LedgerBLE.signSolanaMessage).
        guard let pubkey = Base58.decodeNoCheck(string: signerPubkeyBase58), pubkey.count == 32 else {
            throw SolanaMessageSigningError.signingFailed(
                "This wallet has no valid stored Solana public key; re-add the wallet."
            )
        }
        switch device.kind {
        case .ledger:
            guard let ledger = HardwareWalletFactory.make(kind: .ledger) as? LedgerBLE else {
                throw SolanaMessageSigningError.signingFailed("Expected LedgerBLE instance")
            }
            ledger.targetPeripheralUUID = device.peripheralUUID
            return try await ledger.signSolanaMessage(account: account, message: message, signerPubkey: pubkey)
        case .trezor:
            guard let trezor = HardwareWalletFactory.make(kind: .trezor) as? TrezorBLE else {
                throw SolanaMessageSigningError.signingFailed("Expected TrezorBLE instance")
            }
            trezor.targetPeripheralUUID = device.peripheralUUID
            do {
                return try await trezor.signSolanaMessage(account: account, message: message, signerPubkey: pubkey)
            } catch {
                // Trezor firmware predating Solana OCMS support (trezor-firmware
                // PR #6759) has no SolanaSignMessage (906) handler and returns
                // Failure_UnexpectedMessage. Surface an update-firmware hint.
                if "\(error)".lowercased().contains("unexpected message") {
                    throw SolanaMessageSigningError.trezorFirmwareUnsupported
                }
                throw error
            }
        default:
            throw SolanaMessageSigningError.signingFailed(
                "\(device.kind.displayName) does not support Solana message signing"
            )
        }
    }
}

struct SolanaSignMessageSheet: View {
    let activeWallet: SolanaWalletDescriptor?
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

    private var hardwareAddress: String? {
        if case .hardware(_, _, let addr) = activeWallet?.kind { return addr }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    walletSummary
                } header: {
                    Text("Wallet")
                } footer: {
                    Text("Signs the message with the Solana off-chain message (OCMS) format, the one Ledger and Trezor sign on-device. The signature is bound to this wallet's address.")
                        .font(.caption)
                }

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
                if let addr = hardwareAddress {
                    Text(addr.prefix(6) + "…" + addr.suffix(4))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No active wallet. Pick one in the Solana tab first.").foregroundStyle(.red)
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
                throw SolanaMessageSigningError.noWallet
            }
            switch w.kind {
            case .software:
                guard let sandwich = store.sandwich else {
                    throw SolanaMessageSigningError.identityRequired
                }
                // Require a fresh biometric / passcode before signing (ADR-0045
                // Authorization invariant); refreshes the cache so the sign call
                // below does not prompt again.
                _ = try await sandwich.recoveryMaterialFresh(
                    localizedReason: "Sign a message with your Solana wallet"
                )
                let result = try SolanaMessageSigning.sign(
                    message: message,
                    account: account,
                    sandwich: sandwich,
                    biometricReason: "Sign a message with your Solana wallet"
                )
                signedAddress = result.address
                signature = result.signature
            case .hardware:
                guard let device = hardwareDevice, let pubkey = hardwareAddress else {
                    throw SolanaMessageSigningError.noWallet
                }
                let result = try await SolanaMessageSigning.signOverBLE(
                    device: device,
                    account: account,
                    message: message,
                    signerPubkeyBase58: pubkey
                )
                signedAddress = result.address
                signature = result.signature
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

struct SolanaVerifyMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var message: String = ""
    @State private var signature: String = ""
    @State private var result: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...10)
                    TextField("Signature (base58)", text: $signature, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                } header: {
                    Text("Verify")
                } footer: {
                    Text("Verifies a Solana off-chain message (OCMS) signature. Paste the address, message, and base58 signature produced by a Maknoon, Ledger, or Trezor wallet.")
                        .font(.caption)
                }
                Section {
                    Button {
                        result = SolanaMessageSigning.verify(
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
