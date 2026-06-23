// Per-INSTALLATION merchant verifier identity (ML-DSA-65), separate from the
// holder's consumer Identity Sandwich.
//
// Each installed merchant app (the POS) gets its own stable verifier key + DID,
// keyed by its installedAppId, so a merchant's settings are self-contained to
// that installation (uninstall wipes it; reinstall starts fresh + re-registers).
// The app signs its VerifierRequests / CommerceRequests with this key so the
// customer's wallet resolves a consistent `verifierDid -> pubkey` against
// Elabify's curated registry and shows "Verified: <Merchant>" once registered;
// until then requests are self-signed (pubkey inlined) with this same stable key.
//
// Device-only: the seed lives in the Keychain (ThisDeviceOnly, non-biometric so
// generating a request QR is silent) and never travels in the encrypted backup.
// Curated registration is manual (sales@elabify.com); no self-service API here.

import Foundation
import CryptoKit
import ElabifyCore

final class MerchantIdentityStore: @unchecked Sendable {
    private static func seedKey(_ installedAppId: String) -> String {
        "merchant.mldsaSeed.v1." + installedAppId
    }

    private func publicKey(_ installedAppId: String) -> Data? {
        guard let seed = try? KeyStore.load(forKey: Self.seedKey(installedAppId)),
              let pk = try? MLDSAClient.masterPublicKey(fromSeed: seed) else { return nil }
        return pk
    }

    /// 0x-prefixed public key hex (for the registry entry + inline self-signed QRs).
    func publicKeyHex(_ installedAppId: String) -> String? {
        publicKey(installedAppId).map { "0x" + $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// Stable did:elabify verifier DID derived from the pubkey (RPO-256 tagged),
    /// mirroring the holder DID scheme. nil until provisioned.
    func did(_ installedAppId: String) -> String? {
        guard let pk = publicKey(installedAppId) else { return nil }
        let user = ElabifyCore.rpo256Tagged(0x03, pk)
        let hex = user.prefix(20).map { String(format: "%02x", $0) }.joined()
        return "did:elabify:sepolia:verifier:0x" + hex
    }

    /// Ensure a key exists for this install, generating + persisting on first use.
    @discardableResult
    func ensureProvisioned(_ installedAppId: String) throws -> String {
        if let did = did(installedAppId) { return did }
        let (_, seed) = try MLDSAClient.generateMaster()
        try KeyStore.save(seed, forKey: Self.seedKey(installedAppId), requireBiometric: false)
        guard let did = did(installedAppId) else {
            throw KeyStoreError.unexpected("merchant DID unavailable after provisioning")
        }
        return did
    }

    /// Sign `message` with this install's merchant key (provisions on first use).
    func sign(_ installedAppId: String, _ message: Data) throws -> Data {
        try ensureProvisioned(installedAppId)
        guard let seed = try KeyStore.load(forKey: Self.seedKey(installedAppId)) else {
            throw KeyStoreError.unexpected("merchant seed missing after provisioning")
        }
        return try MLDSAClient.signWithMaster(seed: seed, message: message)
    }

    /// Wipe this install's identity (called on uninstall).
    func evict(_ installedAppId: String) {
        try? KeyStore.delete(forKey: Self.seedKey(installedAppId))
    }
}
