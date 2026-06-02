// Synthetic-CA harness for AppAttestVerifier. A throwaway root + intermediate
// + leaf (carrying an App Attest nonce extension bound to a known authData +
// holderDID) were generated offline with openssl and embedded below; the
// leaf private key signs a fresh assertion at test time. This drives the full
// verifier pipeline (chain to the synthetic root, App ID, nonce binding,
// assertion signature, per-credential binding). Production swaps in Apple's
// real App Attest root via the bundled PEM; only the trust anchor differs.

import XCTest
import Security
import CryptoKit
@testable import Maknoon

final class AppAttestVerifierTests: XCTestCase {

    private let appID = "TEST123456.com.elabify.app.maknoon.test"
    private let holderDID = "did:elabify:sepolia:holder:0x1122334455667788990011223344556677889900"
    private let bindingBytes = Data("appattest-binding-fixture".utf8)

    // openssl-generated fixtures (see commit message / generation notes).
    private let rootB64 = "MIIBkjCCATegAwIBAgIUGFpm6CUvyhiqwQFfolmT+zfP80owCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTVGVzdCBBcHBBdHRlc3QgUm9vdDAeFw0yNjA2MDEwOTAyNDJaFw0zNjA1MjkwOTAyNDJaMB4xHDAaBgNVBAMME1Rlc3QgQXBwQXR0ZXN0IFJvb3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR9EV+jjb6Ns3kJQRGty4nVJQZjmMm6DUEoRIvdVUrluY1eioh6INcKzDHVvtdEZirf7FYHzmgrblJwA7fRiO6Yo1MwUTAdBgNVHQ4EFgQUd8RmCg3Ta7gGzx84hXjb/SNMDH4wHwYDVR0jBBgwFoAUd8RmCg3Ta7gGzx84hXjb/SNMDH4wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEA/Ao0l9+h2m03JN5EpculzBtbSMDZjGL5W+KxV1BLYgICIQDzxWDXoesDsWfP+cs7WNH4Frg0gUYt/eC76Rdx9ZqM0g=="
    private let intB64 = "MIIBkDCCATWgAwIBAgIUYzQ7RGaSpUv6rqsSibGgFbxJCqIwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTVGVzdCBBcHBBdHRlc3QgUm9vdDAeFw0yNjA2MDEwOTAyNDJaFw0zNjA1MjkwOTAyNDJaMBwxGjAYBgNVBAMMEVRlc3QgQXBwQXR0ZXN0IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjag86iR6F0UoiAEo5WNVS8gk7QMZNAzAIGAx+OqV30EjpKB9PrdQq6h1gquUaj4JMtjLS1cNEoGNuOxpO0gTNKNTMFEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUpfuejzbJ51OuIIQ1qOG8mF0dKHQwHwYDVR0jBBgwFoAUd8RmCg3Ta7gGzx84hXjb/SNMDH4wCgYIKoZIzj0EAwIDSQAwRgIhAJ4I7triJ1yk5UBABJ0LS2lwJaH+Hdkc8WjG+8P+2WHMAiEA1E+1InBilQoofFZ+3vWylm9Qy3wkwWVI6r3M4YMLuTE="
    private let leafB64 = "MIIBwzCCAWmgAwIBAgIUD0EVeBQaROnzn4NnaVQohFD5+UgwCgYIKoZIzj0EAwIwHDEaMBgGA1UEAwwRVGVzdCBBcHBBdHRlc3QgQ0EwHhcNMjYwNjAxMDkwMjQyWhcNMzYwNTI5MDkwMjQyWjAeMRwwGgYDVQQDDBNUZXN0IEFwcEF0dGVzdCBMZWFmMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwchfZNKKJ0UxqJNK67f5y0b9qk9c4P8Le3dedyMF1FTPWDoBMbbkoK40Q/8IYvdkleWB8ZhfsQFzDSYedX1DB6OBhjCBgzAMBgNVHRMBAf8EAjAAMDMGCSqGSIb3Y2QIAgQmMCShIgQgg9EEinfPaUJBs4772JT3Uw+XjAoihzLRB2UrbOTtXjIwHQYDVR0OBBYEFIlS0DYP0JUpyiOcw8I/6lZ2sY9QMB8GA1UdIwQYMBaAFKX7no82yedTriCENajhvJhdHSh0MAoGCCqGSM49BAMCA0gAMEUCIQCTDF7APO9NudDE/V5mD0y9bg6C5AH3XzqWl+hO4D5Z4wIgDQYKmWxKlQF2eyYDnahGbk2/tT1GYYRkekdTcrZT/PI="
    private let leafPrivHex = "a793b154ec073f73c9442f97b112244f9bc462708de2b3dcea8a83eba70bb617"
    private let authDataHex = "50eef061f0fa6568b7a50b7cf5ee2d33316dec50a145d354996c5a3a5997288b40000000000707070707070707070707070707070707070707"
    private let root2B64 = "MIIBfzCCASWgAwIBAgIUID26Z9GjA33lpC3ZrKy+1NbFW+QwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKT3RoZXIgUm9vdDAeFw0yNjA2MDEwOTAzMTJaFw0zNjA1MjkwOTAzMTJaMBUxEzARBgNVBAMMCk90aGVyIFJvb3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATD3luxdQX9oqlcLII97SQTouLm11KCVGsXX/BcZ1KI7Z91O1TwNwH9tIdhoii7qaqo1YJNbIAruxSpSbDu5Yq2o1MwUTAdBgNVHQ4EFgQUD29tmlhu0SulKZ32pdWmeotRJgUwHwYDVR0jBBgwFoAUD29tmlhu0SulKZ32pdWmeotRJgUwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA5MtFcXOFzsqNBKtLgiTp9Trpywn5lXI+tSIov3ZHtecCIHUrVHpgZPzBzeENR3/uxDnC80kOo2Ti1Wj4bVquDCni"

    // Expired-leaf chain: leaf valid 2020-01-01..2021-01-01 (expired now);
    // root + intermediate valid 2019..2035. Proves the verifier validates the
    // chain at the leaf's notBefore, so an expired attestation still passes.
    private let expRootB64 = "MIIBWjCCAQCgAwIBAgIUcYQgloqESpflxRiJtjs//OY6y4AwCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIRXhwIFJvb3QwHhcNMTkwMTAxMDAwMDAwWhcNMzUwMTAxMDAwMDAwWjATMREwDwYDVQQDDAhFeHAgUm9vdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMM6V4wx9jS+HoI89zDo//IkaBuzZMtgm2qEnTxfe/nJMnQWF3Oa4/Rd58fvtL3Qi7YtcZun2Y/U6HJMef240HKjMjAwMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFKOgHYpPDq16a2W9oBxvBSAePx/VMAoGCCqGSM49BAMCA0gAMEUCIBUcXJrBhUHgTkihYzXQf5b0LjQqEjsqCUALvANQbMF1AiEAnnBnT5mgGsszRGkIyqilAeJ9Csz0/d8JNbVwHug2NT0="
    private let expIntB64 = "MIIBeTCCAR+gAwIBAgIUM9vEAx5B7BS+adcx5Ai3KMGluRcwCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIRXhwIFJvb3QwHhcNMTkwMTAxMDAwMDAwWhcNMzUwMTAxMDAwMDAwWjARMQ8wDQYDVQQDDAZFeHAgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASysOVMN+UR37IOUpMbBSqY59gR1HbzWmhTNVElc2ASAvZlqmCn0LDGD7rrOE6UE98plIFXrY6A1DdhvSbPmEFQo1MwUTAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRDYumBf0JQLrs2VsSQM+hqB5791zAfBgNVHSMEGDAWgBSjoB2KTw6temtlvaAcbwUgHj8f1TAKBggqhkjOPQQDAgNIADBFAiAq9UY3qXl2ZolYI4wugIKkuGA9YjHOK4mZYZMmX5WayQIhAN+wLur/cbISKYKxd7a+xObNBhfOqXO2Lcg8s4+MAKFJ"
    private let expLeafB64 = "MIIBrTCCAVOgAwIBAgIUaFMzAaMKbD21g2tRrDR5Vi0plxAwCgYIKoZIzj0EAwIwETEPMA0GA1UEAwwGRXhwIENBMB4XDTIwMDEwMTAwMDAwMFoXDTIxMDEwMTAwMDAwMFowEzERMA8GA1UEAwwIRXhwIExlYWYwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARWVISlalu/mk2hidKY0Pe1blG8UYN7aIZ02MJ7cQOBhLR5LZRkF6LYCQ28TS9eRLMzdCKWXJXiVDN9VM2PE8Bwo4GGMIGDMAwGA1UdEwEB/wQCMAAwMwYJKoZIhvdjZAgCBCYwJKEiBCD+NXuBbuqHbDz3TQ34Jczu7rEjaTjAlLhlcMD13EOCEjAdBgNVHQ4EFgQUAvnA9IIY0SHQzJSRiQKgWR3BjawwHwYDVR0jBBgwFoAUQ2LpgX9CUC67NlbEkDPoagee/dcwCgYIKoZIzj0EAwIDSAAwRQIgW6ndTc7PzNzVKpKcUqsRyVasrHG2UEKSn0zw2CPDNwECIQCozYxkgl2WlICuAESl6glcbIioSULkUqRiDyQpqisq3A=="
    private let expLeafPrivHex = "6241ba01c74c8279397e54d98f5cb71465f36dbfbefc591d0e653b930c31fc8b"
    private let expAuthDataHex = "50eef061f0fa6568b7a50b7cf5ee2d33316dec50a145d354996c5a3a5997288b40000000000909090909090909090909090909090909090909"

    private func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    private func hexToData(_ h: String) -> Data {
        var out = [UInt8](); out.reserveCapacity(h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            out.append(UInt8(h[i..<j], radix: 16)!); i = j
        }
        return Data(out)
    }
    private func sec(_ b64: String) -> SecCertificate {
        SecCertificateCreateWithData(nil, Data(base64Encoded: b64)! as CFData)!
    }
    private func cbor(_ entries: [(String, CBORValue)]) throws -> Data {
        try CBOREncoder.encode(.map(entries.map { CBORMapEntry(key: .textString($0.0), value: $0.1) }))
    }

    /// Build a self-issuer attestation whose assertion binds to `binding`.
    /// Defaults to the valid (current-dated) fixture; pass explicit fixture
    /// material to build from a different chain (e.g. the expired one).
    private func makeAttestation(
        binding: Data,
        leafB64: String? = nil,
        intB64: String? = nil,
        authDataHex: String? = nil,
        leafPrivHex: String? = nil
    ) throws -> SelfIssuerAttestation {
        let leafB64 = leafB64 ?? self.leafB64
        let intB64 = intB64 ?? self.intB64
        let authDataHex = authDataHex ?? self.authDataHex
        let leafPrivHex = leafPrivHex ?? self.leafPrivHex
        let leafDER = Data(base64Encoded: leafB64)!
        let intDER = Data(base64Encoded: intB64)!
        let attestation = try cbor([
            ("fmt", .textString("apple-appattest")),
            ("attStmt", .map([
                CBORMapEntry(key: .textString("x5c"),
                             value: .array([.byteString(leafDER), .byteString(intDER)])),
                CBORMapEntry(key: .textString("receipt"), value: .byteString(Data())),
            ])),
            ("authData", .byteString(hexToData(authDataHex))),
        ])

        var assertAuthData = sha256(Data(appID.utf8))
        assertAuthData.append(0x00)
        assertAuthData.append(contentsOf: [0, 0, 0, 1])
        let clientDataHash = sha256(binding)
        let leafKey = try P256.Signing.PrivateKey(rawRepresentation: hexToData(leafPrivHex))
        let sig = try leafKey.signature(for: assertAuthData + clientDataHash).derRepresentation
        let assertion = try cbor([
            ("signature", .byteString(Data(sig))),
            ("authenticatorData", .byteString(assertAuthData)),
        ])

        return SelfIssuerAttestation(
            keyId: "test-key",
            attestation: attestation.base64EncodedString(),
            assertion: assertion.base64EncodedString(),
            bindingHashHex: "0x" + clientDataHash.map { String(format: "%02x", $0) }.joined()
        )
    }

    func testValidAttestationPasses() throws {
        let att = try makeAttestation(binding: bindingBytes)
        let r = AppAttestVerifier.verify(att, bindingBytes: bindingBytes, holderDID: holderDID,
                                         appID: appID, anchors: [sec(rootB64)])
        XCTAssertEqual(r, .pass)
    }

    func testExpiredAttestationStillVerifies() throws {
        // Leaf expired in 2021; this only passes because the verifier validates
        // the chain at the leaf's notBefore rather than "now".
        let att = try makeAttestation(
            binding: bindingBytes,
            leafB64: expLeafB64, intB64: expIntB64,
            authDataHex: expAuthDataHex, leafPrivHex: expLeafPrivHex
        )
        let r = AppAttestVerifier.verify(att, bindingBytes: bindingBytes, holderDID: holderDID,
                                         appID: appID, anchors: [sec(expRootB64)])
        XCTAssertEqual(r, .pass)
    }

    func testNotBeforeParsedFromLeaf() {
        // Existing (valid) leaf fixture was minted with notBefore 2026-06-01
        // 09:02:42 UTC.
        let der = Data(base64Encoded: leafB64)!
        let nb = AppAttestVerifier.notBefore(fromCertDER: der)
        XCTAssertNotNil(nb)
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 1; c.hour = 9; c.minute = 2; c.second = 42
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(nb, cal.date(from: c))

        // The expired leaf parses to 2020-01-01.
        let expNb = AppAttestVerifier.notBefore(fromCertDER: Data(base64Encoded: expLeafB64)!)
        var e = DateComponents(); e.year = 2020; e.month = 1; e.day = 1
        XCTAssertEqual(expNb, cal.date(from: e))
    }

    func testWrongHolderFailsNonce() throws {
        let att = try makeAttestation(binding: bindingBytes)
        let r = AppAttestVerifier.verify(att, bindingBytes: bindingBytes,
                                         holderDID: "did:elabify:sepolia:holder:0xdeadbeef",
                                         appID: appID, anchors: [sec(rootB64)])
        if case .fail = r {} else { XCTFail("expected fail for wrong holder, got \(r)") }
    }

    func testTamperedBindingFails() throws {
        let att = try makeAttestation(binding: bindingBytes)
        let r = AppAttestVerifier.verify(att, bindingBytes: Data("different".utf8),
                                         holderDID: holderDID, appID: appID, anchors: [sec(rootB64)])
        if case .fail = r {} else { XCTFail("expected fail for tampered binding, got \(r)") }
    }

    func testUntrustedRootFails() throws {
        let att = try makeAttestation(binding: bindingBytes)
        let r = AppAttestVerifier.verify(att, bindingBytes: bindingBytes, holderDID: holderDID,
                                         appID: appID, anchors: [sec(root2B64)])
        if case .fail = r {} else { XCTFail("expected fail for untrusted root, got \(r)") }
    }

    func testNonceScanReadsLeafExtension() {
        let n = AppAttestVerifier.nonce(fromCertDER: Data(base64Encoded: leafB64)!)
        XCTAssertEqual(n?.count, 32)
    }
}
