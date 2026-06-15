// Pairing + attestation orchestration. The wallet UI calls this; it
// delegates the BLE bits to the per-vendor client and handles the
// "produce a HardwareAttestation" + Keychain persistence.
//
// Wire shape:
//
//   HardwareAttestation {
//     kind: trezor-secp256k1 | ledger-secp256k1 | mock-secp256k1,
//     masterPubkey: hex of holder's ML-DSA-65 pubkey,
//     attestorPubkey: hex of the device's secp256k1 pubkey,
//     attestorSig: hex of secp256k1 ECDSA over
//                  canonicalize({kind, masterPubkey, attestorPubkey}),
//   }
//
// Persisted in Keychain (non-biometric class — neither pubkey nor sig
// is a secret). Re-attested only when the user explicitly rotates
// hardware wallets or restores from a different identity.

import Foundation
import ElabifyCore

enum HardwareWalletManager {

    /// Pair `kind` and produce a fresh attestation binding it to the
    /// holder's master pubkey. Persists the result into Keychain.
    static func pairAndAttest(
        kind: HardwareWalletKind,
        masterPubkey: Data
    ) async throws -> HardwareAttestation {
        let wallet = HardwareWalletFactory.make(kind: kind)
        // Pin the session so pair() + signMessage() reuse one
        // connection (one handshake) instead of reconnecting per op.
        wallet.beginSession()
        defer { wallet.endSession() }
        let attestorPubkey = try await wallet.pair()

        // The canonical signed payload. Same field ordering as the
        // verifier server's `verifyHardwareAttestation` helper.
        let masterHex   = "0x" + bytesToHex(masterPubkey)
        let attestorHex = "0x" + bytesToHex(attestorPubkey)
        let canonical: [String: Any] = [
            "kind":           kind.rawValue,
            "masterPubkey":   masterHex,
            "attestorPubkey": attestorHex,
        ]
        let msg = try canonicalize(canonical)
        let sig = try await wallet.signMessage(msg)

        let attestation = HardwareAttestation(
            kind: kind.rawValue,
            masterPubkey: masterHex,
            attestorPubkey: attestorHex,
            attestorSig: "0x" + bytesToHex(sig)
        )

        try persist(attestation)
        return attestation
    }

    /// Reload the persisted attestation, if any.
    static func loadAttestation() -> HardwareAttestation? {
        guard let data = try? KeyStore.load(forKey: KeyStoreKeys.hardwareAttestation) else {
            return nil
        }
        return try? JSONDecoder().decode(HardwareAttestation.self, from: data)
    }

    /// Wipe the persisted attestation.
    static func unpair() throws {
        try KeyStore.delete(forKey: KeyStoreKeys.hardwareAttestation)
    }

    // MARK: -- helpers

    private static func persist(_ attestation: HardwareAttestation) throws {
        let data = try JSONEncoder().encode(attestation)
        try KeyStore.save(data, forKey: KeyStoreKeys.hardwareAttestation, requireBiometric: false)
    }

    private static func bytesToHex(_ d: Data) -> String {
        let alphabet: [Character] = Array("0123456789abcdef")
        var s = String()
        s.reserveCapacity(d.count * 2)
        for byte in d {
            s.append(alphabet[Int(byte >> 4)])
            s.append(alphabet[Int(byte & 0x0f)])
        }
        return s
    }
}
