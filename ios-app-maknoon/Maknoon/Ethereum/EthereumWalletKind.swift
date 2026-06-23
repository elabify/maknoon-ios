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

    // Custom Codable: native Swift shape on encode; decode also accepts Android's
    // flat {"type":...} shape so an Android backup restores on iOS (ADR-0035).
    private enum CaseKey: String, CodingKey { case software, hardware }
    private enum SoftwareKeys: String, CodingKey { case account }
    private enum HardwareKeys: String, CodingKey { case deviceId, account, address }
    private enum FlatKeys: String, CodingKey { case type, account, deviceId, address }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .software(let account):
            var s = c.nestedContainer(keyedBy: SoftwareKeys.self, forKey: .software)
            try s.encode(account, forKey: .account)
        case .hardware(let deviceId, let account, let address):
            var h = c.nestedContainer(keyedBy: HardwareKeys.self, forKey: .hardware)
            try h.encode(deviceId, forKey: .deviceId)
            try h.encode(account, forKey: .account)
            try h.encode(address, forKey: .address)
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
                    account: (try? h.decode(UInt32.self, forKey: .account)) ?? 0,
                    address: try h.decode(String.self, forKey: .address)
                ); return
            }
        }
        let f = try decoder.container(keyedBy: FlatKeys.self)
        if (try? f.decode(String.self, forKey: .type)) == "hardware" {
            self = .hardware(
                deviceId: try f.decode(UUID.self, forKey: .deviceId),
                account: (try? f.decode(UInt32.self, forKey: .account)) ?? 0,
                address: try f.decode(String.self, forKey: .address)
            )
        } else {
            self = .software(account: (try? f.decode(UInt32.self, forKey: .account)) ?? 0)
        }
    }
}
