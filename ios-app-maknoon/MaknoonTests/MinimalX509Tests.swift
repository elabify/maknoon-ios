// Unit tests for the minimal X.509 DER reader that backs client-side HAVID
// (ADR-0051 / ADR-0054). iOS ships no swift-certificates, so HavidVerifier parses
// the issuer's leaf certificate with an in-repo DER walk; these tests pin the
// SAN-URI, validity-window, and subject-CN extraction against a real openssl
// certificate whose SAN carries a did:elabify URI.
//
// Fixture (throwaway self-signed, 2026-07-06, valid ~10y):
//   openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out cert.pem \
//     -subj "/CN=Test Issuer Org/O=Elabify" \
//     -addext "subjectAltName=URI:did:elabify:sepolia:issuer:testorg"

import XCTest
import CryptoKit
@testable import Maknoon

final class MinimalX509Tests: XCTestCase {

    private let testDid = "did:elabify:sepolia:issuer:testorg"

    // Base64 DER of the fixture certificate.
    private let certB64 = """
    MIIDajCCAlKgAwIBAgIUO4UqoBy4EZPEKAC+n9XaUPi4gQwwDQYJKoZIhvcNAQELBQAwLDEYMBYGA1UEAwwPVGVzdCBJc3N1ZXIgT3JnMRAwDgYDVQQKDAdFbGFiaWZ5MB4XDTI2MDcwNjA0MzM1MFoXDTM2MDcwMzA0MzM1MFowLDEYMBYGA1UEAwwPVGVzdCBJc3N1ZXIgT3JnMRAwDgYDVQQKDAdFbGFiaWZ5MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6kvtxrO9HnwhG50g5PTn8ctzdzpxO1AU4HWuvw3GpA1/kOINIq5dAVdVOI9gnXo4KKo0Aa1O00/ut4yFVSxz09Q6RoEXfFNbCt9uBf/c7vGxLE+J12CxaOOhMTMmVodqN6n8C6J+FzbO/YdcmCqKWlY/aXByHLLFf/oioPfzGG5t0OTnA4hdkT+CkUbViQcCT+h4xAgStqoNpUIALMW3UtkOynq66BKW5MZ1djA3xr0lJrxa50HdABR7piIAKNBULzTQXoKTtEd0JYog1e55z8u2v99LYQKWVWdP0dXhnJ12WnH3zBaCLnQdA7KdHWadVLvg1QdmaagJhFgTxy89ZQIDAQABo4GDMIGAMB0GA1UdDgQWBBRtTw/whOiNufg6HD14mxgdDqLEmDAfBgNVHSMEGDAWgBRtTw/whOiNufg6HD14mxgdDqLEmDAPBgNVHRMBAf8EBTADAQH/MC0GA1UdEQQmMCSGImRpZDplbGFiaWZ5OnNlcG9saWE6aXNzdWVyOnRlc3RvcmcwDQYJKoZIhvcNAQELBQADggEBAKQYWPYwv7aKSNcjmZT/sljYFeB1crmzGkMuvktBmydmdcz9iQt3MtLhsmwNhonJhjQ1dJrWkeG0/Ww1nyPFYhwiKl4CWIoQe2KIUI3K+70qBiPmLURoMXyw3kEiVLG98wCsCYR8jMuIotKrUm8r8bIjTRFPHpXShCIO+BzE9wq+w8jNcbSVoOrQMIXFVaaGxappnBYsh3lT11PBaKz5HEgqP9UQm64n0oatRJgBfMPuiQaq9W0P6Rgs3Y9WZ+1RROkaD1nsex6JQ3R7K6JRE6dqlvWFZEfL6XqdZt4FgNMZiEzAte7JY7jyD+Dr4BHbbTMKhdt2xWglzbBe/C5K+Sc=
    """

    private func der() throws -> Data {
        let b64 = certB64.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces)
        return try XCTUnwrap(Data(base64Encoded: b64))
    }

    func testExtractsSanUri() throws {
        let cert = try XCTUnwrap(MinimalX509(der: der()))
        XCTAssertTrue(cert.sanURIs.contains(testDid), "SAN URIs were \(cert.sanURIs)")
    }

    func testExtractsSubjectCommonName() throws {
        let cert = try XCTUnwrap(MinimalX509(der: der()))
        XCTAssertEqual(cert.subjectCN, "Test Issuer Org")
    }

    func testValidityWindowIsCurrent() throws {
        let cert = try XCTUnwrap(MinimalX509(der: der()))
        let (notBefore, notAfter) = try XCTUnwrap(cert.validity)
        let now = Date()
        XCTAssertLessThan(notBefore, now)
        XCTAssertGreaterThan(notAfter, now)
    }

    func testFingerprintMatchesOpenssl() throws {
        let fp = SHA256.hash(data: try der()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fp, "a650e310f3f276fc0db5702738846e1bbf220da1261a92077addd1cf8a8702cc")
    }

    func testGarbageDerRejectedOrEmpty() {
        // A non-certificate blob must not crash and must yield no SAN.
        let junk = Data([0x30, 0x03, 0x02, 0x01, 0x2A])
        let cert = MinimalX509(der: junk)
        XCTAssertTrue(cert?.sanURIs.isEmpty ?? true)
    }
}
