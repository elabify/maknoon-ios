// Trezor Safe 5 BLE client. Scaffolds the BLE plumbing in the same
// shape as `LedgerBLE.swift`; the protobuf framed-message protocol for
// SignMessage is the bit that needs real-device validation.
//
// Trezor wire references (github.com/trezor/trezor-firmware):
//
//   Service UUID:        8c000001-a59b-4d58-a9ad-073df69fa1b1
//   Write characteristic: 8c000002-a59b-4d58-a9ad-073df69fa1b1
//   Notify characteristic: 8c000003-a59b-4d58-a9ad-073df69fa1b1
//
//   (UUIDs match the BLE-adapter convention Trezor's open-source
//   firmware uses for Safe 5; verify against the firmware shipped on
//   your specific device before relying on them.)
//
// Message protocol: trezor-protobuf framed over the BLE write/notify
// pair. Each chunk is 64 bytes; the first 9 bytes carry the
// "?" sentinel + magic + message type + length, and subsequent chunks
// chain via the same sentinel. See trezor-firmware/python/src/trezorlib/transport/bridge.py
// for the reference framing.
//
// Phase 0.1 ships ONLY the BLE plumbing; the protobuf encode/decode
// for `MessageSignEth` + `EthereumMessageSignature` and the on-device
// confirmation prompts are TODO until field testing with a real
// Trezor Safe 5. Pair / signMessage throw `.notImplemented(.trezor)`
// at runtime so the UI routes the user back to the picker; the
// Settings sheet hides the Trezor option on simulator builds.

import CoreBluetooth
import Foundation

private nonisolated(unsafe) let trezorServiceUUID = CBUUID(string: "8c000001-a59b-4d58-a9ad-073df69fa1b1")
private nonisolated(unsafe) let trezorWriteUUID   = CBUUID(string: "8c000002-a59b-4d58-a9ad-073df69fa1b1")
private nonisolated(unsafe) let trezorNotifyUUID  = CBUUID(string: "8c000003-a59b-4d58-a9ad-073df69fa1b1")

final class TrezorBLE: NSObject, HardwareWallet, @unchecked Sendable {
    var kind: HardwareWalletKind { .trezor }

    func pair() async throws -> Data {
        // TODO Phase 0.2: connect + Initialize/Features + EthereumGetPublicKey
        // protobuf flow, return compressed secp256k1 pubkey.
        throw HardwareWalletError.notImplemented(.trezor)
    }

    func signMessage(_ message: Data) async throws -> Data {
        // TODO Phase 0.2: EthereumSignMessage with on-device confirm.
        throw HardwareWalletError.notImplemented(.trezor)
    }
}
