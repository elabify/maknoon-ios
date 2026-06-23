// Demo mock hardware wallet. Lets the simulator exercise every
// hardware-touching flow end-to-end: device pairing, identity-
// sandwich wrap/unwrap, chain attestations.
//
// The mock kind is `mock-secp256k1`. The verifier-server has a
// matching special-case path that accepts mock attestations on the
// basis of structural validity only (`kind`, `masterPubkey`,
// `attestorPubkey` are well-formed). Real `trezor-secp256k1` and
// `ledger-secp256k1` kinds go through proper secp256k1 ECDSA
// verification with `@noble/secp256k1`.
//
// `signMessage` is deterministic per (pubkey, message) so the
// Identity Sandwich wrap path works: HKDF of the same signature
// produces the same wrap key on the next unlock attempt, mirroring
// Ledger's RFC6979-deterministic personal_sign.

import Foundation
import CryptoKit

struct MockHardwareWallet: HardwareWallet {
    var kind: HardwareWalletKind { .mock }

    /// Fixed 33-byte compressed-format secp256k1 pubkey for the demo
    /// "device". Stable so the user can see the same pubkey reappear
    /// across pair / unpair cycles (matches the real-device experience
    /// where a Trezor's master pubkey doesn't change across pairings).
    static let demoPubkey: Data = {
        let hex = "02deadbeefcafebabe000000000000000000000000000000000000000000000001"
        return Data(hexEncoded: hex)
    }()

    /// Stable identifier returned by `identifyDevice`. Mirrors the
    /// real-device contract: the same physical unit reports the same
    /// serial across pair / unpair cycles. The Identity Sandwich
    /// wrap layer uses this as authenticated data so a sealed blob
    /// can't be opened by a different mock instance (in practice
    /// there's only one on the sim, but the wire is real).
    static let demoSerial: String = "MOCK-DEMO-DEVICE-0001"

    func identifyDevice() async throws -> String {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return Self.demoSerial
    }

    func pair() async throws -> Data {
        // Simulate the device's user-confirmation latency.
        try? await Task.sleep(nanoseconds: 700_000_000)
        return Self.demoPubkey
    }

    /// Deterministic pseudo-signature: SHA-256(pubkey || msg) ||
    /// SHA-256(msg || pubkey). 64 bytes, byte-identical for repeat
    /// calls with the same message. Matches the RFC6979 contract
    /// real Ledger / Trezor devices honour for personal_sign, which
    /// is what the Identity Sandwich wrap path relies on.
    func signMessage(_ message: Data) async throws -> Data {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let h1 = SHA256.hash(data: Self.demoPubkey + message)
        let h2 = SHA256.hash(data: message + Self.demoPubkey)
        return Data(h1) + Data(h2)
    }

    /// Deterministic V/R/S for SIGN_TRANSACTION. SHA-256(envelope ||
    /// account) split across R and S. V alternates 0/1 by parity of
    /// the envelope length. The verifier server special-cases mock
    /// signatures so the broadcast obviously fails on real RPCs
    /// (the demo signer isn't a valid secp256k1 key on chain) but
    /// the entire pre-broadcast pipeline can be demoed on sim.
    func signEthereumTransaction(
        envelope: Data,
        account: UInt32,
        erc20Descriptor: Data? = nil
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        // The mock has no device to clear-sign on; erc20Descriptor is
        // accepted for protocol parity and ignored.
        _ = erc20Descriptor
        try? await Task.sleep(nanoseconds: 600_000_000)
        var input = envelope
        var be = account.bigEndian
        withUnsafeBytes(of: &be) { input.append(contentsOf: $0) }
        let h1 = SHA256.hash(data: Self.demoPubkey + input)
        let h2 = SHA256.hash(data: input + Self.demoPubkey)
        return (
            v: UInt8(envelope.count & 0x01),
            r: Data(h1),
            s: Data(h2)
        )
    }

    /// Deterministic Ethereum address per account index. Real Ledger
    /// runs keccak256(pubkey).last(20); the Mock skips the secp256k1
    /// step and just hashes the demo pubkey + account so the
    /// simulator demo lands on a stable, account-distinct address.
    /// EIP-55 checksumming is intentional so the displayed address
    /// looks like the real thing.
    func getEthereumAddress(account: UInt32) async throws -> String {
        try? await Task.sleep(nanoseconds: 300_000_000)
        var input = Self.demoPubkey
        var be = account.bigEndian
        withUnsafeBytes(of: &be) { input.append(contentsOf: $0) }
        let hash = SHA256.hash(data: input)
        let last20 = Data(hash.suffix(20))
        return Self.eip55(addressHex20: last20)
    }

    /// Inline EIP-55 mixed-case checksum so the Mock doesn't need to
    /// import WalletCore. Lowercase hex of the 20 address bytes,
    /// hash via SHA-256 (instead of keccak256: this is a mock,
    /// the address string format is the demo property, not the
    /// hash). Real device path is in `LedgerBLE.eip55Checksum`.
    private static func eip55(addressHex20: Data) -> String {
        let lower = addressHex20.map { String(format: "%02x", $0) }.joined()
        let hash = SHA256.hash(data: Data(lower.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (i, ch) in lower.enumerated() {
            let nibble = hashHex[hashHex.index(hashHex.startIndex, offsetBy: i)]
            if let n = nibble.hexDigitValue, n >= 8, ch.isLetter {
                out.append(ch.uppercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

private extension Data {
    init(hexEncoded hex: String) {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        precondition(s.count.isMultiple(of: 2), "hex string must have even length")
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            bytes.append(UInt8(s[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = Data(bytes)
    }
}
