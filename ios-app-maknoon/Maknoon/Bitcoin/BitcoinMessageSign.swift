// Sign-message and verify-message sheets, modelled on Sparrow's Tools
// menu. Implements the legacy "Bitcoin Signed Message" format (the one
// Bitcoin Core's signmessage / verifymessage and Electrum produce):
// header-prefixed double-SHA256 digest + secp256k1 recoverable ECDSA,
// base64-encoded. The signature binds to the signing key's legacy
// P2PKH address; verification recovers the public key and checks it
// against that address.
//
// The crypto runs through Trust Wallet Core's BitcoinMessageSigner
// (the same primitive Trust Wallet ships, with its own known-answer
// tests). Signing needs the private key, so it is offered for software
// wallets only; verification is keyless and works for any P2PKH
// address + message + signature from any source.
//
// BIP137 / BIP322 are intentionally not offered: BitcoinMessageSigner
// implements the one widely-interoperable legacy format, and shipping a
// single correct format beats offering pickers that don't round-trip.

import SwiftUI
import UIKit
import WalletCore

enum BitcoinMessageSigningError: LocalizedError {
    case identityRequired
    case hardwareUnsupported
    case networkUnsupported
    case noWallet
    case keyDerivationFailed
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .identityRequired:
            return "Unlock your Identity Sandwich first; signing needs your wallet's private key."
        case .hardwareUnsupported:
            return "Message signing is available for software wallets only. This wallet is hardware-backed; its key never leaves the device."
        case .networkUnsupported:
            return "Message signing is available for mainnet wallets only."
        case .noWallet:
            return "No active Bitcoin wallet. Pick one in the Bitcoin tab first."
        case .keyDerivationFailed:
            return "Couldn't derive the signing key for this wallet."
        case .signingFailed:
            return "The signer did not produce a signature."
        }
    }
}

/// Legacy "Bitcoin Signed Message" signing + verification via Trust
/// Wallet Core. Stateless; both entry points are pure functions of
/// their inputs (plus, for signing, a biometric-gated seed read).
enum BitcoinMessageSigning {
    /// Sign `message` with the active software wallet's first external
    /// key (BIP84 `m/84'/<coin>'/<account>'/0/0`). Returns the base64
    /// signature together with the legacy P2PKH address it is bound to,
    /// which is the address `verify` checks against.
    static func sign(
        message: String,
        account: UInt32,
        network: BitcoinNetwork,
        sandwich: IdentitySandwich,
        biometricReason: String
    ) throws -> (address: String, signature: String) {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        return try sign(
            message: message,
            mnemonic: material.words.joined(separator: " "),
            passphrase: material.hasPassphrase ? material.passphrase : "",
            account: account,
            network: network
        )
    }

    /// Pure form: sign with a BIP39 mnemonic + passphrase directly, no
    /// sandbox / biometric read. Used by the sandwich overload above and
    /// exercised by the unit tests (sign then verify round-trip).
    static func sign(
        message: String,
        mnemonic: String,
        passphrase: String,
        account: UInt32,
        network: BitcoinNetwork
    ) throws -> (address: String, signature: String) {
        // Trust Wallet Core's BitcoinMessageSigner only supports the
        // mainnet legacy "Bitcoin Signed Message" format (it rejects a
        // test-network address), so message signing is mainnet-only.
        guard network == .mainnet else {
            throw BitcoinMessageSigningError.networkUnsupported
        }
        guard let hd = HDWallet(
            mnemonic: mnemonic,
            passphrase: passphrase
        ) else {
            throw BitcoinMessageSigningError.keyDerivationFailed
        }

        // Legacy message signing binds to the mainnet P2PKH (version
        // byte 0x00) address of the signing key, independent of the
        // wallet's native segwit address type.
        let path = "m/84'/\(network.coinType)'/\(account)'/0/0"
        let key = hd.getKey(coin: .bitcoin, derivationPath: path)
        let pub = key.getPublicKeySecp256k1(compressed: true)
        guard let p2pkh = BitcoinAddress(publicKey: pub, prefix: 0) else {
            throw BitcoinMessageSigningError.keyDerivationFailed
        }
        let address = p2pkh.description
        let signature = BitcoinMessageSigner.signMessage(
            privateKey: key,
            address: address,
            message: message
        )
        guard !signature.isEmpty else {
            throw BitcoinMessageSigningError.signingFailed
        }
        return (address, signature)
    }

    /// Verify a legacy "Bitcoin Signed Message" signature. Keyless:
    /// works for any legacy P2PKH address + message + base64 signature.
    static func verify(address: String, message: String, signature: String) -> Bool {
        BitcoinMessageSigner.verifyMessage(
            address: address,
            message: message,
            signature: signature
        )
    }
}

struct BitcoinSignMessageSheet: View {
    let activeWallet: BitcoinWalletDescriptor?
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""
    @State private var signedAddress: String?
    @State private var signature: String?
    @State private var errorText: String?
    @State private var signing = false

    /// Account index when the active wallet is software-backed; nil for
    /// hardware wallets (which cannot message-sign) or no wallet.
    private var softwareAccount: UInt32? {
        guard let w = activeWallet, case .software(let account) = w.kind else { return nil }
        return account
    }

    private var isHardware: Bool {
        guard let w = activeWallet, case .hardware = w.kind else { return false }
        return true
    }

    private var isMainnet: Bool {
        activeWallet?.network == .mainnet
    }

    /// Signing is offered only for software, mainnet wallets (the
    /// legacy message format the signer implements is mainnet-only).
    private var unsupportedNote: String? {
        if isHardware {
            return "Message signing is available for software wallets only."
        }
        if activeWallet != nil && !isMainnet {
            return "Message signing is available for mainnet wallets only."
        }
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
                    Text("Signs with the wallet's first receive key using the legacy \"Bitcoin Signed Message\" format. The signature is bound to that key's legacy address (starting with 1 on mainnet), which is what a verifier checks against.")
                        .font(.caption)
                }

                if let unsupportedNote {
                    Section {
                        Label(unsupportedNote, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                                Text(signing ? "Signing…" : "Sign message")
                            }
                        }
                        .disabled(signing || softwareAccount == nil || message.isEmpty)
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
                Text(w.network.displayName).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No active wallet. Pick one in the Bitcoin tab first.").foregroundStyle(.red)
        }
    }

    private func labeledCopyable(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .font(.caption)
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
            guard let account = softwareAccount else {
                throw isHardware ? BitcoinMessageSigningError.hardwareUnsupported
                                 : BitcoinMessageSigningError.noWallet
            }
            guard let sandwich = store.sandwich else {
                throw BitcoinMessageSigningError.identityRequired
            }
            guard let network = activeWallet?.network else {
                throw BitcoinMessageSigningError.noWallet
            }
            let result = try BitcoinMessageSigning.sign(
                message: message,
                account: account,
                network: network,
                sandwich: sandwich,
                biometricReason: "Sign a message with your Bitcoin wallet"
            )
            signedAddress = result.address
            signature = result.signature
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

struct BitcoinVerifyMessageSheet: View {
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
                    TextField("Address", text: $address, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...10)
                    TextField("Signature", text: $signature, axis: .vertical)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                } header: {
                    Text("Verify")
                } footer: {
                    Text("Verifies a legacy \"Bitcoin Signed Message\" signature (Bitcoin Core / Electrum). Paste the address, message, and base64 signature from any source. Works for legacy addresses (starting with 1 on mainnet).")
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
        let ok = BitcoinMessageSigning.verify(
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message,
            signature: signature.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        result = ok ? .valid : .invalid
    }
}
