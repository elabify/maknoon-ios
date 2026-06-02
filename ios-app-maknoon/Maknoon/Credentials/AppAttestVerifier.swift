// Offline, peer-to-peer verification of an App Attest binding on a
// self-issued credential. Proves a genuine, unmodified Maknoon app instance
// (matching our App ID) on real Apple hardware minted the credential, so a
// verifying Maknoon client can distinguish an app-produced self credential
// from a QR fabricated outside the app.
//
// Procedure (Apple's App Attest validation, on the verifying device):
//   1. CBOR-decode the attestation object: fmt, attStmt{x5c, receipt}, authData.
//   2. Validate the x5c chain (leaf <- intermediate) to the App Attest root.
//   3. authData.rpIdHash == SHA256(appID).
//   4. The leaf's nonce extension (1.2.840.113635.100.8.2) ==
//      SHA256(authData || SHA256(holderDID)), binding the attested key to
//      this holder.
//   5. CBOR-decode the assertion; verify the leaf key signed
//      (assertion.authenticatorData || SHA256(bindingBytes)), where
//      bindingBytes are this credential's {cid, root, holderPk, schema}.
//
// Implementation note: this uses only the platform Security framework +
// CryptoKit + a tiny DER scan (no swift-certificates / swift-crypto, whose
// dynamic Crypto framework fails to build in this project's SPM setup).
// Chain validation is SecTrust against a configurable anchor (the bundled
// Apple root in production; a synthetic root in the unit test). The custom
// nonce extension, which iOS's Security framework cannot surface, is read
// by scanning the certificate DER for the extension OID.

import Foundation
import Security
import CryptoKit

enum AppAttestVerifyResult: Equatable {
    case pass
    case fail(String)
    case unavailable   // no attestation present (key-only self credential)
}

enum AppAttestVerifier {
    /// App Attest App ID = "<TeamID>.<bundleID>".
    static let appID = "PQ34VD5384.com.elabify.app.maknoon"

    /// DER of the App Attest nonce extension OID 1.2.840.113635.100.8.2
    /// (tag 0x06, length 0x09, then the 9 content bytes).
    private static let nonceOIDDER: [UInt8] =
        [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x08, 0x02]

    /// Apple's App Attest root, parsed from the bundled PEM. nil if missing.
    static func appleRoot() -> SecCertificate? {
        guard let url = Bundle.main.url(forResource: "AppAttestRootCA", withExtension: "pem"),
              let pem = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return certificate(fromPEM: pem)
    }

    static func verify(
        _ att: SelfIssuerAttestation,
        bindingBytes: Data,
        holderDID: String,
        appID: String = AppAttestVerifier.appID,
        anchors: [SecCertificate]? = nil
    ) -> AppAttestVerifyResult {
        let trustAnchors = anchors ?? appleRoot().map { [$0] } ?? []
        guard !trustAnchors.isEmpty else { return .fail("No App Attest trust root available") }
        guard let attData = Data(base64Encoded: att.attestation),
              let asrtData = Data(base64Encoded: att.assertion) else {
            return .fail("Attestation/assertion not base64")
        }

        // 0. The assertion binds to this exact credential (replay defence).
        let clientDataHash = Data(SHA256.hash(data: bindingBytes))
        let cdhHex = clientDataHash.map { String(format: "%02x", $0) }.joined()
        let carried = att.bindingHashHex.hasPrefix("0x")
            ? String(att.bindingHashHex.dropFirst(2)) : att.bindingHashHex
        guard carried.lowercased() == cdhHex else {
            return .fail("Assertion binding does not match this credential")
        }

        // 1. Attestation object.
        guard let obj = try? CBORDecoder.decode(attData),
              case .map(let top) = obj,
              top.textValue("fmt") == "apple-appattest",
              case .map(let attStmt)? = top.value("attStmt"),
              case .array(let x5c)? = attStmt.value("x5c"),
              case .byteString(let authData)? = top.value("authData")
        else { return .fail("Malformed attestation object") }

        let certDERs: [Data] = x5c.compactMap { if case .byteString(let d) = $0 { return d }; return nil }
        guard certDERs.count >= 2,
              let leaf = SecCertificateCreateWithData(nil, certDERs[0] as CFData),
              let intermediate = SecCertificateCreateWithData(nil, certDERs[1] as CFData)
        else { return .fail("Attestation certificate chain missing or unparseable") }

        // 2. Chain to the trust anchor (SecTrust, anchors-only).
        guard chainIsTrusted(leafDER: certDERs[0], leaf: leaf,
                             intermediate: intermediate, anchors: trustAnchors) else {
            return .fail("Attestation chain did not validate to the App Attest root")
        }

        // 3. App ID.
        let appIdHash = Data(SHA256.hash(data: Data(appID.utf8)))
        guard authData.count >= 37, Data(authData.prefix(32)) == appIdHash else {
            return .fail("Attestation App ID mismatch")
        }

        // 4. Nonce binds the attested key to this holder.
        let enrollChallengeHash = Data(SHA256.hash(data: Data(holderDID.utf8)))
        let expectedNonce = Data(SHA256.hash(data: authData + enrollChallengeHash))
        guard let certNonce = nonce(fromCertDER: certDERs[0]), certNonce == expectedNonce else {
            return .fail("Attestation nonce not bound to this holder")
        }

        // 5. Assertion signature over (authenticatorData || clientDataHash).
        guard let asrt = try? CBORDecoder.decode(asrtData),
              case .map(let am) = asrt,
              case .byteString(let sig)? = am.value("signature"),
              case .byteString(let assertAuthData)? = am.value("authenticatorData")
        else { return .fail("Malformed assertion") }
        guard assertAuthData.count >= 37, Data(assertAuthData.prefix(32)) == appIdHash else {
            return .fail("Assertion App ID mismatch")
        }
        guard let key = SecCertificateCopyKey(leaf) else {
            return .fail("Could not extract attestation public key")
        }
        let signedMessage = assertAuthData + clientDataHash
        var secErr: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(
            key, .ecdsaSignatureMessageX962SHA256,
            signedMessage as CFData, sig as CFData, &secErr
        )
        return ok ? .pass : .fail("Assertion signature did not verify")
    }

    // MARK: -- helpers

    private static func chainIsTrusted(
        leafDER: Data, leaf: SecCertificate, intermediate: SecCertificate, anchors: [SecCertificate]
    ) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates([leaf, intermediate] as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        // Validate as of the leaf's notBefore, not "now": we are proving the
        // attestation's authenticity (it was valid when the credential was
        // minted), not its freshness. App Attest leaf certs are short-lived,
        // so a credential presented weeks later must not fail merely because
        // the attestation cert has since expired. Falls back to the current
        // date if notBefore can't be parsed (no regression vs. before).
        if let nb = notBefore(fromCertDER: leafDER) {
            SecTrustSetVerifyDate(trust, nb as CFDate)
        }
        var err: CFError?
        return SecTrustEvaluateWithError(trust, &err)
    }

    /// The leaf certificate's notBefore, parsed by walking the DER to the
    /// TBSCertificate validity field. iOS's Security framework does not expose
    /// certificate dates, so we read it directly.
    /// Path: Certificate -> tbsCertificate -> {[version], serial, signature,
    /// issuer, validity -> notBefore}.
    static func notBefore(fromCertDER der: Data) -> Date? {
        let b = [UInt8](der)
        guard let cert = readTLV(b, 0), cert.tag == 0x30,
              let tbs = readTLV(b, cert.valueStart), tbs.tag == 0x30 else { return nil }
        var i = tbs.valueStart
        guard var node = readTLV(b, i) else { return nil }
        if node.tag == 0xA0 {                       // skip optional version [0]
            i = node.next
            guard let n = readTLV(b, i) else { return nil }
            node = n
        }
        // node == serialNumber; step past signature + issuer to validity.
        i = node.next
        guard let sigAlg = readTLV(b, i) else { return nil }
        i = sigAlg.next
        guard let issuer = readTLV(b, i) else { return nil }
        i = issuer.next
        guard let validity = readTLV(b, i), validity.tag == 0x30,
              let nb = readTLV(b, validity.valueStart) else { return nil }
        let bytes = Array(b[nb.valueStart..<nb.valueEnd])
        return parseASN1Time(tag: nb.tag, bytes: bytes)
    }

    private struct DERNode { let tag: UInt8; let valueStart: Int; let valueEnd: Int; let next: Int }

    private static func readTLV(_ b: [UInt8], _ i: Int) -> DERNode? {
        guard i >= 0, i + 1 < b.count else { return nil }
        let tag = b[i]
        var j = i + 1
        let first = b[j]; j += 1
        var len = 0
        if first & 0x80 == 0 {
            len = Int(first)
        } else {
            let n = Int(first & 0x7f)
            guard n >= 1, n <= 4, j + n <= b.count else { return nil }
            for _ in 0..<n { len = (len << 8) | Int(b[j]); j += 1 }
        }
        let end = j + len
        guard end <= b.count else { return nil }
        return DERNode(tag: tag, valueStart: j, valueEnd: end, next: end)
    }

    private static func parseASN1Time(tag: UInt8, bytes: [UInt8]) -> Date? {
        guard let s = String(bytes: bytes, encoding: .ascii) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        switch tag {
        case 0x17: fmt.dateFormat = "yyMMddHHmmss'Z'"     // UTCTime
        case 0x18: fmt.dateFormat = "yyyyMMddHHmmss'Z'"   // GeneralizedTime
        default: return nil
        }
        return fmt.date(from: s)
    }

    /// 32-byte nonce from the App Attest extension by scanning the cert DER
    /// for the extension OID and then the inner OCTET STRING (04 20 <32>).
    static func nonce(fromCertDER der: Data) -> Data? {
        let b = [UInt8](der)
        guard let oidEnd = indexAfterSubsequence(nonceOIDDER, in: b) else { return nil }
        var i = oidEnd
        while i + 1 < b.count {
            if b[i] == 0x04, b[i + 1] == 0x20, i + 2 + 32 <= b.count {
                return Data(b[(i + 2)..<(i + 2 + 32)])
            }
            i += 1
        }
        return nil
    }

    /// Index just past the first occurrence of `needle` in `haystack`.
    private static func indexAfterSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var match = true
            for j in 0..<needle.count where haystack[start + j] != needle[j] { match = false; break }
            if match { return start + needle.count }
        }
        return nil
    }

    static func certificate(fromPEM pem: String) -> SecCertificate? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

private extension Array where Element == CBORMapEntry {
    func value(_ key: String) -> CBORValue? {
        first { if case .textString(let k) = $0.key { return k == key }; return false }?.value
    }
    func textValue(_ key: String) -> String? {
        if case .textString(let s)? = value(key) { return s }
        return nil
    }
}
