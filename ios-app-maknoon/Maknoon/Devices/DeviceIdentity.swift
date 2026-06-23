// Deterministic device identity (ADR-0033). A registered device's id is
// UUIDv5(namespace, "<kind.rawValue>:<serial>") so re-adding or restoring the
// SAME physical device always reproduces the SAME id. This prevents the
// orphaned-wallet bug: wallets link to their device by a `deviceId: UUID`, so a
// random per-registration id meant removing + re-adding a device (or a restore)
// minted a new id and broke every wallet link under it. A deterministic id makes
// a remove + re-add cycle return the same id, so the links survive.
//
// CROSS-PLATFORM CONTRACT: byte-identical to Android DeviceIdentity. KAT:
//   trezor:BE12AAAEFA704D6B6A9E4EC6 -> 9d2002ff-fa4c-5d54-ab7a-4405728585f7
//
// CAVEAT: for a Ledger the `serial` is a platform-specific BLE transport id
// (iOS CoreBluetooth peripheral UUID vs Android BLE MAC), so the deterministic
// id is stable only WITHIN a platform; across platforms the serial (and thus the
// id) differs and the connect-time serial rebind + relink-by-key paths recover
// the link. A Trezor's serial is its firmware device_id (stable cross-platform),
// so its deterministic id is identical on both platforms.

import Foundation
import CryptoKit

enum DeviceIdentity {
    /// RFC 4122 namespace UUID for Maknoon device ids. MUST match Android.
    static let namespace = UUID(uuidString: "f9b6a1c2-3d4e-5f60-8a1b-2c3d4e5f6071")!

    /// The deterministic id for a (kind, serial) pair.
    static func deterministicId(kind: DeviceKind, serial: String) -> UUID {
        uuidV5(namespace: namespace, name: "\(kind.rawValue):\(serial)")
    }

    /// RFC 4122 name-based UUID, VERSION 5 (SHA-1). Matches Foundation /
    /// Python `uuid.uuid5` and Android's hand-rolled v5 byte-for-byte.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = Data(bytes(of: namespace))
        data.append(contentsOf: Array(name.utf8))
        let digest = Array(Insecure.SHA1.hash(data: data)) // 20 bytes
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50 // version 5
        b[8] = (b[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
    }
}
