// Shared signing-dispatch helpers used by both the regular Send
// flow (BitcoinSendView) and the RBF fee-bump flow (BumpFeeSheet).
// Identical signing protocols across both paths, only the source
// of the unsigned PSBT differs.

import BitcoinDevKit
import Foundation

enum BitcoinSigningHelpers {

    /// Software-wallet sign: build a transient secret-descriptor BDK
    /// wallet from the identity sandwich, sign the PSBT, return the
    /// signed base64. The transient wallet is in-memory and
    /// discarded immediately after; the seed material it derives
    /// from is captured only inside `recoveryMaterial(...)` which
    /// iOS clears from memory when the closure exits.
    @MainActor
    static func signSoftware(
        unsignedBase64: String,
        sandwich: IdentitySandwich,
        account: UInt32,
        network: BitcoinNetwork
    ) throws -> String {
        let transient = try BitcoinDescriptors.transientSignerWallet(
            sandwich: sandwich,
            account: account,
            network: network,
            biometricReason: "Authorize Bitcoin send"
        )
        let psbt = try Psbt(psbtBase64: unsignedBase64)
        // `trustWitnessUtxo: true` is required when the PSBT only
        // carries `witness_utxo` for its inputs (no full prev tx).
        // BDK's TxBuilder.finish() emits witness-utxo-only PSBTs for
        // segwit inputs by default; the default SignOptions has
        // `trustWitnessUtxo: false` and silently signs nothing on
        // such inputs, leaving the PSBT with no partial_sigs and
        // breaking the downstream finalize with "Missing pubkey for
        // a pkh/wpkh." See <https://blog.trezor.io/...> for the
        // SegWit-bug rationale; safe here because we built the PSBT
        // ourselves and trust our own witness_utxo values.
        let opts = SignOptions(
            trustWitnessUtxo: true,
            assumeHeight: nil,
            allowAllSighashes: false,
            tryFinalize: true,
            signWithTapInternalKey: true,
            allowGrinding: true
        )
        let signed = try transient.sign(psbt: psbt, signOptions: opts)
        // BDK returns `true` only when the PSBT is fully finalized.
        // `false` can still mean "partial_sigs were added" for a
        // multi-sig setup, but for our single-sig wallets it always
        // means "nothing matched", surface that loudly instead of
        // letting the user hit "Missing pubkey" on broadcast.
        let inputs = psbt.input()
        let totalSigs = inputs.reduce(0) { $0 + $1.partialSigs.count }
        guard signed || totalSigs > 0 else {
            let derivs = inputs.enumerated().map { idx, inp -> String in
                let keys = inp.bip32Derivation.keys.map { String($0.prefix(12)) }.joined(separator: ",")
                return "in[\(idx)] derivs=[\(keys)]"
            }.joined(separator: " | ")
            throw BitcoinWallet.WalletError.sendFailed(
                "Software signer produced no signatures (descriptor / fingerprint mismatch?). \(derivs)"
            )
        }
        return psbt.serialize()
    }

    /// Hardware-BLE sign: connect to the paired device over its
    /// vendor transport (today: Ledger BLE via ledger-btc-core),
    /// run SIGN_PSBT, return the signed PSBT base64 with partial
    /// signatures merged in.
    static func signOverBLE(
        unsignedBase64: String,
        device: RegisteredDevice,
        fingerprintHex: String,
        accountXpub: String,
        network: BitcoinNetwork,
        hidden: HardwarePassphraseRef? = nil,
        derivationPath: String? = nil,
        hostEntered: String? = nil
    ) async throws -> String {
        let coinType: UInt32 = network == .mainnet ? 0 : 1
        switch device.kind {
        case .ledger:
            let ledger = HardwareWalletFactory.make(kind: .ledger)
            guard let ledger = ledger as? LedgerBLE else {
                throw BitcoinWallet.WalletError.sendFailed("Expected LedgerBLE instance, got \(type(of: ledger))")
            }
            // Bind to this specific physical Ledger so a different
            // paired Ledger nearby can't accidentally pick up the
            // request (multi-device safety, Week 8 work).
            ledger.targetPeripheralUUID = device.peripheralUUID
            ledger.setDerivationPathOverride(derivationPath)
            return try await ledger.signBitcoinPSBT(
                unsignedBase64: unsignedBase64,
                fingerprintHex: fingerprintHex,
                accountXpub: accountXpub,
                account: 0,
                coinType: coinType
            )
        case .trezor:
            let trezor = HardwareWalletFactory.make(kind: .trezor)
            guard let trezor = trezor as? TrezorBLE else {
                throw BitcoinWallet.WalletError.sendFailed("Expected TrezorBLE instance, got \(type(of: trezor))")
            }
            trezor.targetPeripheralUUID = device.peripheralUUID
            // A hidden wallet must re-open its passphrase session so the
            // device derives the matching keys; standard wallets resolve
            // to `.standard`.
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
            trezor.setDerivationPathOverride(derivationPath)
            return try await trezor.signBitcoinPSBT(
                unsignedBase64: unsignedBase64,
                fingerprintHex: fingerprintHex,
                accountXpub: accountXpub,
                account: 0,
                coinType: coinType
            )
        default:
            throw BitcoinWallet.WalletError.sendFailed(
                "Device kind \(device.kind.displayName) does not support BLE Bitcoin signing yet"
            )
        }
    }

    /// Hardware-BLE message sign: connect to the paired device, sign the
    /// arbitrary message at the full BIP32 `path`, and return the signed-for
    /// address + the base64 "Bitcoin Signed Message" signature. Supports
    /// hidden (passphrase) wallets via `hidden` + `hostEntered`, exactly like
    /// the PSBT send path. Works for Trezor and Ledger.
    static func signMessageOverBLE(
        device: RegisteredDevice,
        path: String,
        message: Data,
        network: BitcoinNetwork,
        hidden: HardwarePassphraseRef? = nil,
        hostEntered: String? = nil
    ) async throws -> (address: String, signature: String) {
        let coinType: UInt32 = network == .mainnet ? 0 : 1
        switch device.kind {
        case .trezor:
            let trezor = HardwareWalletFactory.make(kind: .trezor)
            guard let trezor = trezor as? TrezorBLE else {
                throw BitcoinWallet.WalletError.sendFailed("Expected TrezorBLE instance, got \(type(of: trezor))")
            }
            trezor.targetPeripheralUUID = device.peripheralUUID
            // A hidden wallet re-opens its passphrase session so the device
            // derives the matching key; standard wallets resolve to `.standard`.
            trezor.applyPassphraseMode(try HardwarePassphraseRef.resolveChoice(hidden, hostEntered: hostEntered))
            let addressN = try BIP32Path.parse(path)
            let r = try await trezor.signBitcoinMessage(addressN: addressN, message: message, coinType: coinType)
            return (r.address, r.signature.base64EncodedString())
        case .ledger:
            let ledger = HardwareWalletFactory.make(kind: .ledger)
            guard let ledger = ledger as? LedgerBLE else {
                throw BitcoinWallet.WalletError.sendFailed("Expected LedgerBLE instance, got \(type(of: ledger))")
            }
            ledger.targetPeripheralUUID = device.peripheralUUID
            return try await ledger.signBitcoinMessage(path: path, message: message, network: network)
        default:
            throw BitcoinWallet.WalletError.sendFailed(
                "Device kind \(device.kind.displayName) does not support message signing yet"
            )
        }
    }

    /// Surface a compact, human-readable debug code from common
    /// error types we expect at the signing boundary. Returned
    /// string is suitable for display next to the user-facing
    /// error message ("Debug code: SW 0x6985"). Nil for errors
    /// where no recognizable code exists.
    static func extractDebugCode(_ error: Error) -> String? {
        if let le = error as? LedgerError {
            switch le {
            case .DeviceRejected(let sw, _):
                return String(format: "SW 0x%04X", sw)
            case .UserCanceled:
                return "0x6985 (user canceled)"
            case .Transport:     return "LedgerError.Transport"
            case .InvalidPsbt:   return "LedgerError.InvalidPsbt"
            case .InvalidPolicy: return "LedgerError.InvalidPolicy"
            case .Protocol:      return "LedgerError.Protocol"
            }
        }
        if let hwe = error as? HardwareWalletError {
            return "\(hwe)"
        }
        return nil
    }
}
