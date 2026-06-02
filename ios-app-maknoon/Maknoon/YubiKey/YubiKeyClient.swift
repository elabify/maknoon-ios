// YubiKey client.
//
// NFC is the primary transport for everything: serial read, FIDO2
// enrollment, FIDO2 unlock. The user taps a YubiKey 5 series (5 NFC,
// 5C NFC, 5Ci, etc.) to the top of the iPhone. iOS shows its native
// "Hold your iPhone near the NFC tag" sheet, yubikit-ios opens
// either the Management application (for serial read) or a FIDO2
// session (for wrap derivation).
//
// USB-C is a fallback for serial read on devices without NFC, or
// when the user prefers it. FIDO2 isn't reachable over USB-C on
// iOS, so the Identity Sandwich wrap (enroll + unlock) is always
// NFC-only.
//
// Wrap derivation uses FIDO2 deterministic ECDSA: YubiKey 5+
// signatures are byte-identical for the same (private key, message
// hash) per RFC 6979. We bake the wrap salt into the clientDataHash
// so each wrap blob has a unique signature, then HKDF that
// signature into an AES-GCM key. Same shape as the Ledger
// personal_sign path; no FIDO2 extensions required.

import Foundation
import CryptoKit
import UIKit
#if canImport(YubiKit)
import YubiKit
#endif

@MainActor
final class YubiKeyClient {
    static let shared = YubiKeyClient()

    enum Error: LocalizedError {
        case sdkUnavailable
        case noConnection
        case timeout
        case userCanceled
        case session(String)
        case fido2(String)
        case missingSignature
        case nfcRequired

        var errorDescription: String? {
            switch self {
            case .sdkUnavailable:
                return "YubiKey SDK is not linked in this build."
            case .noConnection:
                return "Tap your YubiKey to the top of the iPhone and try again."
            case .timeout:
                return "YubiKey tap timed out. Tap again and hold the key steady against the top of the phone."
            case .userCanceled:
                return "Canceled."
            case .session(let s):
                return s
            case .fido2(let s):
                return "FIDO2 error: \(s)"
            case .missingSignature:
                return "The YubiKey didn't return a signature."
            case .nfcRequired:
                return "Adding a YubiKey to the Identity Sandwich needs an NFC tap. USB-C is supported for reading the device serial, but FIDO2 isn't reachable over USB-C on iPhone."
            }
        }
    }

    #if canImport(YubiKit)
    private let observer = ConnectionObserver()
    #endif

    private init() {
        #if canImport(YubiKit)
        YubiKitManager.shared.delegate = observer
        #endif
    }

    // MARK: -- Public API

    /// Cancel any in-flight YubiKey operation.
    func cancel() {
        #if canImport(YubiKit)
        observer.fireCancellation()
        YubiKitManager.shared.stopNFCConnection()
        YubiKitManager.shared.stopSmartCardConnection()
        #endif
    }

    /// Read the YubiKey serial via NFC. Used at registration time
    /// as the primary path: iOS shows its native NFC sheet, the
    /// user taps the YubiKey to the top of the phone, we open the
    /// Management application and read DeviceInfo.
    func identifySerialOverNFC() async throws -> String {
        #if canImport(YubiKit) && MAKNOON_NFC
        LogStore.shared.info("YubiKey", "identifySerialOverNFC: starting NFC session")
        defer { observer.clearAllPendingState() }
        let connection = try await waitForNFCConnection(prompt: "Tap your YubiKey to read its serial")
        defer {
            LogStore.shared.info("YubiKey", "identifySerialOverNFC: stopping NFC session")
            YubiKitManager.shared.stopNFCConnection()
        }
        LogStore.shared.info("YubiKey", "identifySerialOverNFC: NFC connected, opening management session")
        let serial: UInt = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt, Swift.Error>) in
            connection.managementSession { session, err in
                if let err {
                    LogStore.shared.error("YubiKey", "identifySerialOverNFC: management session error \(err.localizedDescription)")
                    cont.resume(throwing: Error.session(err.localizedDescription)); return
                }
                guard let session else {
                    LogStore.shared.error("YubiKey", "identifySerialOverNFC: management session was nil")
                    cont.resume(throwing: Error.noConnection); return
                }
                session.getDeviceInfo { info, err in
                    if let err {
                        LogStore.shared.error("YubiKey", "identifySerialOverNFC: getDeviceInfo error \(err.localizedDescription)")
                        cont.resume(throwing: Error.session(err.localizedDescription)); return
                    }
                    cont.resume(returning: info?.serialNumber ?? 0)
                }
            }
        }
        LogStore.shared.info("YubiKey", "identifySerialOverNFC: read serial \(serial)")
        return "\(serial)"
        #else
        throw Error.nfcRequired
        #endif
    }

    /// Read the YubiKey serial via the smart-card / USB-C transport.
    /// Fallback for devices without NFC, or when the user prefers
    /// the wired path.
    func identifySerial() async throws -> String {
        #if canImport(YubiKit)
        LogStore.shared.info("YubiKey", "identifySerial: starting smart-card (USB-C) session")
        let connection = try await waitForSmartCardConnection()
        defer { YubiKitManager.shared.stopSmartCardConnection() }
        let serial: UInt = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt, Swift.Error>) in
            connection.managementSession { session, err in
                if let err { cont.resume(throwing: Error.session(err.localizedDescription)); return }
                guard let session else { cont.resume(throwing: Error.noConnection); return }
                session.getDeviceInfo { info, err in
                    if let err { cont.resume(throwing: Error.session(err.localizedDescription)); return }
                    cont.resume(returning: info?.serialNumber ?? 0)
                }
            }
        }
        LogStore.shared.info("YubiKey", "identifySerial: read serial \(serial)")
        return "\(serial)"
        #else
        throw Error.sdkUnavailable
        #endif
    }

    /// Enroll the YubiKey for Identity Sandwich wrap via FIDO2 over
    /// NFC. Returns the credential id (hex) and the first wrap
    /// signature so the caller can seal the blob right away without
    /// asking the user to tap again.
    func enrollOverNFC(label: String, salt: Data, deviceSerial: String, pin: String?) async throws -> (credentialIdHex: String, secret: Data) {
        #if canImport(YubiKit) && MAKNOON_NFC
        LogStore.shared.info("YubiKey", "enrollOverNFC: starting (serial=\(deviceSerial), salt=\(salt.count)B, pin=\(pin?.isEmpty == false ? "set" : "none"))")
        let connection = try await waitForNFCConnection(prompt: "Tap your YubiKey to register it")
        defer {
            LogStore.shared.info("YubiKey", "enrollOverNFC: stopping NFC session")
            YubiKitManager.shared.stopNFCConnection()
        }
        LogStore.shared.info("YubiKey", "enrollOverNFC: NFC connected, opening FIDO2 session")
        let session = try await openFIDO2Session(connection: connection)
        if let pin, !pin.isEmpty {
            LogStore.shared.info("YubiKey", "enrollOverNFC: verifying PIN")
            try await verifyPinOnSession(session: session, pin: pin)
            LogStore.shared.info("YubiKey", "enrollOverNFC: PIN verified")
        }
        LogStore.shared.info("YubiKey", "enrollOverNFC: FIDO2 session opened, calling makeCredential")
        let credId = try await makeCredentialOnSession(session: session, label: label)
        LogStore.shared.info("YubiKey", "enrollOverNFC: makeCredential returned credId (\(credId.count)B), calling getAssertion")
        let signature = try await getAssertionOnSession(
            session: session,
            credentialIdData: credId,
            salt: salt,
            deviceSerial: deviceSerial
        )
        LogStore.shared.info("YubiKey", "enrollOverNFC: getAssertion returned signature (\(signature.count)B)")
        return (
            credentialIdHex: credId.hexString,
            secret: Data(SHA256.hash(data: signature))
        )
        #else
        throw Error.nfcRequired
        #endif
    }

    /// Enroll a YubiKey for Identity Sandwich wrap using the FIDO2
    /// `hmac-secret` extension (CTAP2 §11.2). This is the wrap-
    /// protocol-v2 path: the derived secret comes from a credential-
    /// resident HMAC keyed on (credential, salt), so it's stable
    /// across calls even though FIDO2 signature counters change.
    /// Returns the credential id (hex) plus the 32-byte
    /// hmac-secret output the caller HKDFs into the AES wrap key.
    ///
    /// `pin` is required on YubiKeys with a clientPin set, because
    /// hmac-secret requires UV per CTAP2 spec when UV is configured
    /// on the authenticator. Pass nil only for keys without a PIN.
    func enrollHMACSecretOverNFC(
        label: String,
        salt: Data,
        deviceSerial: String,
        pin: String?
    ) async throws -> (credentialIdHex: String, secret: Data) {
        #if canImport(YubiKit) && MAKNOON_NFC
        precondition(salt.count == 32, "wrap salt must be 32 bytes")
        LogStore.shared.info("YubiKey", "enrollHMACSecretOverNFC: starting (serial=\(deviceSerial), pin=\(pin?.isEmpty == false ? "set" : "none"))")
        defer { observer.clearAllPendingState() }
        let connection = try await waitForNFCConnection(prompt: "Tap your YubiKey to register it")
        defer {
            LogStore.shared.info("YubiKey", "enrollHMACSecretOverNFC: stopping NFC session")
            YubiKitManager.shared.stopNFCConnection()
        }
        let ctap = try await openCTAP2(on: connection)
        let ext = try await ctap.getInfoExtensions()
        guard ext.contains("hmac-secret") else {
            LogStore.shared.error("YubiKey", "enrollHMACSecretOverNFC: authenticator does not list hmac-secret in getInfo.extensions")
            throw Error.fido2("This YubiKey's firmware does not advertise the hmac-secret extension. Maknoon needs hmac-secret to derive a stable wrap key; try a YubiKey 5 series with firmware 5.2 or newer.")
        }
        // PIN protocol v1 setup.
        let authPub = try await ctap.getKeyAgreement()
        let platformPriv = P256.KeyAgreement.PrivateKey()
        let shared = try PINProtocolV1.sharedSecret(
            platformPriv: platformPriv,
            authenticatorPub: authPub
        )
        let pinToken: Data
        if let pin, !pin.isEmpty {
            pinToken = try await ctap.getPinToken(
                pin: pin,
                platformPriv: platformPriv,
                authenticatorPub: authPub
            )
            LogStore.shared.info("YubiKey", "enrollHMACSecretOverNFC: pinToken acquired")
        } else {
            // No-PIN keys: there's no pinToken; the YubiKey will
            // still gate makeCredential on user presence (NFC tap).
            // We cannot satisfy CTAP2 PIN auth so makeCredential's
            // pinUvAuthParam path is skipped; some firmware rejects
            // this. Document the limitation rather than guess.
            throw Error.fido2("This YubiKey has no FIDO2 PIN. Set a PIN on the key (yubico-authenticator > FIDO2 > Set PIN) before enrolling it in the Identity Sandwich.")
        }
        let cdh = wrapClientDataHash(salt: salt, deviceSerial: deviceSerial)
        let pinUvAuthParam = PINProtocolV1.authenticate(key: pinToken, message: cdh)

        let userId = randomBytes(count: 16)
        let credResult = try await ctap.makeCredentialHMACSecret(
            rpId: Self.rpId,
            rpName: "Maknoon Identity",
            userId: userId,
            userName: label,
            clientDataHash: cdh,
            pinUvAuthParam: pinUvAuthParam
        )
        LogStore.shared.info("YubiKey", "enrollHMACSecretOverNFC: credential created (id=\(credResult.credentialId.prefix(8).map { String(format: "%02x", $0) }.joined())..., \(credResult.credentialId.count) bytes)")

        let assertResult = try await ctap.getAssertionHMACSecret(
            rpId: Self.rpId,
            clientDataHash: cdh,
            credentialId: credResult.credentialId,
            salt: salt,
            platformPriv: platformPriv,
            authenticatorPub: authPub,
            sharedSecret: shared,
            pinUvAuthParam: pinUvAuthParam
        )
        LogStore.shared.info("YubiKey", "enrollHMACSecretOverNFC: hmac-secret output decoded (\(assertResult.hmacSecretOutput.count) bytes)")
        return (
            credentialIdHex: credResult.credentialId.hexString,
            secret: assertResult.hmacSecretOutput
        )
        #else
        throw Error.nfcRequired
        #endif
    }

    /// Recompute the hmac-secret output for an enrolled YubiKey at
    /// unlock time. Same (credential, salt) → same output, by design
    /// of the FIDO2 hmac-secret extension. The output replaces the
    /// raw-signature-based wrap-key seed used in the broken v1 flow.
    func recomputeHMACSecretOverNFC(
        credentialIdHex: String,
        salt: Data,
        deviceSerial: String,
        pin: String?
    ) async throws -> Data {
        #if canImport(YubiKit) && MAKNOON_NFC
        precondition(salt.count == 32, "wrap salt must be 32 bytes")
        LogStore.shared.info("YubiKey", "recomputeHMACSecretOverNFC: starting (serial=\(deviceSerial), credId=\(credentialIdHex.prefix(16))...)")
        defer { observer.clearAllPendingState() }
        guard let credId = Data(hexString: credentialIdHex) else {
            throw Error.fido2("Stored credential id is not hex")
        }
        let connection = try await waitForNFCConnection(prompt: "Tap your YubiKey to unlock")
        defer {
            LogStore.shared.info("YubiKey", "recomputeHMACSecretOverNFC: stopping NFC session")
            YubiKitManager.shared.stopNFCConnection()
        }
        let ctap = try await openCTAP2(on: connection)
        let authPub = try await ctap.getKeyAgreement()
        let platformPriv = P256.KeyAgreement.PrivateKey()
        let shared = try PINProtocolV1.sharedSecret(
            platformPriv: platformPriv,
            authenticatorPub: authPub
        )
        let pinToken: Data
        if let pin, !pin.isEmpty {
            pinToken = try await ctap.getPinToken(
                pin: pin,
                platformPriv: platformPriv,
                authenticatorPub: authPub
            )
        } else {
            throw Error.fido2("This YubiKey has no FIDO2 PIN. Set a PIN on the key before unlocking.")
        }
        let cdh = wrapClientDataHash(salt: salt, deviceSerial: deviceSerial)
        let pinUvAuthParam = PINProtocolV1.authenticate(key: pinToken, message: cdh)
        let assertResult = try await ctap.getAssertionHMACSecret(
            rpId: Self.rpId,
            clientDataHash: cdh,
            credentialId: credId,
            salt: salt,
            platformPriv: platformPriv,
            authenticatorPub: authPub,
            sharedSecret: shared,
            pinUvAuthParam: pinUvAuthParam
        )
        LogStore.shared.info("YubiKey", "recomputeHMACSecretOverNFC: hmac-secret output decoded (\(assertResult.hmacSecretOutput.count) bytes)")
        return assertResult.hmacSecretOutput
        #else
        throw Error.nfcRequired
        #endif
    }

    // MARK: -- v1 legacy (raw-signature) wrap; broken for unlock

    /// Recompute the wrap signature for an enrolled YubiKey at
    /// unlock time. Caller hands in the persisted credential id +
    /// salt; deterministic ECDSA gives back the same signature each
    /// time, which HKDFs into the same wrap key.
    func recomputeSecretOverNFC(credentialIdHex: String, salt: Data, deviceSerial: String, pin: String?) async throws -> Data {
        #if canImport(YubiKit) && MAKNOON_NFC
        LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: starting (serial=\(deviceSerial), salt=\(salt.count)B, credId=\(credentialIdHex.prefix(16))..., pin=\(pin?.isEmpty == false ? "set" : "none"))")
        guard let credId = Data(hexString: credentialIdHex) else {
            LogStore.shared.error("YubiKey", "recomputeSecretOverNFC: stored credential id is not hex")
            throw Error.fido2("stored credential id is not hex")
        }
        let connection = try await waitForNFCConnection(prompt: "Tap your YubiKey to unlock")
        defer {
            LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: stopping NFC session")
            YubiKitManager.shared.stopNFCConnection()
        }
        LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: NFC connected, opening FIDO2 session")
        let session = try await openFIDO2Session(connection: connection)
        if let pin, !pin.isEmpty {
            LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: verifying PIN")
            try await verifyPinOnSession(session: session, pin: pin)
            LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: PIN verified")
        }
        LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: FIDO2 session opened, calling getAssertion")
        let signature = try await getAssertionOnSession(
            session: session,
            credentialIdData: credId,
            salt: salt,
            deviceSerial: deviceSerial
        )
        LogStore.shared.info("YubiKey", "recomputeSecretOverNFC: getAssertion returned signature (\(signature.count)B)")
        return Data(SHA256.hash(data: signature))
        #else
        LogStore.shared.error("YubiKey", "recomputeSecretOverNFC: MAKNOON_NFC not compiled in — this build cannot do NFC")
        throw Error.nfcRequired
        #endif
    }

    // MARK: -- Constants

    /// Maknoon's fixed RP id for the Identity Sandwich wrap.
    private static let rpId = "maknoon.elabify.com"

    // MARK: -- Internals

    #if canImport(YubiKit)
    private func waitForSmartCardConnection() async throws -> YKFSmartCardConnection {
        if let existing = observer.currentSmartCard { return existing }
        let holder: SmartCardHolder = try await withCheckedThrowingContinuation { cont in
            let token = observer.attachSmartCardWaiter(
                onConnect: { connection in
                    cont.resume(returning: SmartCardHolder(connection: connection))
                },
                onTimeout: { cont.resume(throwing: Error.timeout) },
                onCancel: { cont.resume(throwing: Error.userCanceled) }
            )
            YubiKitManager.shared.startSmartCardConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak observer = self.observer] in
                observer?.fireSmartCardTimeout(token: token)
            }
        }
        return holder.connection
    }

    #if MAKNOON_NFC
    private func waitForNFCConnection(prompt: String) async throws -> YKFNFCConnection {
        // Log YubiKit's capability check as advisory only. It can
        // report false even when NFC actually works (older paid-team
        // profiles where NFC wasn't toggled in the Identifiers
        // portal at signing time, certain sideload paths). We let
        // iOS itself decide: startNFCConnection will either present
        // the sheet, or invoke didFailConnectingNFC with a real
        // NFCReaderError code that we surface verbatim.
        let cap = YubiKitDeviceCapabilities.supportsISO7816NFCTags
        LogStore.shared.info("YubiKey", "waitForNFCConnection: YubiKitDeviceCapabilities.supportsISO7816NFCTags=\(cap) (advisory)")
        // Don't reuse `observer.currentNFC` — after a CTAP2 error
        // (wrong PIN, etc.) the cached reference is stale: iOS may
        // not have called didDisconnectNFC yet, but the NFC session
        // is dead on the device side. Reusing it leaves the user
        // stranded with NFCError 102 until force-quit. Always start
        // a fresh session; the extra startNFCConnection is cheap
        // compared to the tap-to-tap latency the user already pays.
        observer.clearAllPendingState()
        LogStore.shared.info("YubiKey", "waitForNFCConnection: calling startNFCConnection (prompt=\"\(prompt)\")")
        let holder: NFCHolder = try await withCheckedThrowingContinuation { cont in
            let token = observer.attachNFCWaiter(
                onConnect: { connection in
                    LogStore.shared.info("YubiKey", "waitForNFCConnection: didConnectNFC fired")
                    cont.resume(returning: NFCHolder(connection: connection))
                },
                onTimeout: {
                    LogStore.shared.warn("YubiKey", "waitForNFCConnection: 60s timeout with no NFC tap")
                    cont.resume(throwing: Error.timeout)
                },
                onCancel: {
                    LogStore.shared.info("YubiKey", "waitForNFCConnection: user canceled NFC sheet")
                    cont.resume(throwing: Error.userCanceled)
                },
                onFail: { err in
                    LogStore.shared.error("YubiKey", "waitForNFCConnection: didFailConnectingNFC \(err.localizedDescription)")
                    cont.resume(throwing: Error.session(err.localizedDescription))
                }
            )
            YubiKitManager.shared.startNFCConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak observer = self.observer] in
                observer?.fireNFCTimeout(token: token)
            }
        }
        return holder.connection
    }

    /// Open the FIDO2 applet on an NFC connection's smart-card
    /// interface so we can drive raw CTAP2 commands (hmac-secret
    /// support). yubikit-ios's YKFFIDO2Session selects the applet
    /// implicitly, but doesn't expose the smart-card layer; here we
    /// do the same select ourselves.
    private func openCTAP2(on connection: YKFNFCConnection) async throws -> CTAP2Client {
        guard let smartCard = connection.smartCardInterface else {
            throw Error.noConnection
        }
        // Select FIDO2 applet (AID A0000006472F0001 per CTAP2 spec).
        // The Objective-C bridging initializer is annotated as
        // returning an optional but the FIDO2 builder cannot return
        // nil; treat as a hard precondition rather than threading
        // optional-ness through the async path.
        guard let selectAPDU = YKFSelectApplicationAPDU(applicationName: .FIDO2) else {
            throw Error.session("Could not build select-FIDO2 APDU")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            smartCard.selectApplication(selectAPDU) { data, err in
                if let err {
                    LogStore.shared.error("YubiKey", "openCTAP2: select FIDO2 failed: \(err.localizedDescription)")
                    cont.resume(throwing: Error.session(err.localizedDescription))
                    return
                }
                _ = data
                cont.resume(returning: ())
            }
        }
        LogStore.shared.info("YubiKey", "openCTAP2: FIDO2 applet selected")
        return CTAP2Client(smartCard: smartCard)
    }

    private func verifyPinOnSession(session: YKFFIDO2Session, pin: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            session.verifyPin(pin) { err in
                if let err {
                    LogStore.shared.error("YubiKey", "verifyPin: \(err.localizedDescription)")
                    cont.resume(throwing: Error.fido2("PIN verification failed: \(err.localizedDescription)"))
                    return
                }
                cont.resume(returning: ())
            }
        }
    }

    private func openFIDO2Session(connection: YKFNFCConnection) async throws -> YKFFIDO2Session {
        let holder: FIDO2SessionHolder = try await withCheckedThrowingContinuation { cont in
            connection.fido2Session { session, err in
                if let err { cont.resume(throwing: Error.fido2(err.localizedDescription)); return }
                guard let session else { cont.resume(throwing: Error.noConnection); return }
                cont.resume(returning: FIDO2SessionHolder(session: session))
            }
        }
        return holder.session
    }

    private func makeCredentialOnSession(session: YKFFIDO2Session, label: String) async throws -> Data {
        let rp = YKFFIDO2PublicKeyCredentialRpEntity()
        rp.rpId = Self.rpId
        rp.rpName = "Maknoon Identity"

        let user = YKFFIDO2PublicKeyCredentialUserEntity()
        user.userId = randomBytes(count: 16)
        user.userName = label
        user.userDisplayName = label

        let alg = YKFFIDO2PublicKeyCredentialParam()
        alg.alg = -7  // ES256

        // Pass an empty options map. CTAP2 defaults are non-resident
        // (rk=false) without user verification, which is exactly what
        // we want. Older YubiKey 5 firmware (FIDO2.0) returns
        // CTAP2_ERR_UNSUPPORTED_OPTION when "uv" is set explicitly,
        // even with false, because UV is undefined on that firmware.
        // Omitting the keys lets every YubiKey firmware vintage
        // accept the request.
        let cdh = webauthnClientDataHash(challenge: randomBytes(count: 32), purpose: "webauthn.create")

        return try await withCheckedThrowingContinuation { cont in
            session.makeCredential(
                withClientDataHash: cdh,
                rp: rp,
                user: user,
                pubKeyCredParams: [alg],
                excludeList: nil,
                options: nil
            ) { resp, err in
                if let err { cont.resume(throwing: Error.fido2(err.localizedDescription)); return }
                if let id = resp?.authenticatorData?.credentialId, !id.isEmpty {
                    cont.resume(returning: id); return
                }
                cont.resume(throwing: Error.fido2("credential id missing in attestation"))
            }
        }
    }

    private func getAssertionOnSession(
        session: YKFFIDO2Session,
        credentialIdData: Data,
        salt: Data,
        deviceSerial: String
    ) async throws -> Data {
        let allow = YKFFIDO2PublicKeyCredentialDescriptor()
        allow.credentialId = credentialIdData
        let pkType = YKFFIDO2PublicKeyCredentialType()
        pkType.name = "public-key"
        allow.credentialType = pkType

        // Omit options entirely. CTAP2 defaults are up=true, uv=false,
        // which matches the wrap requirement: the user must tap the
        // key (user-presence), no PIN verification. Setting "uv":
        // false explicitly triggers CTAP2_ERR_UNSUPPORTED_OPTION on
        // FIDO2.0 firmware (YubiKey 5 series before 5.7).
        let cdh = wrapClientDataHash(salt: salt, deviceSerial: deviceSerial)

        return try await withCheckedThrowingContinuation { cont in
            session.getAssertionWithClientDataHash(
                cdh,
                rpId: Self.rpId,
                allowList: [allow],
                options: nil
            ) { resp, err in
                if let err { cont.resume(throwing: Error.fido2(err.localizedDescription)); return }
                let s = resp?.signature
                if let s, !s.isEmpty { cont.resume(returning: s); return }
                cont.resume(throwing: Error.missingSignature)
            }
        }
    }
    #endif // MAKNOON_NFC
    #endif // canImport(YubiKit)

    /// Domain-separated client data hash used at FIDO2 wrap time.
    /// Mirrors the shape of WebAuthn but isn't actually a WebAuthn
    /// JSON ClientDataJSON; we just hash a fixed prefix plus salt
    /// plus device serial so each device gets a unique signature
    /// per wrap blob.
    private func wrapClientDataHash(salt: Data, deviceSerial: String) -> Data {
        var input = Data()
        input.append(Data("maknoon-wrap-v1".utf8))
        input.append(salt)
        input.append(Data(deviceSerial.utf8))
        return Data(SHA256.hash(data: input))
    }

    private func webauthnClientDataHash(challenge: Data, purpose: String) -> Data {
        var cd = [String: Any]()
        cd["type"] = purpose
        cd["challenge"] = challenge.base64URLString
        cd["origin"] = "https://\(Self.rpId)"
        let json = try! JSONSerialization.data(withJSONObject: cd, options: [.sortedKeys])
        return Data(SHA256.hash(data: json))
    }

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    #if canImport(YubiKit)
    private struct SmartCardHolder: @unchecked Sendable {
        let connection: YKFSmartCardConnection
    }
    #if MAKNOON_NFC
    private struct NFCHolder: @unchecked Sendable {
        let connection: YKFNFCConnection
    }
    private struct FIDO2SessionHolder: @unchecked Sendable {
        let session: YKFFIDO2Session
    }
    #endif
    #endif
}

#if canImport(YubiKit)
@MainActor
private final class ConnectionObserver: NSObject, YKFManagerDelegate {
    typealias Token = UInt64

    private(set) var currentSmartCard: YKFSmartCardConnection?
    private(set) var currentNFC: YKFNFCConnection?

    private struct SmartCardWaiter {
        let token: Token
        let onConnect: (YKFSmartCardConnection) -> Void
        let onTimeout: () -> Void
        let onCancel: () -> Void
    }
    private struct NFCWaiter {
        let token: Token
        let onConnect: (YKFNFCConnection) -> Void
        let onTimeout: () -> Void
        let onCancel: () -> Void
        let onFail: (Swift.Error) -> Void
    }

    private var pendingSmartCard: SmartCardWaiter?
    private var pendingNFC: NFCWaiter?
    private var nextToken: Token = 1

    func attachSmartCardWaiter(
        onConnect: @escaping (YKFSmartCardConnection) -> Void,
        onTimeout: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> Token {
        let token = nextToken
        nextToken &+= 1
        pendingSmartCard = SmartCardWaiter(token: token, onConnect: onConnect, onTimeout: onTimeout, onCancel: onCancel)
        return token
    }

    func attachNFCWaiter(
        onConnect: @escaping (YKFNFCConnection) -> Void,
        onTimeout: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onFail: @escaping (Swift.Error) -> Void
    ) -> Token {
        let token = nextToken
        nextToken &+= 1
        pendingNFC = NFCWaiter(token: token, onConnect: onConnect, onTimeout: onTimeout, onCancel: onCancel, onFail: onFail)
        return token
    }

    func fireSmartCardTimeout(token: Token) {
        guard let w = pendingSmartCard, w.token == token else { return }
        pendingSmartCard = nil
        w.onTimeout()
    }

    func fireNFCTimeout(token: Token) {
        guard let w = pendingNFC, w.token == token else { return }
        pendingNFC = nil
        w.onTimeout()
    }

    func fireCancellation() {
        if let w = pendingSmartCard { pendingSmartCard = nil; w.onCancel() }
        if let w = pendingNFC { pendingNFC = nil; w.onCancel() }
    }

    /// Force-clear every cached connection + pending waiter. Called
    /// from the YubiKey public entry points on every exit (success or
    /// throw) so a half-open NFC session left behind by a CTAP2 error
    /// (e.g. wrong PIN → didFailConnectingNFC fires after
    /// didConnectNFC) can't poison the next attempt. Without this,
    /// the wrong-PIN failure mode is: `currentNFC` stays cached, the
    /// next `waitForNFCConnection` call (or the old code's
    /// reuse-if-set branch) hands back a dead reference, and every
    /// subsequent YubiKey op fails with NFCError 102 until force-
    /// quit.
    func clearAllPendingState() {
        if let w = pendingSmartCard { pendingSmartCard = nil; w.onCancel() }
        if let w = pendingNFC { pendingNFC = nil; w.onCancel() }
        currentSmartCard = nil
        currentNFC = nil
    }

    nonisolated func didConnectSmartCard(_ connection: YKFSmartCardConnection) {
        let holder = SmartCardShuttle(connection: connection)
        Task { @MainActor in
            self.currentSmartCard = holder.connection
            if let w = self.pendingSmartCard {
                self.pendingSmartCard = nil
                w.onConnect(holder.connection)
            }
        }
    }

    nonisolated func didDisconnectSmartCard(_ connection: YKFSmartCardConnection, error: Swift.Error?) {
        Task { @MainActor in self.currentSmartCard = nil }
    }

    nonisolated func didConnectNFC(_ connection: YKFNFCConnection) {
        let holder = NFCShuttle(connection: connection)
        Task { @MainActor in
            self.currentNFC = holder.connection
            if let w = self.pendingNFC {
                self.pendingNFC = nil
                w.onConnect(holder.connection)
            }
        }
    }

    nonisolated func didDisconnectNFC(_ connection: YKFNFCConnection, error: Swift.Error?) {
        Task { @MainActor in self.currentNFC = nil }
    }

    nonisolated func didFailConnectingNFC(_ error: Swift.Error) {
        let shuttle = ErrorShuttle(error: error)
        Task { @MainActor in
            if let w = self.pendingNFC {
                self.pendingNFC = nil
                w.onFail(shuttle.error)
            }
        }
    }

    private struct SmartCardShuttle: @unchecked Sendable {
        let connection: YKFSmartCardConnection
    }
    private struct NFCShuttle: @unchecked Sendable {
        let connection: YKFNFCConnection
    }
    private struct ErrorShuttle: @unchecked Sendable {
        let error: Swift.Error
    }

    nonisolated func didConnectAccessory(_ connection: YKFAccessoryConnection) {}
    nonisolated func didDisconnectAccessory(_ connection: YKFAccessoryConnection, error: Swift.Error?) {}
    nonisolated func didFailConnectingSmartCard(_ error: Swift.Error) {}
}
#endif

private extension Data {
    init?(hexString: String) {
        let s = hexString.replacingOccurrences(of: " ", with: "")
        guard s.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var base64URLString: String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
