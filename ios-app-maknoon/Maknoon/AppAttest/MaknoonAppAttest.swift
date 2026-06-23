// Apple App Attest wrapper for Maknoon's verified-identity flow.
//
// App Attest gives the issuer a cryptographic proof that a request
// originated from the legitimate Elabify-signed Maknoon binary
// running on real Apple silicon. Without this, anyone could POST
// fabricated chip data to the issuer endpoint.
//
// Lifecycle:
//   1. First time: `generateAndAttestKey()` creates a key pair on
//      the Secure Enclave, gets an attestation from Apple's servers,
//      and persists the key id to UserDefaults so future requests
//      reuse the same identity.
//   2. Per request: `assert(over:)` signs the SHA-256 of the
//      request body. The issuer verifies the assertion against the
//      attestation it received during enrollment.
//
// Both calls require a real device; the simulator returns
// `notSupported` from DCAppAttestService. App Store builds use
// the production environment; development builds use sandbox.
// The Apple Developer entitlement is gated by MAKNOON_NFC since
// it's the same paid-team gate.

import Foundation
import DeviceCheck
import CryptoKit

enum MaknoonAppAttestError: LocalizedError {
    case notSupported
    case keyGenerationFailed(String)
    case attestationFailed(String)
    case assertionFailed(String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest isn't supported on this device. Run on a real iPhone with iOS 14 or newer."
        case .keyGenerationFailed(let s):
            return "Couldn't generate the App Attest key: \(s)"
        case .attestationFailed(let s):
            return "Couldn't fetch attestation from Apple: \(s)"
        case .assertionFailed(let s):
            return "Couldn't sign the request: \(s)"
        case .missingKey:
            return "No App Attest key exists yet. Run enrollment first."
        }
    }
}

/// Output of the enrollment step. The issuer needs all three to
/// store the attestation record for future assertion checks.
struct AppAttestEnrollment: Codable, Sendable {
    /// Apple-issued key identifier (base64).
    let keyId: String
    /// CBOR-encoded attestation object from Apple's server (base64).
    let attestation: String
    /// The challenge the issuer gave us; included so the server can
    /// match the attestation against the challenge it issued.
    let challenge: String
}

/// Output of a per-request assertion. The issuer recombines the
/// payload with the assertion to verify under the previously-stored
/// attestation key.
struct AppAttestAssertion: Codable, Sendable {
    let keyId: String
    /// CBOR-encoded assertion object from `generateAssertion` (base64).
    let assertion: String
    /// The client-supplied payload that was signed (echoed for the
    /// server's convenience; should be re-computed server-side from
    /// the actual request body).
    let clientDataHash: String  // hex
}

@MainActor
final class MaknoonAppAttest {
    static let shared = MaknoonAppAttest()

    private static let keyIDDefaultsKey = "appAttest.keyId.v1"
    private static let attestationDefaultsKey = "appAttest.attestation.v1"
    private static let attestationChallengeKey = "appAttest.attestationChallenge.v1"

    private init() {}

    /// Produce a self-issuer App Attest binding for a locally-minted
    /// credential: enroll once (challenge = holderDID, attestation cached so
    /// re-attestation isn't needed), then assert over the credential binding
    /// bytes. Returns nil when App Attest is unavailable (simulator /
    /// unsupported / offline first-enroll), so the credential degrades to
    /// key-only. The enrollment needs network the first time; assertions are
    /// offline.
    func selfIssuerAttestation(holderDID: String, bindingBytes: Data) async -> SelfIssuerAttestation? {
        guard isSupported else { return nil }
        let challengeB64 = Data(holderDID.utf8).base64EncodedString()
        do {
            let attestationB64: String
            if let cached = UserDefaults.standard.string(forKey: Self.attestationDefaultsKey),
               UserDefaults.standard.string(forKey: Self.attestationChallengeKey) == challengeB64,
               existingKeyId != nil {
                attestationB64 = cached
            } else {
                let enrollment = try await generateAndAttestKey(issuerChallenge: Data(holderDID.utf8))
                UserDefaults.standard.set(enrollment.attestation, forKey: Self.attestationDefaultsKey)
                UserDefaults.standard.set(challengeB64, forKey: Self.attestationChallengeKey)
                attestationB64 = enrollment.attestation
            }
            let assertion = try await assert(over: bindingBytes)
            let bindingHash = Data(SHA256.hash(data: bindingBytes))
            return SelfIssuerAttestation(
                keyId: assertion.keyId,
                attestation: attestationB64,
                assertion: assertion.assertion,
                bindingHashHex: "0x" + bindingHash.map { String(format: "%02x", $0) }.joined()
            )
        } catch {
            LogStore.shared.warn("appattest", "self-issuer attestation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// True when the framework can do anything on this device.
    var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    /// Stored key id from a prior `generateAndAttestKey(...)` call,
    /// or nil if the user has never enrolled.
    var existingKeyId: String? {
        UserDefaults.standard.string(forKey: Self.keyIDDefaultsKey)
    }

    /// Enroll this device: create a fresh attestation key + get
    /// Apple's attestation over an issuer-supplied challenge. The
    /// returned `AppAttestEnrollment` goes to the issuer once;
    /// every subsequent request uses `assert(over:)`.
    func generateAndAttestKey(issuerChallenge: Data) async throws -> AppAttestEnrollment {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw MaknoonAppAttestError.notSupported }

        let keyId: String
        if let existing = existingKeyId {
            keyId = existing
        } else {
            keyId = try await withCheckedThrowingContinuation { cont in
                service.generateKey { id, err in
                    if let err {
                        cont.resume(throwing: MaknoonAppAttestError.keyGenerationFailed(err.localizedDescription))
                        return
                    }
                    guard let id else {
                        cont.resume(throwing: MaknoonAppAttestError.keyGenerationFailed("nil keyId"))
                        return
                    }
                    cont.resume(returning: id)
                }
            }
            UserDefaults.standard.set(keyId, forKey: Self.keyIDDefaultsKey)
        }

        // Apple requires the challenge be hashed before attest.
        let clientDataHash = Data(SHA256.hash(data: issuerChallenge))
        let attestation: Data = try await withCheckedThrowingContinuation { cont in
            service.attestKey(keyId, clientDataHash: clientDataHash) { data, err in
                if let err {
                    cont.resume(throwing: MaknoonAppAttestError.attestationFailed(err.localizedDescription))
                    return
                }
                guard let data else {
                    cont.resume(throwing: MaknoonAppAttestError.attestationFailed("nil attestation"))
                    return
                }
                cont.resume(returning: data)
            }
        }

        return AppAttestEnrollment(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: issuerChallenge.base64EncodedString()
        )
    }

    /// Per-request signature. `payload` is the raw bytes the issuer
    /// will verify against (typically the JSON-encoded request body).
    /// The assertion is what the issuer needs to confirm Maknoon
    /// signed THIS request with the enrolled key.
    func assert(over payload: Data) async throws -> AppAttestAssertion {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw MaknoonAppAttestError.notSupported }
        guard let keyId = existingKeyId else { throw MaknoonAppAttestError.missingKey }
        let clientDataHash = Data(SHA256.hash(data: payload))
        let assertion: Data = try await withCheckedThrowingContinuation { cont in
            service.generateAssertion(keyId, clientDataHash: clientDataHash) { data, err in
                if let err {
                    cont.resume(throwing: MaknoonAppAttestError.assertionFailed(err.localizedDescription))
                    return
                }
                guard let data else {
                    cont.resume(throwing: MaknoonAppAttestError.assertionFailed("nil assertion"))
                    return
                }
                cont.resume(returning: data)
            }
        }
        return AppAttestAssertion(
            keyId: keyId,
            assertion: assertion.base64EncodedString(),
            clientDataHash: clientDataHash.map { String(format: "%02x", $0) }.joined()
        )
    }
}
