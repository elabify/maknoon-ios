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

    // Custom Codable: ENCODE keeps the native Swift shape
    // ({"software":{"account":N}} / {"hardware":{...}}) so existing iOS data and
    // iOS->Android restores are unchanged; DECODE also accepts Android's flat
    // shape ({"type":"software"|"hardware", ...}) so an Android backup restores
    // on iOS. See ADR-0035 (cross-platform wallet descriptors).
    private enum CaseKey: String, CodingKey { case software, hardware }
    private enum SoftwareKeys: String, CodingKey { case account }
    private enum HardwareKeys: String, CodingKey { case deviceId, accountFingerprint, accountXpub }
    private enum FlatKeys: String, CodingKey { case type, account, deviceId, accountFingerprint, accountXpub }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .software(let account):
            var s = c.nestedContainer(keyedBy: SoftwareKeys.self, forKey: .software)
            try s.encode(account, forKey: .account)
        case .hardware(let deviceId, let fp, let xpub):
            var h = c.nestedContainer(keyedBy: HardwareKeys.self, forKey: .hardware)
            try h.encode(deviceId, forKey: .deviceId)
            try h.encode(fp, forKey: .accountFingerprint)
            try h.encode(xpub, forKey: .accountXpub)
        }
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CaseKey.self), !c.allKeys.isEmpty {
            if let s = try? c.nestedContainer(keyedBy: SoftwareKeys.self, forKey: .software) {
                self = .software(account: (try? s.decode(UInt32.self, forKey: .account)) ?? 0); return
            }
            if let h = try? c.nestedContainer(keyedBy: HardwareKeys.self, forKey: .hardware) {
                self = .hardware(
                    deviceId: try h.decode(UUID.self, forKey: .deviceId),
                    accountFingerprint: try h.decode(String.self, forKey: .accountFingerprint),
                    accountXpub: try h.decode(String.self, forKey: .accountXpub)
                ); return
            }
        }
        let f = try decoder.container(keyedBy: FlatKeys.self)
        if (try? f.decode(String.self, forKey: .type)) == "hardware" {
            self = .hardware(
                deviceId: try f.decode(UUID.self, forKey: .deviceId),
                accountFingerprint: try f.decode(String.self, forKey: .accountFingerprint),
                accountXpub: try f.decode(String.self, forKey: .accountXpub)
            )
        } else {
            self = .software(account: (try? f.decode(UInt32.self, forKey: .account)) ?? 0)
        }
    }
}
