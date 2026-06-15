// Builds the BIP84 (Native SegWit, P2WPKH) external + internal
// descriptors used by every BitcoinWallet instance.
//
// Three flavours, picked by `BitcoinWallet.open` based on what the
// wallet metadata has cached:
//
//   1. `watchOnlyFromCachedKey(...)` — wallet has cachedXpub +
//      cachedFingerprint persisted on the descriptor. Used on every
//      software-wallet open AFTER the first one, and on every
//      hardware-wallet open. Returns a watch-only descriptor; cannot
//      sign. NO seed access — therefore NO biometric prompt.
//
//   2. `deriveFromSeed(...)` — used ONCE at wallet-creation time (and
//      as a fallback for legacy wallets whose cache is empty).
//      Reads the BIP39 entropy from the Identity Sandwich (one
//      biometric/passcode prompt), derives the account xpub +
//      master fingerprint, returns them to the caller so the caller
//      can cache them on the wallet metadata for the next open.
//      Also returns a watch-only descriptor pair (so the BDK Wallet
//      built from this is watch-only, even at creation).
//
//   3. `transientSignerWallet(...)` — used ONLY at send time. Reads
//      the BIP39 entropy under a "Authorize Bitcoin send" prompt,
//      builds a secret-descriptor BDK Wallet against an in-memory
//      Persister, and returns it. The transient wallet's only job
//      is to sign the PSBT that the watch-only main wallet just
//      built. It's discarded immediately after.

import Foundation
import BitcoinDevKit

enum BitcoinDescriptorError: LocalizedError {
    case sandwichLocked
    case descriptorFailed(String)
    var errorDescription: String? {
        switch self {
        case .sandwichLocked:           return "Identity Sandwich is locked"
        case .descriptorFailed(let m):  return "Could not build descriptor: \(m)"
        }
    }
}

struct BitcoinDescriptorPair {
    let external: Descriptor
    let `internal`: Descriptor
}

/// Result of `deriveFromSeed`. Carries the descriptor pair AND the
/// cacheable account-level public-key material so the caller can
/// avoid asking for the seed again.
struct BitcoinDescriptorSeedDerived {
    let pair: BitcoinDescriptorPair
    let accountFingerprint: String
    let accountXpub: String
}

enum BitcoinDescriptors {

    // MARK: -- watch-only from cached public key (no seed access)

    static func watchOnlyFromCachedKey(
        accountFingerprint: String,
        accountXpub: String,
        network: BitcoinNetwork,
        scriptType: BIP32Path.BitcoinScriptType = .nativeSegwit
    ) throws -> BitcoinDescriptorPair {
        return try watchOnlyFromXpub(
            xpub: accountXpub,
            fingerprint: accountFingerprint,
            network: network,
            scriptType: scriptType
        )
    }

    // MARK: -- one-time derive from sandwich seed

    static func deriveFromSeed(
        sandwich: IdentitySandwich,
        account: UInt32,
        network: BitcoinNetwork,
        biometricReason: String
    ) throws -> BitcoinDescriptorSeedDerived {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        let mnemonic = try Mnemonic.fromString(mnemonic: words)
        let root = DescriptorSecretKey(
            network: network.bdk,
            mnemonic: mnemonic,
            password: material.hasPassphrase ? material.passphrase : nil
        )

        // Derive the account-level secret key, take the public
        // counterpart, and serialize it as the xpub string we cache.
        let pathString = "m/84'/\(network.coinType)'/\(account)'"
        let path = try DerivationPath(path: pathString)
        let accountSecret = try root.derive(path: path)
        let accountPublic = accountSecret.asPublic()
        let accountXpub = String(describing: accountPublic)

        // BDK exposes the BIP32 master fingerprint directly on any
        // DescriptorPublicKey; no need to roll a Base58Check decoder.
        let fingerprint = accountPublic.masterFingerprint()

        let pair = try watchOnlyFromXpub(
            xpub: accountXpub,
            fingerprint: fingerprint,
            network: network
        )
        return BitcoinDescriptorSeedDerived(
            pair: pair,
            accountFingerprint: fingerprint,
            accountXpub: accountXpub
        )
    }

    // MARK: -- transient secret-descriptor signer (send time only)

    static func transientSignerWallet(
        sandwich: IdentitySandwich,
        account: UInt32,
        network: BitcoinNetwork,
        biometricReason: String
    ) throws -> Wallet {
        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        let mnemonic = try Mnemonic.fromString(mnemonic: words)
        let root = DescriptorSecretKey(
            network: network.bdk,
            mnemonic: mnemonic,
            password: material.hasPassphrase ? material.passphrase : nil
        )

        let secret: DescriptorSecretKey
        if account == 0 {
            secret = root
        } else {
            let pathString = "m/84'/\(network.coinType)'/\(account)'"
            let path = try DerivationPath(path: pathString)
            secret = try root.derive(path: path)
        }
        let external = Descriptor.newBip84(secretKey: secret, keychainKind: .external, network: network.bdk)
        let `internal` = Descriptor.newBip84(secretKey: secret, keychainKind: .internal, network: network.bdk)

        let mem = try Persister.newInMemory()
        return try Wallet(
            descriptor: external,
            changeDescriptor: `internal`,
            network: network.bdk,
            persister: mem
        )
    }

    // MARK: -- watch-only from an existing xpub (hardware wallet path)

    /// Build the external + internal watch-only descriptors for the
    /// given account xpub. `scriptType` (from the wallet's path purpose)
    /// selects the BDK template: BIP84 wpkh / BIP49 sh(wpkh) / BIP44 pkh.
    static func watchOnlyFromXpub(
        xpub: String,
        fingerprint: String,
        network: BitcoinNetwork,
        scriptType: BIP32Path.BitcoinScriptType = .nativeSegwit
    ) throws -> BitcoinDescriptorPair {
        // Normalize SLIP-132 alternates (zpub/ypub/vpub/upub/...)
        // to xpub/tpub. BDK's descriptor parser rejects the
        // alternates with "DescriptorKeyParseError: Error while
        // parsing xkey." SeedSigner's BlueWallet export emits a
        // zpub for BIP-84 mainnet, so any SeedSigner-paired
        // wallet hits this path.
        let normalized = ExtendedKeyNormalize.toXpubLegacy(xpub)
        let pub = try DescriptorPublicKey.fromString(publicKey: normalized)
        func make(_ keychain: KeychainKind) throws -> Descriptor {
            switch scriptType {
            case .legacy:
                return try Descriptor.newBip44Public(
                    publicKey: pub, fingerprint: fingerprint,
                    keychainKind: keychain, network: network.bdk
                )
            case .nestedSegwit:
                return try Descriptor.newBip49Public(
                    publicKey: pub, fingerprint: fingerprint,
                    keychainKind: keychain, network: network.bdk
                )
            case .nativeSegwit:
                return try Descriptor.newBip84Public(
                    publicKey: pub, fingerprint: fingerprint,
                    keychainKind: keychain, network: network.bdk
                )
            }
        }
        return BitcoinDescriptorPair(external: try make(.external), internal: try make(.internal))
    }
}
