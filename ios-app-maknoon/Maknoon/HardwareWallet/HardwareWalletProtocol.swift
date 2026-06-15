// Pluggable hardware-wallet interface. Each vendor implementation
// (Trezor BLE, Ledger BLE, mock, future PQ-capable devices) conforms to
// this protocol; the rest of the wallet talks to it only through these
// two methods.
//
// Phase 0 ships only `MockHardwareWallet`. Real BLE clients for Trezor
// Safe 5 and Ledger Nano X are scoped for the post-pilot follow-up:
// each one is a multi-day implementation (vendor framed-message
// protocols, GATT plumbing, user-presence confirmation UX) and they
// can't be tested on the simulator anyway. The wire format is
// vendor-agnostic so adding either later is a drop-in addition.

import Foundation

/// Vendor discriminator. Surfaces in the wire-format `kind` field.
enum HardwareWalletKind: String, CaseIterable, Codable, Sendable {
    case trezor   = "trezor-secp256k1"
    case ledger   = "ledger-secp256k1"
    case mock     = "mock-secp256k1"

    var displayName: String {
        switch self {
        case .trezor: return "Trezor"
        case .ledger: return "Ledger Nano X"
        case .mock:   return "Demo (no hardware)"
        }
    }

    /// True iff this vendor requires a real BLE connection that the
    /// simulator can't service. The picker hides these on simulator
    /// builds.
    var requiresRealHardware: Bool {
        switch self {
        case .trezor, .ledger: return true
        case .mock:            return false
        }
    }
}

/// Common interface every vendor implements. Marked Sendable so
/// the discovery + identity wrap code paths can pass an instance
/// across actor boundaries (the BLE clients serialize through
/// CoreBluetooth's main delegate queue, so cross-actor passes are
/// safe in practice; the conformers declare `@unchecked Sendable`).
protocol HardwareWallet: Sendable {
    var kind: HardwareWalletKind { get }

    /// Lightweight "register the device" handshake. Connects just
    /// long enough to read a stable per-device identifier ("serial")
    /// that Maknoon can recognise on every subsequent reconnect.
    /// Does NOT do any promotion work; no on-device app needs to be
    /// open beyond what the device's transport requires to come
    /// online. The returned string is what gets persisted as
    /// `RegisteredDevice.serial`.
    func identifyDevice() async throws -> String

    /// Pair (or re-pair) with the device. Returns the device's stable
    /// secp256k1 public key. The user typically confirms on-device.
    func pair() async throws -> Data

    /// Sign an arbitrary message with the paired device's secp256k1
    /// key. The user typically confirms on-device for each call.
    func signMessage(_ message: Data) async throws -> Data

    /// Fetch the BIP84 account-level xpub for a given account index +
    /// Bitcoin network. Used at pair-time to build a watch-only BDK
    /// descriptor that we can sync without holding a private key.
    func getBitcoinAccountXpub(account: UInt32, networkCoinType: UInt32) async throws -> String

    /// Fetch the 4-byte BIP32 master fingerprint (8-char lowercase
    /// hex). Required by BDK to build a valid watch-only descriptor
    /// alongside the account xpub. `networkCoinType` is only used for
    /// error-message diagnostics so callers can tell the user to open
    /// "Bitcoin Test" vs "Bitcoin"; the underlying fingerprint is the
    /// same across networks because it's at the root.
    func getBitcoinMasterFingerprint(networkCoinType: UInt32) async throws -> String

    /// Pin the device session open across multiple back-to-back calls
    /// (Discover scans, multi-account adds). Without pinning, every
    /// public method tears the BLE connection down via its trailing
    /// `defer { resetSession() }`, which is right for single-shot ops
    /// (so the next user-initiated op starts from a clean slate) but
    /// wrong for compound flows: the Ledger drops mid-scan when
    /// asked to reconnect 6+ times in rapid succession.
    ///
    /// beginSession() / endSession() are reference-counted; nest them
    /// freely and the underlying teardown only fires once the outer
    /// endSession() runs. Implementations that don't need pinning
    /// (mock, Trezor stub) inherit the no-op default below.
    func beginSession()
    func endSession()

    /// Override the BIP32 derivation path for the next seed-deriving
    /// op(s); nil = the chain's standard path from `account`. MUST be a
    /// protocol requirement (not extension-only) so a call through the
    /// `HardwareWallet` type dispatches to the Ledger / Trezor override
    /// rather than the no-op default. Mock / YubiKey inherit the no-op.
    func setDerivationPathOverride(_ path: String?)

    /// Fetch the Ethereum EOA address for a given BIP44 account
    /// index (m/44'/60'/<account>'/0/0). Returns the EIP-55
    /// checksummed `0x...` hex string. Used by the Ethereum
    /// AddWalletFromDevice flow to register a watch-only hardware
    /// wallet against an EVM network.
    func getEthereumAddress(account: UInt32) async throws -> String

    /// Sign a PSBT for a Bitcoin transaction. Returns the signed PSBT
    /// bytes; the caller (BDK) finalises and broadcasts. Each input
    /// requires on-device approval; cancellation surfaces as
    /// `HardwareWalletError.userCancelled`.
    func signPSBT(_ psbt: Data, networkCoinType: UInt32) async throws -> Data

    /// Sign an EIP-1559 Ethereum transaction. `envelope` is the
    /// 0x02-prefixed unsigned RLP blob (see `EthereumTxEncoder
    /// .unsignedEnvelope`). `account` selects the BIP44 derivation
    /// path m/44'/60'/<account>'/0/0. Returns parity-bit V (0 or 1)
    /// plus the 32-byte R / S signature components.
    ///
    /// `erc20Descriptor`, when non-nil, is a Ledger-signed CAL token
    /// blob (`LedgerERC20Descriptors`) provided to the device before
    /// signing so it clear-signs an ERC-20 transfer instead of
    /// demanding blind signing. Implementations that don't support it
    /// ignore the argument.
    func signEthereumTransaction(
        envelope: Data,
        account: UInt32,
        erc20Descriptor: Data?
    ) async throws -> (v: UInt8, r: Data, s: Data)

    // MARK: -- Solana
    //
    // BIP44 m/44'/501'/<account>'/0' for Ed25519 / SLIP-0010.
    // Both Ledger Solana app and Trezor (firmware 2.6.4+) implement
    // these. Tron is Ledger-only; Trezor firmware does not support
    // it and the corresponding capability bit stays off on
    // `DeviceKind.trezor`.

    /// Fetch the Solana base58 32-byte public key (which IS the
    /// address) for a given BIP44 account index. Used at pair-time
    /// to register a watch-only Solana wallet.
    func getSolanaAddress(account: UInt32) async throws -> String

    /// Sign a Solana transaction. `unsignedTx` is the serialized
    /// message bytes (Solana's compact-array format, not the full
    /// transaction wrapper). Returns the 64-byte Ed25519 signature.
    /// Network (mainnet-beta / devnet / testnet) is a host-side
    /// concern; the device signs the same payload regardless.
    func signSolanaTransaction(unsignedTx: Data, account: UInt32) async throws -> Data

    // MARK: -- Tron
    //
    // BIP44 m/44'/195'/<account>'/0/0 for secp256k1. Ledger only;
    // Trezor firmware does not implement Tron.

    /// Fetch the Tron base58check `T...` address for a given BIP44
    /// account index.
    func getTronAddress(account: UInt32) async throws -> String

    /// Fetch the uncompressed 65-byte secp256k1 public key for the
    /// Tron BIP44 account. Required by TWC's TransactionCompiler
    /// when assembling a hardware-signed Tron transaction (the
    /// `Transaction.signature` field references the signer pubkey).
    func getTronPubkey(account: UInt32) async throws -> Data

    /// Sign a Tron transaction. `rawTxProto` is the serialized
    /// `Transaction.raw_data` protobuf blob. Returns the secp256k1
    /// (r, s, v) tuple over keccak256(rawTxProto), Ethereum-style.
    func signTronTransaction(
        rawTxProto: Data,
        account: UInt32
    ) async throws -> (v: UInt8, r: Data, s: Data)

    /// iOS-stable BLE peripheral identifier the wallet most recently
    /// connected to, if any. Captured at pair time and persisted on
    /// the `RegisteredDevice` so later reconnects can hard-filter
    /// scans to this specific peripheral and never accidentally
    /// connect to a different Ledger / Trezor the user also owns.
    /// Returns nil for transports that don't expose one (USB-C
    /// YubiKey, SeedSigner camera-only).
    var currentBLEPeripheralUUID: UUID? { get }
}

// Default implementations so vendors that have not implemented the
// new methods (today: Trezor, Mock, plus YubiKey for everything)
// still compile.
extension HardwareWallet {
    func identifyDevice() async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func getBitcoinAccountXpub(account: UInt32, networkCoinType: UInt32) async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func getBitcoinMasterFingerprint(networkCoinType: UInt32 = 0) async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func beginSession() {}
    func endSession() {}
    /// Override the BIP32 derivation path for the NEXT seed-deriving
    /// op(s) on this client. `nil` (the default) uses the chain's
    /// standard path from `account`. Set right before an add / discover
    /// / sign op for a custom- or alternative-path wallet. Vendors that
    /// don't support custom paths (Mock, YubiKey) inherit this no-op.
    func setDerivationPathOverride(_ path: String?) {}
    func getEthereumAddress(account: UInt32) async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func signPSBT(_ psbt: Data, networkCoinType: UInt32) async throws -> Data {
        throw HardwareWalletError.notImplemented(kind)
    }
    func signEthereumTransaction(
        envelope: Data,
        account: UInt32,
        erc20Descriptor: Data? = nil
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        throw HardwareWalletError.notImplemented(kind)
    }

    func getSolanaAddress(account: UInt32) async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func signSolanaTransaction(unsignedTx: Data, account: UInt32) async throws -> Data {
        throw HardwareWalletError.notImplemented(kind)
    }
    func getTronAddress(account: UInt32) async throws -> String {
        throw HardwareWalletError.notImplemented(kind)
    }
    func getTronPubkey(account: UInt32) async throws -> Data {
        throw HardwareWalletError.notImplemented(kind)
    }
    func signTronTransaction(
        rawTxProto: Data,
        account: UInt32
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        throw HardwareWalletError.notImplemented(kind)
    }

    /// Default for non-BLE wallets (YubiKey, SeedSigner, Mock).
    /// BLE implementations override.
    var currentBLEPeripheralUUID: UUID? { nil }
}

/// Errors surfaced from hardware-wallet code paths.
///
/// LocalizedError conformance is important: without it, the default
/// Swift Error → NSError bridge produces "The operation couldn't be
/// completed. (Maknoon.HardwareWalletError error 1.)" — generic and
/// useless. With it, `localizedDescription` returns the real
/// `description` text, so callers that wrap by `error.localizedDescription`
/// (the UniFFI Rust foreign-error path does this) surface the actual
/// reason instead of the bridge boilerplate.
enum HardwareWalletError: Error, CustomStringConvertible, LocalizedError {
    case notImplemented(HardwareWalletKind)
    case userCancelled
    case transport(String)

    var description: String {
        switch self {
        case .notImplemented(let k):
            return "\(k.displayName) BLE client not yet shipped; pair with \(HardwareWalletKind.mock.displayName) for now."
        case .userCancelled:
            return "User cancelled on-device confirmation"
        case .transport(let m):
            return "Hardware transport error: \(m)"
        }
    }

    /// LocalizedError conformance. Returns the human-readable
    /// `description` so callers reading `error.localizedDescription`
    /// (notably the UniFFI Rust foreign-error path) see the actual
    /// reason instead of "The operation couldn't be completed.
    /// (Maknoon.HardwareWalletError error 1.)".
    var errorDescription: String? { description }
}

/// Build a vendor-specific client.
///
/// On the simulator, real BLE transports are not available, so we
/// route `.ledger` and `.trezor` through `MockHardwareWallet`. That
/// lets the holder app demo every hardware-touching flow (identity
/// wrap, chain wallet pairing, message signing) end-to-end without
/// physical devices. On a real iOS device the BLE clients are used
/// unchanged.
enum HardwareWalletFactory {

    // Each call returns a FRESH BLE client. Earlier this returned a
    // shared singleton on the theory that BLE state benefits from
    // continuity across calls, but in practice singleton state
    // outlives our reset paths in subtle ways (CBCentralManager
    // internal state persisting after `central = nil`, characteristic
    // proxies surviving peripheral nil-out, etc) and produced
    // intermittent connect timeouts on retry. Fresh instance per
    // call guarantees zero stale BLE state inside Maknoon; iOS's
    // own BLE bond cache is a separate issue and only a phone
    // restart clears that one.

    static func make(kind: HardwareWalletKind) -> HardwareWallet {
        #if targetEnvironment(simulator)
        if kind == .ledger || kind == .trezor {
            return MockHardwareWallet()
        }
        #endif
        switch kind {
        case .trezor: return TrezorBLE()
        case .ledger: return LedgerBLE()
        case .mock:   return MockHardwareWallet()
        }
    }
}

