// Maknoon's app-facing Bitcoin network enum. Maps onto BDK's `Network`
// type and to the BIP44 coin-type used for derivation paths
// (m/84'/<coin>'/<account>'/<chain>/<index>).
//
// `mainnet` uses coin-type 0, every other network (testnet3, testnet4,
// signet, regtest) uses coin-type 1 per BIP44.
//
// `regtest` is intentionally not user-selectable in the UI (it has no
// public block explorers and would only confuse a non-developer), but
// is kept here so the dev test harness can target it.

import Foundation
import BitcoinDevKit

enum BitcoinNetwork: String, Codable, CaseIterable, Sendable {
    case mainnet
    case testnet3
    case signet

    /// BIP44 coin type for derivation. Mainnet is 0', everything else
    /// is 1' per the spec.
    var coinType: UInt32 {
        switch self {
        case .mainnet: return 0
        case .testnet3, .signet: return 1
        }
    }

    /// Legacy P2PKH address version byte (base58check prefix). Mainnet is
    /// 0x00 ("1…"); testnet3 and signet share 0x6F ("m…"/"n…"). Used to bind
    /// a "Bitcoin Signed Message" (BIP-137) signature to the signing key's
    /// legacy address on the active network.
    var p2pkhVersion: UInt8 {
        switch self {
        case .mainnet: return 0x00
        case .testnet3, .signet: return 0x6F
        }
    }

    /// Bridge to BDK's Network enum.
    var bdk: Network {
        switch self {
        case .mainnet:  return .bitcoin
        case .testnet3: return .testnet
        case .signet:   return .signet
        }
    }

    var displayName: String {
        switch self {
        case .mainnet:  return "Mainnet"
        case .testnet3: return "Testnet3"
        case .signet:   return "Signet"
        }
    }

    /// Default Electrum server used when the user has not configured one.
    /// All three of these are public, free-to-use endpoints maintained
    /// by Blockstream (mainnet/testnet) and an established community
    /// operator (signet).
    var defaultElectrumURL: String {
        switch self {
        case .mainnet:  return "ssl://electrum.blockstream.info:50002"
        case .testnet3: return "ssl://electrum.blockstream.info:60002"
        case .signet:   return "ssl://mempool.space:60602"
        }
    }

    /// Default mempool.space (or Esplora-compatible) base URL used for
    /// fee recommendations and block-target visualisation.
    var defaultMempoolURL: String {
        switch self {
        case .mainnet:  return "https://mempool.space"
        case .testnet3: return "https://mempool.space/testnet"
        case .signet:   return "https://mempool.space/signet"
        }
    }

    /// Symbol shown next to amounts (BTC on mainnet, tBTC on testnets).
    var ticker: String {
        switch self {
        case .mainnet:  return "BTC"
        case .testnet3: return "tBTC"
        case .signet:   return "sBTC"
        }
    }
}
