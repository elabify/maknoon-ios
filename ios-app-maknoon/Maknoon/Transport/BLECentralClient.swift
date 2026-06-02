// Verifier side of the BLE engagement transport. Given an Engagement
// payload (read from a single QR), scans for the advertised service
// UUID, connects, writes the encapsulated key to the handshake
// characteristic, and reads back the sealed Presentation from the
// payload notify.
//
// Phase 0.1: single-shot. The Presentation flows in one HPKE-derived
// AEAD frame on the wire (nonce || ciphertext || tag). Future revs
// can chunk; the framing is already length-aware.

import CoreBluetooth
import CryptoKit
import Foundation

enum BLECentralPhase {
    case idle
    case unsupported(String)
    case scanning
    case connecting
    case handshaking
    case receivingPayload
    case received(Presentation)
    case error(String)
}

@MainActor
final class BLECentralClient: NSObject, ObservableObject {
    @Published private(set) var phase: BLECentralPhase = .idle

    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var engagement: TransportEngagement?
    private var serviceUuid: CBUUID = CBUUID(nsuuid: UUID())
    private var encapsulatedKey: Data = Data()
    private var aeadKey: SymmetricKey?

    /// Begin a session with the given engagement payload. The central
    /// powers on, scans for the advertised service, connects, runs
    /// the HPKE handshake, and surfaces the decoded Presentation in
    /// `phase = .received(...)` when complete.
    func connect(to engagement: TransportEngagement) {
        guard let ble = engagement.ble, let svcUuid = UUID(uuidString: ble.service) else {
            phase = .error("Engagement has no usable BLE block")
            return
        }
        self.engagement = engagement
        self.serviceUuid = CBUUID(nsuuid: svcUuid)
        do {
            let (sender, encap) = try TransportVerifier.makeSender(
                holderPublicKeyBase64: ble.engagementKey,
                sessionId: engagement.sessionId,
                serviceUuid: ble.service
            )
            self.encapsulatedKey = encap
            self.aeadKey = try sender.exportSecret(
                context: Data("elabify-payload".utf8),
                outputByteCount: 32
            )
        } catch {
            phase = .error("HPKE setup failed: \(error)")
            return
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        connectedPeripheral = nil
        aeadKey = nil
        engagement = nil
    }

    // MARK: -- characteristics derived from service UUID

    private func charUuid(suffix: UInt8) -> CBUUID {
        var bytes = serviceUuid.data
        bytes[15] = suffix
        return CBUUID(data: bytes)
    }
}

// `@preconcurrency` is load-bearing here: BLECentralClient is
// @MainActor and the CB delegate methods need to satisfy a
// nonisolated protocol requirement.
extension BLECentralClient: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.phase = .scanning
                central.scanForPeripherals(withServices: [self.serviceUuid], options: nil)
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

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi: NSNumber) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        Task { @MainActor in self.phase = .connecting }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUuid])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Task { @MainActor in self.phase = .error("connect failed: \(error?.localizedDescription ?? "nil")") }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Normal end-of-transmission once we have the payload; surface
        // only if we hadn't already finished.
        if case .received = phase { return }
        Task { @MainActor in self.phase = .error("disconnected: \(error?.localizedDescription ?? "ok")") }
    }
}

extension BLECentralClient: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for svc in services where svc.uuid == serviceUuid {
            peripheral.discoverCharacteristics(
                [charUuid(suffix: BLEPeripheralHost.handshakeSuffix),
                 charUuid(suffix: BLEPeripheralHost.payloadSuffix),
                 charUuid(suffix: BLEPeripheralHost.statusSuffix)],
                for: svc
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        let handshake = chars.first { $0.uuid == charUuid(suffix: BLEPeripheralHost.handshakeSuffix) }
        let payload = chars.first { $0.uuid == charUuid(suffix: BLEPeripheralHost.payloadSuffix) }
        guard let handshake, let payload else {
            Task { @MainActor in self.phase = .error("GATT characteristics missing") }
            return
        }
        // Subscribe to notify on payload first so we don't miss the
        // immediate response to our handshake write.
        peripheral.setNotifyValue(true, for: payload)
        Task { @MainActor in self.phase = .handshaking }
        peripheral.writeValue(encapsulatedKey, for: handshake, type: .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == charUuid(suffix: BLEPeripheralHost.payloadSuffix),
              let data = characteristic.value,
              let aeadKey = aeadKey else { return }
        Task { @MainActor in self.phase = .receivingPayload }
        // Wire: nonce (12 B) || ciphertext || tag (16 B).
        guard data.count > 12 + 16 else {
            Task { @MainActor in self.phase = .error("payload too short") }
            return
        }
        let nonceBytes = data.prefix(12)
        let tagBytes = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagBytes)
            let plain = try AES.GCM.open(sealed, using: aeadKey)
            let presentation = try JSONDecoder().decode(Presentation.self, from: plain)
            Task { @MainActor in self.phase = .received(presentation) }
            // Drop the connection; the holder side waits for the
            // peripheral to be cancelled by the system or by our own
            // explicit disconnect.
            central?.cancelPeripheralConnection(peripheral)
        } catch {
            Task { @MainActor in self.phase = .error("decrypt failed: \(error)") }
        }
    }
}
