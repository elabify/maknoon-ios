// Cross-platform wallet-derivation known-answer test (KAT), ADR-0064.
//
// Proves software-wallet address derivation folds the identity BIP-39
// passphrase identically across iOS + Android for all four networks. iOS is
// the canonical reference these values were generated from; this test guards
// against a regression on the reference. Android asserts the SAME corpus
// (androidTest/assets/wallet-derivation-kat.json) built from a real
// IdentitySandwich, which is where a passphrase-dropping derivation would
// surface. The `kat` string below MUST stay byte-identical to that asset.
//
// iOS derives via the pure (mnemonic, passphrase) entry points rather than a
// sandwich: building a sandwich here would call IdentitySandwich.buildAndPersist
// (KeyStore.wipeAll + Secure-Enclave writes), which is destructive on a device.
// The frozen address is a function of (mnemonic, passphrase, path), so the pure
// path proves equality to the same values Android's sandwich path must produce.

import XCTest
@testable import Maknoon

final class WalletDerivationKATTests: XCTestCase {

    private func corpus() throws -> [String: Any] {
        let data = Self.kat.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testWalletDerivationKATCorpusMatches() throws {
        let c = try corpus()
        let mnemonic = c["mnemonic"] as! String

        // The mnemonic must be BIP-39 of the declared entropy (32 zero bytes).
        let entropyHex = c["entropyHex"] as! String
        XCTAssertEqual(entropyHex, String(repeating: "0", count: 64), "fixture entropy is 32 zero bytes")
        XCTAssertEqual(BIP39.mnemonicFromSeed(Data(count: 32)).joined(separator: " "), mnemonic,
                       "mnemonic is not BIP-39(entropyHex)")

        let vectors = c["vectors"] as! [[String: Any]]
        XCTAssertFalse(vectors.isEmpty)
        let msg = "x"

        for v in vectors {
            let passphrase = v["passphrase"] as! String
            let account = UInt32(v["account"] as! Int)
            let label = "pass=\"\(passphrase)\" account=\(account)"

            // Ethereum: pure personal_sign + keyless recover of the signer.
            let ethSig = try EthereumDescriptors.signPersonalMessage(
                mnemonic: mnemonic, passphrase: passphrase, account: account, message: Data(msg.utf8))
            let ethAddr = EthereumMessageSigning.recoverAddress(message: msg, signature: ethSig)
            XCTAssertEqual(ethAddr?.lowercased(), (v["eth"] as! String).lowercased(), "ETH mismatch \(label)")

            // Solana: pure sign returns the bound base58 address.
            let sol = try SolanaMessageSigning.sign(
                message: msg, account: account, mnemonic: mnemonic, passphrase: passphrase)
            XCTAssertEqual(sol.address, v["sol"] as! String, "SOL mismatch \(label)")

            // Tron: pure sign returns the bound T-address.
            let tron = try TronMessageSigning.sign(
                message: msg, account: account, mnemonic: mnemonic, passphrase: passphrase)
            XCTAssertEqual(tron.address, v["tron"] as! String, "TRON mismatch \(label)")

            // Bitcoin: BIP84 native-segwit mainnet receive address (account 0 only).
            if let wantBtc = v["btc"] as? String {
                let btc = try BitcoinMessageSigning.sign(
                    message: msg, derivationPath: "m/84'/0'/\(account)'/0/0",
                    scriptType: .nativeSegwit, network: .mainnet,
                    mnemonic: mnemonic, passphrase: passphrase)
                XCTAssertEqual(btc.address, wantBtc, "BTC mismatch \(label)")
            }
        }
    }

    // Byte-identical copy of
    // the Musnad Android SDK
    private static let kat = """
    {
      "entropyHex": "0000000000000000000000000000000000000000000000000000000000000000",
      "mnemonic": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
      "vectors": [
        { "passphrase": "", "account": 0, "eth": "0xF278cF59F82eDcf871d630F28EcC8056f25C1cdb", "sol": "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx", "tron": "TEfhiqsW1SdN44DeHrAWVmbyr8ZbvChrtS", "btc": "bc1qzmtrqsfuaf6l6kkcsseumq26ukaphfj9skkug6" },
        { "passphrase": "", "account": 1, "eth": "0x94142B4f665316D3304C3a595ec83aC9C8046598", "sol": "5frqxtii9LeGq2bz3dSNokvZcEooF483MzeU24JrhcTA", "tron": "TUeQNhjUcQwjB2epWHip6E6UJ7uhUJLUWV" },
        { "passphrase": "TREZOR", "account": 0, "eth": "0x2b5D7A0E9d3EC34D629D07c6bDE5c41fb613c655", "sol": "FqmSsV7HEX93rzs3pTGAdxhSuvdk1bay6VQQaTPBGuUo", "tron": "TUxz2kwj8gAZocscfj8cxseDdv4M2apZZz", "btc": "bc1q8ee9jp2ga509lae7xdcu88j0elzlyv0khhryaq" },
        { "passphrase": "TREZOR", "account": 1, "eth": "0x7aBb15A014B82491c56E7fA27C88314Fc303B471", "sol": "7qb6VxCcazkFim8batGkdwVhQsv8RdT9LJy1sbyLoSEQ", "tron": "TE6fHnNAUikRCv9deWskVU1Xrf9FL14Dqr" }
      ]
    }
    """
}
