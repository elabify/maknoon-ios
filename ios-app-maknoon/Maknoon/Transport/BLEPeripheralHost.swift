// Holder side of the BLE engagement transport. Advertises a per-session
// GATT service, writes the holder's HPKE public key into the engagement
// QR off-band, then waits for the verifier to write an encapsulated
// key + read back the sealed Presentation.
//
// One `BLEPeripheralHost` per share session. Tear it down (`.stop()`)
// when the share sheet dismisses; the radio stops advertising on
// dealloc as well, but explicit teardown avoids lingering visibility
// to nearby devices.
//
// GATT layout per ADR-0028:
//   handshake: write (no response). Verifier writes encapsulated key.
//   payload  : write w/ response + notify. Sealed Presentation flows
//               here (verifier reads via notify).
//   status   : notify. One-shot completion signal.
//
// The simulator has no BLE radio. On simulator builds the peripheral
// initialises but never reaches `.poweredOn`; the share sheet
// surfaces this as "BLE unavailable on simulator" and the user can
// fall back to multi-frame QR.

import CoreBluetooth
import CryptoKit
import Foundation

enum BLEPeripheralPhase {
    case idle
    case unsupported(String)
    case advertising
    case handshakeReceived
    case payloadDelivered
    case error(String)
}

@MainActor
final class BLEPeripheralHost: NSObject, ObservableObject {
    @Published private(set) var phase: BLEPeripheralPhase = .idle
    @Published private(set) var engagement: TransportEngagement?

    private var peripheral: CBPeripheralManager?
    private var holderTransport: TransportHolder?
    private var serviceUuid: CBUUID = CBUUID(nsuuid: UUID())
    private var sessionId: String = ""
    private var handshakeChar: CBMutableCharacteristic?
    private var payloadChar: CBMutableCharacteristic?
    private var statusChar: CBMutableCharacteristic?
    private var sealedPayload: Data?
    private var subscribedCentral: CBCentral?

    // Characteristic suffix bytes per ADR-0028.
    static let handshakeSuffix: UInt8 = 0x01
    static let payloadSuffix:   UInt8 = 0x02
    static let statusSuffix:    UInt8 = 0x03

    /// Start advertising. Builds a fresh X-Wing keypair, a fresh
    /// service UUID, and emits the engagement payload into
    /// `self.engagement` so the UI can render the QR.
    func start() {
        do {
            let transport = try TransportHolder()
            holderTransport = transport
            let svcUuid = UUID()
            serviceUuid = CBUUID(nsuuid: svcUuid)
            sessionId = randomHex(8)
            engagement = TransportEngagement(
                v: TransportEngagement.version,
                sessionId: sessionId,
                issuedAt: Int64(Date().timeIntervalSince1970),
                expiresAt: Int64(Date().timeIntervalSince1970) + 120,
                ble: EngagementBLE(
                    service: svcUuid.uuidString,
                    engagementKey: transport.publicKeyBase64
                ),
                fallback: EngagementFallback(multiframeQr: true, callbackUrl: nil)
            )
            peripheral = CBPeripheralManager(delegate: self, queue: nil)
            phase = .idle
        } catch {
            phase = .error("Could not generate engagement key: \(error)")
        }
    }

    /// Stop advertising + tear down the GATT service.
    func stop() {
        peripheral?.stopAdvertising()
        peripheral?.removeAllServices()
        peripheral = nil
        holderTransport = nil
        sealedPayload = nil
        engagement = nil
        subscribedCentral = nil
        phase = .idle
    }

    /// Stage the Presentation that will be sealed + delivered once the
    /// verifier connects. Call BEFORE `start()` in normal flows so the
    /// session can complete the moment the verifier writes its
    /// encapsulated key.
    func setPresentation(_ presentation: Presentation) throws {
        try setPayload(JSONEncoder().encode(presentation))
    }

    /// Stage an arbitrary already-encoded payload (e.g. a `CommerceResponse`)
    /// to be sealed + delivered on handshake, exactly like `setPresentation`.
    /// Maknoon Pay's full lane (ADR-0031) stages a CommerceResponse here; the
    /// merchant decodes it instead of a bare Presentation.
    func setPayload(_ data: Data) {
        sealedPayload = data
    }

    // MARK: -- internals

    private func registerGattService() {
        guard let peripheral else { return }
        handshakeChar = CBMutableCharacteristic(
            type: charUuid(suffix: Self.handshakeSuffix),
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        payloadChar = CBMutableCharacteristic(
            type: charUuid(suffix: Self.payloadSuffix),
            properties: [.notify, .write],
            value: nil,
            permissions: [.writeable]
        )
        statusChar = CBMutableCharacteristic(
            type: charUuid(suffix: Self.statusSuffix),
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let svc = CBMutableService(type: serviceUuid, primary: true)
        svc.characteristics = [handshakeChar!, payloadChar!, statusChar!]
        peripheral.add(svc)
    }

    private func charUuid(suffix: UInt8) -> CBUUID {
        // 128-bit per-session UUID with a trailing byte that
        // distinguishes the three characteristics. Layout-stable so
        // the verifier can derive them from the service UUID alone.
        var bytes = uuidToBytes(serviceUuid)
        bytes[15] = suffix
        return CBUUID(data: bytes)
    }
}

// `@preconcurrency` is load-bearing here: BLEPeripheralHost is
// @MainActor and the CB delegate methods need to satisfy a
// nonisolated protocol requirement. Without it, Swift 6 rejects
// the conformance with "main actor-isolated instance method
// cannot satisfy nonisolated requirement."
extension BLEPeripheralHost: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.registerGattService()
            case .poweredOff:
                self.phase = .unsupported("Bluetooth is off")
            case .unauthorized:
                self.phase = .unsupported("Bluetooth permission denied")
            case .unsupported:
                self.phase = .unsupported("BLE unsupported on this device")
            case .resetting, .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            Task { @MainActor in self.phase = .error("addService: \(error!)") }
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUuid],
            CBAdvertisementDataLocalNameKey:    "Maknoon",
        ])
        Task { @MainActor in self.phase = .advertising }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if req.characteristic.uuid == handshakeChar?.uuid {
                guard let data = req.value else { continue }
                handleHandshake(data: data, central: req.central, peripheral: peripheral)
                peripheral.respond(to: req, withResult: .success)
            } else {
                peripheral.respond(to: req, withResult: .writeNotPermitted)
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == payloadChar?.uuid {
            subscribedCentral = central
        }
    }

    private func handleHandshake(data: Data, central: CBCentral, peripheral: CBPeripheralManager) {
        guard let holderTransport, let payloadChar, let sealedPayload else {
            Task { @MainActor in self.phase = .error("Session state missing") }
            return
        }
        do {
            let recipient = try holderTransport.makeRecipient(
                encapsulatedKey: data,
                sessionId: sessionId,
                serviceUuid: serviceUuid.uuidString
            )
            // Phase 0.1 single-shot: holder reuses the symmetric
            // context to seal an OUTGOING sealed-presentation frame.
            // HPKE seal is on the SENDER side; for the holder to
            // ship a sealed message back we instead derive an
            // outgoing key via `exportSecret` + a private AEAD
            // call. Simpler path for Phase 0.1: the verifier and
            // holder both derive AES-256-GCM keys via
            // `recipient.exportSecret(...)`, and the holder uses
            // that with `AES.GCM` to seal the Presentation. The
            // verifier opens with the same key.
            let exportKey = try recipient.exportSecret(
                context: Data("elabify-payload".utf8),
                outputByteCount: 32
            )
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(sealedPayload, using: exportKey, nonce: nonce)
            // Wire: nonce (12 bytes) || ciphertext || tag (16 bytes).
            var blob = Data()
            blob.append(contentsOf: sealed.nonce)
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
            // Push via notify on payload characteristic.
            peripheral.updateValue(blob, for: payloadChar, onSubscribedCentrals: nil)
            Task { @MainActor in self.phase = .payloadDelivered }
        } catch {
            Task { @MainActor in self.phase = .error("Handshake failed: \(error)") }
        }
    }
}

// MARK: -- small helpers

private func uuidToBytes(_ cb: CBUUID) -> Data {
    return cb.data
}

private func randomHex(_ count: Int) -> String {
    var b = Data(count: count)
    _ = b.withUnsafeMutableBytes { ptr in
        SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
    }
    return b.map { String(format: "%02x", $0) }.joined()
}
