// Two flavours of Ethereum wallet, mirroring BitcoinWalletKind.
//
//   .software(account:)
//     Derives the BIP44 EOA address from the Identity Sandwich's
//     BIP39 seed at m/44'/60'/<account>'/0/0. Multiple accounts
//     can coexist from the same seed.
//
//   .hardware(deviceId:, account:, address:)
//     Address fetched from a paired Ledger / Trezor at pairing time
//     for `m/44'/60'/<account>'/0/0`. The private key never leaves
//     the device; signing routes back over BLE at the same path.

import Foundation

enum EthereumWalletKind: Codable, Hashable, Sendable {
    case software(account: UInt32)
    case hardware(deviceId: UUID, account: UInt32, address: String)
}
