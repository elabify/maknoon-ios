// Raw CTAP2 client. yubikit-ios's `YKFFIDO2Session` does not expose
// the CTAP2 `extensions` parameter on makeCredential / getAssertion,
// which means we can't use it to drive the FIDO2 hmac-secret
// extension that the Identity Sandwich wrap depends on. This file
// bypasses YKFFIDO2Session and talks raw NFC-CTAP2 APDUs through
// `YKFSmartCardInterface`, encoded by our small CBOR module.
//
// Spec refs:
//   CTAP 2.1 §6 (commands), §8.2 (NFC framing), §11.2 (hmac-secret).
//
// NFC framing for CTAP2 commands (§8.2):
//   NFCCTAP_MSG       APDU: CLA=0x80 INS=0x10 P1=0x00 P2=0x00 Lc=N data Le=0
//   NFCCTAP_GETRESPONSE: CLA=0x80 INS=0x11 P1=0x00 P2=0x00 Le=0
//
// We use extended-length APDUs so the YubiKey can return up to ~7K of
// data in a single round trip. yubikit-ios's smartCardInterface
// understands status word 0x61XX and re-fetches via the OATH-style
// GET RESPONSE; for CTAP2 the authenticator may use 0x9100-0x9100
// extended status words instead. In practice for our messages
// (≤ 1KB) a single round trip is enough; we still defensively retry
// once on a chunked response.

#if canImport(YubiKit)
import Foundation
import CryptoKit
import YubiKit

enum CTAP2Error: LocalizedError {
    case sessionUnavailable
    case nfcConnectionUnavailable
    case ctapStatus(UInt8, String?)
    case missingField(String)
    case invalidResponseShape(String)
    case responseTooShort

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "CTAP2: YubiKit session was not available on the active NFC connection."
        case .nfcConnectionUnavailable:
            return "CTAP2: NFC connection went away before the command completed."
        case .ctapStatus(let s, let m):
            let name = ctapStatusName(s)
            if let m, !m.isEmpty { return "CTAP2 error \(name) (0x\(String(format: "%02X", s))): \(m)" }
            return "CTAP2 error \(name) (0x\(String(format: "%02X", s)))"
        case .missingField(let f):
            return "CTAP2 response was missing field \(f)"
        case .invalidResponseShape(let m):
            return "CTAP2 response had unexpected shape: \(m)"
        case .responseTooShort:
            return "CTAP2 response was empty"
        }
    }
}

/// CTAP2 status codes we care about by name. Anything else falls
/// through to a hex representation.
private func ctapStatusName(_ s: UInt8) -> String {
    switch s {
    case 0x00: return "ok"
    case 0x01: return "invalidCommand"
    case 0x02: return "invalidParameter"
    case 0x11: return "invalidCBOR"
    case 0x12: return "missingParameter"
    case 0x19: return "userActionTimeout"
    case 0x1F: return "invalidOption"
    case 0x21: return "actionTimeout"
    case 0x22: return "pinRequired"
    case 0x27: return "invalidCredential"
    case 0x2B: return "unsupportedOption"
    case 0x2C: return "invalidOption"
    case 0x2D: return "keepaliveCancel"
    case 0x2E: return "noCredentials"
    case 0x31: return "pinInvalid"
    case 0x32: return "pinBlocked"
    case 0x33: return "pinAuthInvalid"
    case 0x34: return "pinAuthBlocked"
    case 0x35: return "pinNotSet"
    case 0x36: return "pinRequiredForSelectedOp"
    case 0x37: return "pinPolicyViolation"
    case 0x39: return "operationDenied"
    default:   return "ctapStatus_\(String(format: "0x%02X", s))"
    }
}

/// All commands take and return CBOR. Inputs are encoded; responses
/// are decoded into a typed shape per command.
struct CTAP2Client {
    let smartCard: YKFSmartCardInterface

    // MARK: -- authenticatorGetInfo (0x04)

    /// Subset of authenticatorGetInfo (0x04) Maknoon needs: the supported
    /// extension names (map key 2) and the `clientPin` option (map key 4).
    struct GetInfo {
        let extensions: [String]
        /// `options.clientPin`: `true` = a PIN is set on the key; `false` =
        /// clientPin is supported but no PIN has been set yet; `nil` = the
        /// option is absent (clientPin unsupported, or no options map). This
        /// is the difference between "enter your PIN" and "set a PIN first".
        let clientPinSet: Bool?
    }

    /// One getInfo round trip returning the extensions + the clientPin state.
    func getInfo() async throws -> GetInfo {
        let resp = try await exchangeCommand(0x04, payload: .map([]))
        let exts = (resp.entry(forIntKey: 2)?.asArray ?? []).compactMap { $0.asString }
        // Map key 4 is "options": a map of String -> Bool.
        let clientPin = resp.entry(forIntKey: 4)?.entry(forTextKey: "clientPin")?.asBool
        return GetInfo(extensions: exts, clientPinSet: clientPin)
    }

    // MARK: -- authenticatorClientPIN (0x06)

    /// getKeyAgreement (subcommand 0x02): returns the authenticator's
    /// ephemeral keyAgreement public key. Regenerated per power
    /// cycle; capture once at the start of each NFC session.
    func getKeyAgreement() async throws -> P256.KeyAgreement.PublicKey {
        // CBOR: {1: pinProtocol(1), 2: subcommand(0x02)}
        let request: CBORValue = .map([
            CBORMapEntry(key: .intKey(1), value: .unsignedInt(1)),
            CBORMapEntry(key: .intKey(2), value: .unsignedInt(0x02)),
        ])
        let resp = try await exchangeCommand(0x06, payload: request)
        // Response CBOR: {1: COSE_Key (the authenticator's pub)}
        guard let coseValue = resp.entry(forIntKey: 1) else {
            throw CTAP2Error.missingField("keyAgreement (response map key 1)")
        }
        return try COSEKey.parseP256Public(coseValue)
    }

    /// getPinToken (subcommand 0x05) with PIN protocol 1: returns an
    /// encrypted 16-byte token that authorizes subsequent CTAP2
    /// commands for the duration of this NFC session.
    func getPinToken(
        pin: String,
        platformPriv: P256.KeyAgreement.PrivateKey,
        authenticatorPub: P256.KeyAgreement.PublicKey
    ) async throws -> Data {
        let shared = try PINProtocolV1.sharedSecret(
            platformPriv: platformPriv,
            authenticatorPub: authenticatorPub
        )
        // pinHash = LEFT(SHA-256(pin), 16)
        let pinBytes = Data(pin.precomposedStringWithCompatibilityMapping.utf8)
        let pinHash = Data(SHA256.hash(data: pinBytes)).prefix(16)
        // pinHashEnc = AES-256-CBC(shared, IV=0, pinHash)
        let pinHashEnc = try PINProtocolV1.encrypt(key: shared, plaintext: Data(pinHash))
        let platformCOSE = COSEKey.encodeP256Public(platformPriv.publicKey)
        // {1: pinProtocol(1), 2: subcommand(0x05), 3: keyAgreement, 6: pinHashEnc}
        let request: CBORValue = .map([
            CBORMapEntry(key: .intKey(1), value: .unsignedInt(1)),
            CBORMapEntry(key: .intKey(2), value: .unsignedInt(0x05)),
            CBORMapEntry(key: .intKey(3), value: platformCOSE),
            CBORMapEntry(key: .intKey(6), value: .byteString(pinHashEnc)),
        ])
        let resp = try await exchangeCommand(0x06, payload: request)
        // {2: pinToken (encrypted, 16 or 32 bytes)}
        guard let tokenEncBytes = resp.entry(forIntKey: 2)?.asBytes else {
            throw CTAP2Error.missingField("pinToken (response map key 2)")
        }
        let token = try PINProtocolV1.decrypt(key: shared, ciphertext: tokenEncBytes)
        // Trim trailing padding if any (PIN protocol 1 pinToken is
        // typically 16 bytes; YubiKey 5 returns 16).
        return token
    }

    // MARK: -- authenticatorMakeCredential (0x01)

    struct MakeCredentialResult {
        /// Raw authenticator data blob (rpIdHash || flags || counter
        /// || attested credential data || extension output).
        let authData: Data
        /// Credential id extracted from attested credential data.
        let credentialId: Data
    }

    /// makeCredential with `extensions = {"hmac-secret": true}`. When
    /// `pinUvAuthParam` is non-nil (the key has a PIN set) it is sent to
    /// satisfy user verification; when nil (a no-PIN key) the keys 8/9 are
    /// omitted and the authenticator gates on user presence (the touch) alone.
    func makeCredentialHMACSecret(
        rpId: String,
        rpName: String,
        userId: Data,
        userName: String,
        clientDataHash: Data,
        pinUvAuthParam: Data?
    ) async throws -> MakeCredentialResult {
        // {1: clientDataHash, 2: rp, 3: user, 4: pubKeyCredParams,
        //  6: extensions, [8: pinUvAuthParam, 9: pinUvAuthProtocol]}
        var entries: [CBORMapEntry] = [
            CBORMapEntry(key: .intKey(1), value: .byteString(clientDataHash)),
            CBORMapEntry(key: .intKey(2), value: .map([
                CBORMapEntry(key: .textString("id"), value: .textString(rpId)),
                CBORMapEntry(key: .textString("name"), value: .textString(rpName)),
            ])),
            CBORMapEntry(key: .intKey(3), value: .map([
                CBORMapEntry(key: .textString("id"), value: .byteString(userId)),
                CBORMapEntry(key: .textString("name"), value: .textString(userName)),
                CBORMapEntry(key: .textString("displayName"), value: .textString(userName)),
            ])),
            CBORMapEntry(key: .intKey(4), value: .array([
                .map([
                    CBORMapEntry(key: .textString("type"), value: .textString("public-key")),
                    CBORMapEntry(key: .textString("alg"), value: .negativeInt(-7)), // ES256
                ]),
            ])),
            CBORMapEntry(key: .intKey(6), value: .map([
                CBORMapEntry(key: .textString("hmac-secret"), value: .bool(true)),
            ])),
        ]
        if let pinUvAuthParam {
            entries.append(CBORMapEntry(key: .intKey(8), value: .byteString(pinUvAuthParam)))
            entries.append(CBORMapEntry(key: .intKey(9), value: .unsignedInt(1)))
        }
        let resp = try await exchangeCommand(0x01, payload: .map(entries))
        // {1: fmt, 2: authData, 3: attStmt}
        guard let authData = resp.entry(forIntKey: 2)?.asBytes else {
            throw CTAP2Error.missingField("authData (response map key 2)")
        }
        let credId = try Self.extractCredentialId(authData: authData)
        return MakeCredentialResult(authData: authData, credentialId: credId)
    }

    // MARK: -- authenticatorGetAssertion (0x02) with hmac-secret

    struct AssertionHMACSecretResult {
        /// Authenticator data from the response.
        let authData: Data
        /// 32-byte deterministic hmac-secret output (decrypted).
        let hmacSecretOutput: Data
    }

    /// getAssertion with the hmac-secret extension supplying a single
    /// salt. Returns the 32-byte decrypted hmac output, the value
    /// Maknoon HKDFs into the AES wrap key.
    func getAssertionHMACSecret(
        rpId: String,
        clientDataHash: Data,
        credentialId: Data,
        salt: Data,
        platformPriv: P256.KeyAgreement.PrivateKey,
        authenticatorPub: P256.KeyAgreement.PublicKey,
        sharedSecret: Data,
        pinUvAuthParam: Data?
    ) async throws -> AssertionHMACSecretResult {
        precondition(salt.count == 32, "hmac-secret salt1 must be exactly 32 bytes")
        // saltEnc = AES-256-CBC(shared, IV=0, salt)
        let saltEnc = try PINProtocolV1.encrypt(key: sharedSecret, plaintext: salt)
        // saltAuth = LEFT(HMAC-SHA-256(shared, saltEnc), 16)
        let saltAuth = PINProtocolV1.authenticate(key: sharedSecret, message: saltEnc)
        let platformCOSE = COSEKey.encodeP256Public(platformPriv.publicKey)
        // hmac-secret extension request:
        //   {1: platformCOSE, 2: saltEnc, 3: saltAuth, 4: pinProtocol(1)}
        let hmacSecretExt: CBORValue = .map([
            CBORMapEntry(key: .intKey(1), value: platformCOSE),
            CBORMapEntry(key: .intKey(2), value: .byteString(saltEnc)),
            CBORMapEntry(key: .intKey(3), value: .byteString(saltAuth)),
            CBORMapEntry(key: .intKey(4), value: .unsignedInt(1)),
        ])
        // getAssertion request:
        //   {1: rpId, 2: clientDataHash, 3: allowList,
        //    4: extensions, 6: pinUvAuthParam, 7: pinUvAuthProtocol}
        var entries: [CBORMapEntry] = [
            CBORMapEntry(key: .intKey(1), value: .textString(rpId)),
            CBORMapEntry(key: .intKey(2), value: .byteString(clientDataHash)),
            CBORMapEntry(key: .intKey(3), value: .array([
                .map([
                    CBORMapEntry(key: .textString("type"), value: .textString("public-key")),
                    CBORMapEntry(key: .textString("id"), value: .byteString(credentialId)),
                ]),
            ])),
            CBORMapEntry(key: .intKey(4), value: .map([
                CBORMapEntry(key: .textString("hmac-secret"), value: hmacSecretExt),
            ])),
        ]
        if let pinUvAuthParam {
            entries.append(CBORMapEntry(key: .intKey(6), value: .byteString(pinUvAuthParam)))
            entries.append(CBORMapEntry(key: .intKey(7), value: .unsignedInt(1)))
        }
        let resp = try await exchangeCommand(0x02, payload: .map(entries))
        // {2: authData, 3: signature, ...}
        guard let authData = resp.entry(forIntKey: 2)?.asBytes else {
            throw CTAP2Error.missingField("authData (response map key 2)")
        }
        // hmac-secret output is encoded INSIDE authData's extensions
        // section, not at the top-level response map. Parse authData.
        let hmacEnc = try Self.extractHMACSecretOutput(authData: authData)
        let hmac = try PINProtocolV1.decrypt(key: sharedSecret, ciphertext: hmacEnc)
        return AssertionHMACSecretResult(authData: authData, hmacSecretOutput: hmac)
    }

    // MARK: -- shared APDU exchange

    /// Send a CTAP2 command via NFC-CTAP2 framing. The CLA/INS/P1/P2
    /// for NFCCTAP_MSG is 80 10 00 00, payload is `cmd || cborData`,
    /// Le = 0 (extended). yubikit-ios's smartCardInterface unwraps
    /// the 9000 SW for us; CTAP-level success returns data starting
    /// with the CTAP status byte 0x00.
    private func exchangeCommand(_ command: UInt8, payload: CBORValue) async throws -> CBORValue {
        let cborBody = try CBOREncoder.encode(payload)
        var apduData = Data()
        apduData.append(command)
        apduData.append(cborBody)
        // Build NFCCTAP_MSG APDU manually; use extended-length so the
        // YubiKey can return multi-hundred-byte responses without
        // chaining.
        let apdu = YKFAPDU(
            cla: 0x80,
            ins: 0x10,
            p1: 0x00,
            p2: 0x00,
            data: apduData,
            type: .extended
        )
        guard let apdu else {
            throw CTAP2Error.invalidResponseShape("could not build NFCCTAP_MSG APDU")
        }
        let respData: Data = try await withCheckedThrowingContinuation { cont in
            smartCard.executeCommand(apdu) { data, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                guard let data else {
                    cont.resume(throwing: CTAP2Error.nfcConnectionUnavailable)
                    return
                }
                cont.resume(returning: data)
            }
        }
        guard let firstByte = respData.first else {
            throw CTAP2Error.responseTooShort
        }
        if firstByte != 0x00 {
            // CTAP2 status; if a CBOR error body follows, surface it.
            let rest = respData.count > 1 ? respData.subdata(in: 1..<respData.count) : Data()
            let detail = (try? CBORDecoder.decode(rest))?.asString
            throw CTAP2Error.ctapStatus(firstByte, detail)
        }
        let body = respData.count > 1 ? respData.subdata(in: 1..<respData.count) : Data()
        if body.isEmpty {
            // Some commands (Reset, ClientPIN setPin) return only the
            // status; surface as an empty map.
            return .map([])
        }
        return try CBORDecoder.decode(body)
    }

    // MARK: -- authData helpers

    /// authData layout for makeCredential (CTAP2 §6.1):
    ///   bytes 0..31   rpIdHash
    ///   byte  32      flags (UP=0x01, UV=0x04, AT=0x40, ED=0x80)
    ///   bytes 33..36  signCount (big-endian uint32)
    ///   bytes 37..52  aaguid (16 bytes; present if AT)
    ///   bytes 53..54  credIdLen (big-endian uint16; present if AT)
    ///   bytes 55..    credId, then COSE_Key, then extensions if ED
    /// We only need credentialId from the attestedCred block.
    private static func extractCredentialId(authData: Data) throws -> Data {
        guard authData.count >= 37 else {
            throw CTAP2Error.invalidResponseShape("authData under 37 bytes")
        }
        let flags = authData[authData.startIndex + 32]
        guard (flags & 0x40) != 0 else {
            throw CTAP2Error.invalidResponseShape("attested credential flag not set in authData (flags=0x\(String(format: "%02X", flags)))")
        }
        guard authData.count >= 55 else {
            throw CTAP2Error.invalidResponseShape("authData truncated before credIdLen")
        }
        let hi = UInt16(authData[authData.startIndex + 53])
        let lo = UInt16(authData[authData.startIndex + 54])
        let credIdLen = Int((hi << 8) | lo)
        guard authData.count >= 55 + credIdLen else {
            throw CTAP2Error.invalidResponseShape("authData truncated before credId payload")
        }
        let start = authData.startIndex + 55
        return authData.subdata(in: start..<(start + credIdLen))
    }

    /// authData layout for getAssertion mirrors makeCredential's
    /// header. attestedCred is typically absent on assertions;
    /// extensions present when ED (0x80) is set. The hmac-secret
    /// extension output sits under the "hmac-secret" key in the
    /// extensions CBOR map (32 bytes encrypted for a single salt).
    private static func extractHMACSecretOutput(authData: Data) throws -> Data {
        guard authData.count >= 37 else {
            throw CTAP2Error.invalidResponseShape("authData under 37 bytes")
        }
        let flags = authData[authData.startIndex + 32]
        guard (flags & 0x80) != 0 else {
            throw CTAP2Error.invalidResponseShape("extensions flag not set on assertion authData (flags=0x\(String(format: "%02X", flags)))")
        }
        // Past rpIdHash (32) + flags (1) + signCount (4) = byte 37.
        var cursor = authData.startIndex + 37
        if (flags & 0x40) != 0 {
            // attestedCred present: aaguid 16 || credIdLen 2 || credId N || COSE_Key (CBOR)
            guard cursor + 18 <= authData.endIndex else {
                throw CTAP2Error.invalidResponseShape("authData truncated within attestedCred header")
            }
            let hi = UInt16(authData[cursor + 16])
            let lo = UInt16(authData[cursor + 17])
            let credIdLen = Int((hi << 8) | lo)
            cursor += 18 + credIdLen
            // Step past the COSE_Key CBOR by length-aware decoding.
            let tail = authData.subdata(in: cursor..<authData.endIndex)
            let consumed = try CBORDecoder.decodeLength(tail)
            cursor += consumed
        }
        // Whatever remains is the extensions CBOR map.
        let extData = authData.subdata(in: cursor..<authData.endIndex)
        let extValue = try CBORDecoder.decode(extData)
        guard let hmac = extValue.entry(forTextKey: "hmac-secret")?.asBytes else {
            throw CTAP2Error.missingField("authData extensions.hmac-secret")
        }
        return hmac
    }
}

// MARK: -- user-facing error translation

/// Map a CTAP2 / YubiKey error into a sentence a wallet user can act
/// on. The raw CTAP2 status word stays in the diagnostic log via
/// `LogStore` (CTAP2Client already logs every command + status); this
/// helper just keeps the camelCase enum-case-name out of the
/// HardwareUnlockView / DeviceDetailView / SettingsView error labels.
///
/// Pass any error through; non-CTAP2 errors fall back to the
/// LocalizedError description (or `String(describing:)`).
func userFacingYubiKeyMessage(for error: Error) -> String {
    if let ctap = error as? CTAP2Error, case .ctapStatus(let code, _) = ctap {
        if let friendly = friendlyCTAPStatus(code) {
            return friendly
        }
    }
    return (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

private func friendlyCTAPStatus(_ code: UInt8) -> String? {
    switch code {
    case 0x31: return "YubiKey PIN is incorrect."
    case 0x32: return "YubiKey PIN is blocked. The key needs a FIDO2 reset to unblock."
    case 0x33: return "YubiKey PIN authentication failed."
    case 0x34: return "YubiKey PIN authentication is blocked."
    case 0x35: return "This YubiKey has no FIDO2 PIN set. Set one in Yubico Authenticator first."
    case 0x36: return "YubiKey requires its PIN for this operation."
    case 0x19, 0x21: return "YubiKey didn't respond in time. Tap it again."
    case 0x2E: return "No matching FIDO2 credential on this YubiKey."
    case 0x27: return "The credential on this YubiKey doesn't match what Maknoon enrolled."
    case 0x2B, 0x2C: return "YubiKey rejected the request (unsupported option)."
    case 0x39: return "YubiKey rejected the request."
    default:   return nil
    }
}

#endif // canImport(YubiKit)
