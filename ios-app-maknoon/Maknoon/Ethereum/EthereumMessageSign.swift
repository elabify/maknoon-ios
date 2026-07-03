// Sign-message and verify-message sheets for Ethereum, modelled on the
// Bitcoin equivalents (BitcoinMessageSign.swift). Implements EIP-191
// `personal_sign`: keccak256("\u{19}Ethereum Signed Message:\n" + len +
// message), signed with secp256k1 (recoverable), returned as a 65-byte
// 0x-hex signature (r||s||v) with v in {27,28} as web3 clients expect.
// This is the format MetaMask / Etherscan / MyCrypto produce and verify.
//
// Signing needs the private key, so it is offered for software wallets
// only (hardware routing is added with the hardware-signing work);
// verification is keyless and works for any address + message +
// signature from any source, by recovering the signer address and
// comparing it to the supplied address.
//
// personal_sign carries no chain id, so it is network-agnostic (unlike
// the Bitcoin legacy format, which is mainnet-only).

import SwiftUI
import UIKit
import WalletCore

enum EthereumMessageSigningError: LocalizedError {
    case identityRequired
    case hardwareUnsupported
    case noWallet
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityRequired:
            return "Unlock Maknoon first; signing needs your wallet's private key."
        case .hardwareUnsupported:
            return "Message signing is available for software wallets only. This wallet is hardware-backed; its key never leaves the device."
        case .noWallet:
            return "No active Ethereum wallet. Pick one in the Ethereum tab first."
        case .signingFailed(let m):
            return m
        }
    }
}

/// EIP-191 `personal_sign` signing + verification. Signing derives the
/// account key under a biometric prompt; verification is a pure,
/// keyless function (recover the signer address and compare).
enum EthereumMessageSigning {
    /// Sign `message` (UTF-8) with the active software wallet's account.
    /// Returns the 0x-hex signature; the signer address is the wallet's
    /// own EOA address, which is what `verify` checks against.
    static func sign(
        message: String,
        account: UInt32,
        sandwich: IdentitySandwich,
        biometricReason: String
    ) throws -> String {
        try EthereumDescriptors.signPersonalMessageFromSandwich(
            sandwich: sandwich,
            account: account,
            message: Data(message.utf8),
            biometricReason: biometricReason
        )
    }

    /// Verify an EIP-191 `personal_sign` signature: recover the signer
    /// address and compare (case-insensitively) to `address`. Keyless.
    static func verify(address: String, message: String, signature: String) -> Bool {
        guard let recovered = recoverAddress(message: message, signature: signature) else {
            return false
        }
        let want = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recovered.lowercased() == want
    }

    /// Recover the EIP-55 address that produced an EIP-191 `personal_sign`
    /// signature, or nil if the signature is malformed.
    static func recoverAddress(message: String, signature: String) -> String? {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        guard let raw = Data(hexString: hex), raw.count == 65 else { return nil }
        // web3 encodes v as 27/28; Trust Wallet Core's recover wants the
        // recovery id (0/1) in the trailing byte.
        var sig = raw
        if sig[64] >= 27 { sig[64] -= 27 }
        let messageData = Data(message.utf8)
        var prefixed = Data("\u{19}Ethereum Signed Message:\n\(messageData.count)".utf8)
        prefixed.append(messageData)
        let digest = Hash.keccak256(data: prefixed)
        guard let pub = PublicKey.recover(signature: sig, message: digest) else { return nil }
        return AnyAddress(publicKey: pub, coin: .ethereum).description
    }

    /// Hardware-BLE `personal_sign`: connect to the paired device, sign with
    /// Ethereum account `account`, and return the 0x-hex signature (r||s||v).
    /// Trezor hidden (passphrase) wallets are supported via `hidden` +
    /// `hostEntered`; Ledger hidden wallets are selected at device unlock.
    static func signOverBLE(
        device: RegisteredDevice,
        account: UInt32,
        message: Data,
        hidden: HardwarePassphraseRef? = nil,
        hostEntered: String? = nil
    ) async throws -> String {
        switch device.kind {
        case .ledger:
            let ledger = HardwareWalletFactory.make(kind: .ledger)
            guard let ledger = ledger as? LedgerBLE else {
                throw EthereumMessageSigningError.signingFailed("Expected LedgerBLE instance, got \(type(of: ledger))")
            }
            ledger.targetPeripheralUUID = device.peripheralUUID
            return try await ledger.signEthereumPersonalMessage(account: account, message: message)
        case .trezor:
            let trezor = HardwareWalletFactory.make(kind: .trezor)
            guard let trezor = trezor as? TrezorBLE else {
                throw EthereumMessageSigningError.signingFailed("Expected TrezorBLE instance, got \(type(of: trezor))")
            }
            trezor.targetPeripheralUUID = device.peripheralUUID
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
            return try await trezor.signEthereumMessage(account: account, message: message)
        default:
            throw EthereumMessageSigningError.signingFailed(
                "\(device.kind.displayName) does not support message signing yet"
            )
        }
    }

    /// Hardware-BLE EIP-712 `eth_signTypedData_v4`. Ledger signs the two hashes
    /// on-device (INS 0x0E). Trezor's typed-data streaming is not implemented yet
    /// (the Rust core returns NotImplemented), so it surfaces a clear message
    /// rather than a cryptic device error.
    static func signTypedDataOverBLE(
        device: RegisteredDevice,
        account: UInt32,
        typedDataJSON: String,
        hidden: HardwarePassphraseRef? = nil,
        hostEntered: String? = nil
    ) async throws -> String {
        switch device.kind {
        case .ledger:
            let ledger = HardwareWalletFactory.make(kind: .ledger)
            guard let ledger = ledger as? LedgerBLE else {
                throw EthereumMessageSigningError.signingFailed("Expected LedgerBLE instance, got \(type(of: ledger))")
            }
            ledger.targetPeripheralUUID = device.peripheralUUID
            return try await ledger.signEthereumTypedData(account: account, typedDataJSON: typedDataJSON)
        case .trezor:
            let trezor = HardwareWalletFactory.make(kind: .trezor)
            guard let trezor = trezor as? TrezorBLE else {
                throw EthereumMessageSigningError.signingFailed("Expected TrezorBLE instance, got \(type(of: trezor))")
            }
            trezor.targetPeripheralUUID = device.peripheralUUID
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
            return try await trezor.signEthereumTypedData(account: account, typedDataJSON: typedDataJSON)
        default:
            throw EthereumMessageSigningError.signingFailed(
                "\(device.kind.displayName) does not support typed-data signing yet"
            )
        }
    }
}

struct EthereumSignMessageSheet: View {
    let activeWallet: EthereumWalletDescriptor?
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""
    @State private var signature: String?
    @State private var errorText: String?
    @State private var signing = false
    @State private var copiedField: String?
    /// Host-typed passphrase for a hidden Trezor wallet (never stored).
    @State private var hostPassphrase: String = ""

    /// Account index for the active wallet (software or hardware); nil if
    /// there is no active wallet.
    private var account: UInt32? {
        switch activeWallet?.kind {
        case .software(let a):       return a
        case .hardware(_, let a, _): return a
        case .none:                  return nil
        }
    }

    private var isHardware: Bool {
        guard let w = activeWallet, case .hardware = w.kind else { return false }
        return true
    }

    /// A host-typed hidden (passphrase) Trezor wallet needs the passphrase
    /// entered up front so the device opens the matching session to sign.
    private var needsPassphrase: Bool {
        activeWallet?.hidden?.needsHostPassphrase == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    walletSummary
                } header: {
                    Text("Wallet")
                } footer: {
                    Text("Signs the message with this account's key using the EIP-191 \"personal_sign\" format (the one MetaMask and Etherscan produce). The signature is bound to this wallet's address, which is what a verifier checks against.")
                        .font(.caption)
                }

                Section {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Message")
                }

                if needsPassphrase {
                    Section {
                        RevealableSecureField(placeholder: "Hidden wallet passphrase", text: $hostPassphrase)
                    } footer: {
                        Text("This wallet is a hidden (passphrase) wallet. Enter its passphrase to sign; it is never stored.")
                            .font(.caption)
                    }
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
                    .disabled(signing || account == nil || message.isEmpty || (needsPassphrase && hostPassphrase.isEmpty))
                    if isHardware {
                        Text("You'll confirm the message on the device screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.callout)
                    }
                    if let signature, let address = activeWallet?.address {
                        VStack(alignment: .leading, spacing: 8) {
                            labeledCopyable("Address", address)
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
                if let addr = w.address {
                    Text(addr.prefix(6) + "…" + addr.suffix(4))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No active wallet. Pick one in the Ethereum tab first.").foregroundStyle(.red)
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
            // Independent tap target: without an explicit style, multiple
            // buttons in one Form row all fire the last button's action.
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
        defer { signing = false }
        do {
            guard let w = activeWallet, let account = account else {
                throw EthereumMessageSigningError.noWallet
            }
            switch w.kind {
            case .software:
                guard let sandwich = store.sandwich else {
                    throw EthereumMessageSigningError.identityRequired
                }
                // Require a fresh biometric / passcode before signing (ADR-0045
                // Authorization invariant); refreshes the cache so the sign call
                // below does not prompt again.
                _ = try await sandwich.recoveryMaterialFresh(
                    localizedReason: "Sign a message with your Ethereum wallet"
                )
                signature = try EthereumMessageSigning.sign(
                    message: message,
                    account: account,
                    sandwich: sandwich,
                    biometricReason: "Sign a message with your Ethereum wallet"
                )
            case .hardware(let deviceId, _, _):
                guard let device = store.devices.find(id: deviceId) else {
                    throw EthereumMessageSigningError.noWallet
                }
                signature = try await EthereumMessageSigning.signOverBLE(
                    device: device,
                    account: account,
                    message: Data(message.utf8),
                    hidden: w.hidden,
                    hostEntered: hostPassphrase
                )
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

struct EthereumVerifyMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var message: String = ""
    @State private var signature: String = ""
    @State private var result: VerifyResult?
    @State private var verifying = false

    enum VerifyResult: Equatable {
        case valid
        case invalid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address (0x…)", text: $address, axis: .vertical)
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
                    Text("Verifies an EIP-191 \"personal_sign\" signature (MetaMask / Etherscan). Paste the address, message, and 0x-hex signature from any source.")
                        .font(.caption)
                }

                Section {
                    Button {
                        Task { await verify() }
                    } label: {
                        HStack {
                            if verifying { ProgressView().controlSize(.small) }
                            Text(verifying ? "Verifying…" : "Verify signature")
                        }
                    }
                    .disabled(verifying || address.isEmpty || message.isEmpty || signature.isEmpty)
                    if let r = result {
                        switch r {
                        case .valid:
                            Label("Signature valid", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        case .invalid:
                            Label("Signature does not match this address and message", systemImage: "xmark.seal.fill")
                                .foregroundStyle(.red)
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

    @MainActor
    private func verify() async {
        verifying = true
        result = nil
        defer { verifying = false }
        let ok = EthereumMessageSigning.verify(
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message,
            signature: signature.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        result = ok ? .valid : .invalid
    }
}
