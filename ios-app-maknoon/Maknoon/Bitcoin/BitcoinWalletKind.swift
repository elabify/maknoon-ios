// The two flavours of Bitcoin wallet Maknoon supports.
//
//   .software(account:)
//     Derives BIP84 keys from the Identity Sandwich's BIP39 seed.
//     The `account` field is the BIP44 account index, so a user can
//     have several independently-labelled software wallets all
//     rooted in the same 24-word recovery phrase.
//
//   .hardware(deviceId:, accountFingerprint:, accountXpub:)
//     Watch-only descriptor built from an xpub fetched from a paired
//     Ledger or Trezor at pairing time. The private key never leaves
//     the device; PSBT signing routes back to the device over BLE.

import Foundation

enum BitcoinWalletKind: Codable, Hashable, Sendable {
    case software(account: UInt32)
    case hardware(deviceId: UUID, accountFingerprint: String, accountXpub: String)
}
