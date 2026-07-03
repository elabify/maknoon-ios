// Trust Wallet Core HDWallet wrapper for Ethereum.
//
// Phase 1: address derivation under a single biometric prompt; the
// resulting EIP-55 address is cached on the descriptor so subsequent
// wallet opens never touch the seed.
//
// Phase 2: a `signTransaction` entry point that derives the BIP44
// EOA private key under a "Authorize Ethereum send" prompt and
// signs an EIP-1559 transaction via TWC's AnySigner. The private
// key never escapes this function: it is built inside the
// recoveryMaterial closure, passed into the protobuf message, and
// goes out of scope once `AnySigner.sign` returns. iOS clears the
// surrounding Data buffer on closure exit.

import Foundation
import WalletCore

enum EthereumDescriptorError: LocalizedError {
    case sandwichLocked
    case hdWalletFailed(String)
    case signingFailed(String)
    var errorDescription: String? {
        switch self {
        case .sandwichLocked:         return "Maknoon is locked"
        case .hdWalletFailed(let m):  return "HD wallet derive failed: \(m)"
        case .signingFailed(let m):   return "Ethereum signing failed: \(m)"
        }
    }
}

/// Plain-data inputs to the signer. Built by the wallet actor after
/// nonce / gas / fee estimation; the SwiftUI layer never constructs
/// one of these directly. For ERC-20 transfers `toAddress` is the
/// token contract, `recipient` is the wallet receiving the tokens,
/// and `value` is the token amount (in the token's smallest unit).
struct EthereumTxPlan {
    enum Payload {
        /// Native coin transfer: `value` wei to `toAddress`.
        case native
        /// ERC-20 transfer: `value` token-units to `recipient` via
        /// the token contract. `toAddress` on the parent struct is
        /// the contract address; `recipient` here is the receiver.
        case erc20(recipient: String)
        /// Arbitrary contract call (e.g. a WalletConnect dApp's
        /// `eth_sendTransaction`): raw `data` sent to `toAddress`,
        /// carrying `value` wei (often zero, non-zero for payable
        /// calls such as an ETH swap). The device clear- or
        /// blind-signs the call; there is no recognized descriptor.
        case contractCall(data: Data)
    }

    let chainId: UInt64
    let nonce: UInt64
    let toAddress: String
    let value: EthereumWeiValue
    let gasLimit: UInt64
    let maxFeePerGas: EthereumWeiValue
    let maxPriorityFeePerGas: EthereumWeiValue
    let payload: Payload
}

/// Wire-format codec for EIP-1559 (type 2) transactions. The
/// software signing path uses Trust Wallet Core which encodes the
/// transaction internally; this codec is what the hardware path
/// needs: we have to hand Ledger the *unsigned* envelope so it can
/// sign, then re-assemble the signed envelope from the V/R/S the
/// device returns.
enum EthereumTxEncoder {

    /// Inner RLP payload (without the 0x02 prefix and without
    /// signature). Used internally by `unsignedEnvelope` and
    /// `signedEnvelope`; exposed so a higher-level signer can hash
    /// it if needed.
    private static func payload(plan: EthereumTxPlan, callData: Data) -> [EthereumRLP.Item] {
        return [
            .uint(plan.chainId),
            .uint(plan.nonce),
            .wei(plan.maxPriorityFeePerGas),
            .wei(plan.maxFeePerGas),
            .uint(plan.gasLimit),
            .address(plan.toAddress),
            .wei(ethValueWei(for: plan)),
            .bytes(callData),
            .list([])                     // accessList (empty)
        ]
    }

    /// The native-coin value (wei) carried in the transaction's
    /// `value` field. For a native send this is the amount. For an
    /// ERC-20 send it MUST be zero: `plan.value` there is the token
    /// amount, which belongs only in the `transfer(to,amount)`
    /// calldata, never in the tx value. Encoding the token amount as
    /// the ETH value produces a transaction the Ledger Ethereum app
    /// rejects with 0x6A80 (even with blind signing on) because the
    /// value contradicts the recognized transfer calldata.
    private static func ethValueWei(for plan: EthereumTxPlan) -> EthereumWeiValue {
        switch plan.payload {
        case .native:       return plan.value
        case .erc20:        return .zero
        case .contractCall: return plan.value
        }
    }

    /// EIP-1559 unsigned envelope: 0x02 || rlp([chainId, nonce, ...,
    /// accessList]). This is exactly what Ledger's SIGN_TRANSACTION
    /// expects after the BIP44 path bytes.
    static func unsignedEnvelope(plan: EthereumTxPlan) -> Data {
        var out = Data([0x02])
        out.append(EthereumRLP.encode(.list(payload(plan: plan, callData: callData(for: plan)))))
        return out
    }

    /// EIP-1559 signed envelope: 0x02 || rlp([..., v, r, s]). Pass
    /// the V/R/S the device returned. V is 0 or 1 for type-2
    /// transactions (parity bit; chain id is already in the payload).
    static func signedEnvelope(plan: EthereumTxPlan, v: UInt8, r: Data, s: Data) -> Data {
        var items = payload(plan: plan, callData: callData(for: plan))
        items.append(.uint(UInt64(v)))
        // r and s are 32-byte big-endian. RLP requires leading-zero
        // stripping for canonical encoding; do it here.
        items.append(.bytes(stripLeadingZeros(r)))
        items.append(.bytes(stripLeadingZeros(s)))
        var out = Data([0x02])
        out.append(EthereumRLP.encode(.list(items)))
        return out
    }

    /// Build the calldata blob for a given plan. Native sends carry
    /// no calldata; ERC-20 sends pack `transfer(to, amount)`.
    private static func callData(for plan: EthereumTxPlan) -> Data {
        switch plan.payload {
        case .native:
            return Data()
        case .erc20(let recipient):
            return EthereumABI.transferData(to: recipient, amount: plan.value) ?? Data()
        case .contractCall(let data):
            return data
        }
    }

    private static func stripLeadingZeros(_ d: Data) -> Data {
        var bytes = Array(d)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        // Allow the canonical-RLP all-zero case to collapse to empty.
        if bytes.count == 1 && bytes[0] == 0 { return Data() }
        return Data(bytes)
    }
}

/// Shared hardware (Ledger / Trezor) EIP-1559 transaction signer. Both the send
/// flow and WalletConnect call this so they pin ONE BLE/THP session across
/// identify+sign and apply identical hidden-wallet passphrase + derivation-path
/// handling. Returns the 0x-prefixed signed raw transaction.
enum EthereumHardwareTx {
    static func sign(
        plan: EthereumTxPlan,
        device: RegisteredDevice,
        account: UInt32,
        hidden: HardwarePassphraseRef? = nil,
        derivationPath: String? = nil,
        hostEntered: String? = nil
    ) async throws -> String {
        let hwKind: HardwareWalletKind = device.kind == .ledger ? .ledger : .trezor
        let hardware = HardwareWalletFactory.make(kind: hwKind)
        // A Trezor hidden wallet must re-open the same passphrase session it was
        // discovered in, or the device derives a different (wrong) key and the
        // signature won't match the wallet's address. Ledger / mock ignore this.
        if let trezor = hardware as? TrezorBLE {
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
        }
        hardware.setDerivationPathOverride(derivationPath)
        // Pin the session across identify + sign (see send-flow note): without
        // it, identify tears the link down and the sign reconnects immediately,
        // racing the half-closed BLE link into a stale-frame handshake error.
        hardware.beginSession()
        defer { hardware.endSession() }
        let connected = try await hardware.identifyDevice()
        guard connected == device.serial else {
            throw IdentityWrapError.deviceSerialMismatch(expected: device.serial, actual: connected)
        }
        let unsigned = EthereumTxEncoder.unsignedEnvelope(plan: plan)
        // ERC-20 transfers get the Ledger-signed token descriptor for
        // clear-signing; native + arbitrary contract calls have none.
        let erc20Descriptor: Data?
        if case .erc20 = plan.payload {
            erc20Descriptor = LedgerERC20Descriptors.descriptor(chainId: plan.chainId, contract: plan.toAddress)
        } else {
            erc20Descriptor = nil
        }
        let (v, r, s) = try await hardware.signEthereumTransaction(
            envelope: unsigned,
            account: account,
            erc20Descriptor: erc20Descriptor
        )
        let signed = EthereumTxEncoder.signedEnvelope(plan: plan, v: v, r: r, s: s)
        return "0x" + signed.map { String(format: "%02x", $0) }.joined()
    }
}

enum EthereumDescriptors {

    /// Read the sandwich seed under a biometric prompt, derive the
    /// Ethereum EOA address at m/44'/60'/<account>'/0/0, and return
    /// the EIP-55 checksummed hex.
    static func addressFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        biometricReason: String
    ) throws -> String {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let key = wallet.getDerivedKey(
            coin: .ethereum,
            account: account,
            change: 0,
            address: 0
        )
        return CoinType.ethereum.deriveAddress(privateKey: key)
    }

    /// Read the sandwich seed under a biometric prompt, derive the
    /// EOA private key, sign the EIP-1559 transaction, return the
    /// raw RLP-encoded signed transaction hex (the format
    /// eth_sendRawTransaction expects).
    static func signTransactionFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        plan: EthereumTxPlan,
        biometricReason: String
    ) throws -> String {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let key = wallet.getDerivedKey(
            coin: .ethereum,
            account: account,
            change: 0,
            address: 0
        )

        var input = EthereumSigningInput()
        input.chainID = EthereumWeiValue(uint64: plan.chainId).bigEndianBytes
        input.nonce = EthereumWeiValue(uint64: plan.nonce).bigEndianBytes
        input.txMode = .enveloped
        input.gasLimit = EthereumWeiValue(uint64: plan.gasLimit).bigEndianBytes
        input.maxFeePerGas = plan.maxFeePerGas.bigEndianBytes
        input.maxInclusionFeePerGas = plan.maxPriorityFeePerGas.bigEndianBytes
        input.toAddress = plan.toAddress
        input.privateKey = key.data

        var tx = EthereumTransaction()
        switch plan.payload {
        case .native:
            var transfer = EthereumTransaction.Transfer()
            transfer.amount = plan.value.bigEndianBytes
            tx.transactionOneof = .transfer(transfer)
        case .erc20(let recipient):
            var erc20 = EthereumTransaction.ERC20Transfer()
            erc20.to = recipient
            erc20.amount = plan.value.bigEndianBytes
            tx.transactionOneof = .erc20Transfer(erc20)
        case .contractCall(let data):
            // Arbitrary call: WalletCore's generic contract carries the
            // ETH value (payable calls) and the raw calldata verbatim.
            var generic = EthereumTransaction.ContractGeneric()
            generic.amount = plan.value.bigEndianBytes
            generic.data = data
            tx.transactionOneof = .contractGeneric(generic)
        }
        input.transaction = tx

        let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
        if output.error != .ok {
            throw EthereumDescriptorError.signingFailed(
                output.errorMessage.isEmpty
                    ? "TWC AnySigner error \(output.error.rawValue)"
                    : output.errorMessage
            )
        }
        // The `encoded` field is the wire-ready signed transaction,
        // including the 0x02 EIP-1559 envelope prefix.
        return "0x" + output.encoded.map { String(format: "%02x", $0) }.joined()
    }

    /// EIP-191 `personal_sign`: derive the EOA private key under a
    /// biometric prompt, hash keccak256("\u{19}Ethereum Signed
    /// Message:\n" + len + message), sign with secp256k1, and return the
    /// 65-byte 0x-hex signature (r||s||v) with v in {27,28} as web3
    /// clients expect. The private key is built inside this function and
    /// never escapes it, mirroring `signTransactionFromSandwich`.
    static func signPersonalMessageFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        message: Data,
        biometricReason: String
    ) throws -> String {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        return try signPersonalMessage(
            mnemonic: material.words.joined(separator: " "),
            passphrase: material.hasPassphrase ? material.passphrase : "",
            account: account,
            message: message
        )
    }

    /// Pure EIP-191 `personal_sign` from a mnemonic + passphrase (no biometric
    /// read). Mirrors the Android `EthereumDescriptors.signPersonalMessage`;
    /// exercised directly by the cross-platform KAT. Derives the account key at
    /// m/44'/60'/<account>'/0/0 and returns the 0x-hex r||s||v (v in {27,28}).
    static func signPersonalMessage(
        mnemonic: String,
        passphrase: String,
        account: UInt32,
        message: Data
    ) throws -> String {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: passphrase) else {
            throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let key = wallet.getDerivedKey(coin: .ethereum, account: account, change: 0, address: 0)

        var prefixed = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8)
        prefixed.append(message)
        let digest = Hash.keccak256(data: prefixed)
        guard var sig = key.sign(digest: digest, curve: .secp256k1), sig.count == 65 else {
            throw EthereumDescriptorError.signingFailed("secp256k1 personal_sign failed")
        }
        // TWC returns recid (0/1) in the trailing byte; web3 wants v=27/28.
        sig[64] = sig[64] + 27
        return "0x" + sig.map { String(format: "%02x", $0) }.joined()
    }

    /// EIP-712 `eth_signTypedData_v4` (software). Hashes the standard
    /// `{types,primaryType,domain,message}` JSON with the SAME pure-Rust hasher
    /// the Ledger path uses (so software and hardware signatures agree), then
    /// signs the 32-byte digest with secp256k1 under a biometric prompt. Returns
    /// the 0x-hex r||s||v signature (v in {27,28}) web3 clients expect.
    static func signTypedDataFromSandwich(
        sandwich: IdentitySandwich,
        account: UInt32,
        typedDataJSON: String,
        biometricReason: String
    ) throws -> String {
        let hashes = try hashEip712TypedData(json: typedDataJSON)
        guard hashes.digest.count == 32 else {
            throw EthereumDescriptorError.signingFailed("eip712 digest size \(hashes.digest.count)")
        }
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        guard let wallet = HDWallet(
            mnemonic: material.words.joined(separator: " "),
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw EthereumDescriptorError.hdWalletFailed("HDWallet constructor returned nil")
        }
        let key = wallet.getDerivedKey(coin: .ethereum, account: account, change: 0, address: 0)
        guard var sig = key.sign(digest: hashes.digest, curve: .secp256k1), sig.count == 65 else {
            throw EthereumDescriptorError.signingFailed("secp256k1 eip712 sign failed")
        }
        sig[64] = sig[64] + 27
        return "0x" + sig.map { String(format: "%02x", $0) }.joined()
    }
}
