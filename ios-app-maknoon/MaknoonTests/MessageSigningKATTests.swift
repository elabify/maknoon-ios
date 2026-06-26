// Cross-platform message-signing known-answer tests (KAT).
//
// Asserts the SAME frozen corpus the Rust core and Android assert, so all
// implementations (here: WalletCore + the shared Rust BTC core via the iOS app
// code paths) produce byte-identical addresses + signatures. BTC = standard
// "Bitcoin Signed Message" (BIP-137, Electrum-compatible) across legacy / nested
// / native-segwit and mainnet / testnet3 / signet; ETH = EIP-191 personal_sign.
//
// The `kat` string below is a copy of the canonical corpus at
// ledger-btc-rs/ledger-btc-core/test-vectors/message-signing-kat.json
// (regenerate via `cargo test -p ledger-btc-core --test kat_gen -- --ignored
// --nocapture`). Keep it byte-identical to that file.

import XCTest
@testable import Maknoon

final class MessageSigningKATTests: XCTestCase {

    private func corpus() throws -> [String: Any] {
        let data = Self.kat.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func scriptType(_ s: String) -> BIP32Path.BitcoinScriptType {
        switch s {
        case "legacy": return .legacy
        case "nestedSegwit": return .nestedSegwit
        case "nativeSegwit": return .nativeSegwit
        default: fatalError("unknown scriptType \(s)")
        }
    }

    private func network(_ s: String) -> BitcoinNetwork {
        switch s {
        case "mainnet": return .mainnet
        case "testnet3": return .testnet3
        case "signet": return .signet
        default: fatalError("unknown network \(s)")
        }
    }

    func testBitcoinKATCorpusMatches() throws {
        let c = try corpus()
        let mnemonic = c["mnemonic"] as! String
        let vectors = c["bitcoin"] as! [[String: Any]]
        XCTAssertFalse(vectors.isEmpty)
        for v in vectors {
            let path = v["path"] as! String
            let message = v["message"] as! String
            let ty = scriptType(v["scriptType"] as! String)
            let net = network(v["network"] as! String)
            let wantAddr = v["expectedAddress"] as! String
            let wantSig = v["expectedSignature"] as! String

            let result = try BitcoinMessageSigning.sign(
                message: message,
                derivationPath: path,
                scriptType: ty,
                network: net,
                mnemonic: mnemonic,
                passphrase: ""
            )
            XCTAssertEqual(result.address, wantAddr, "BTC address mismatch at \(path)/\(net)")
            XCTAssertEqual(result.signature, wantSig, "BTC signature mismatch at \(path)/\(net)")
            XCTAssertTrue(
                BitcoinMessageSigning.verify(address: wantAddr, message: message, signature: wantSig),
                "BTC verify failed at \(path)/\(net)"
            )
        }
    }

    func testEthereumKATCorpusMatches() throws {
        let c = try corpus()
        let mnemonic = c["mnemonic"] as! String
        let eth = c["ethereum"] as! [String: Any]
        let message = eth["message"] as! String
        let wantAddr = eth["expectedAddress"] as! String
        let wantSig = eth["expectedSignature"] as! String

        let sig = try EthereumDescriptors.signPersonalMessage(
            mnemonic: mnemonic,
            passphrase: "",
            account: 0,
            message: Data(message.utf8)
        )
        XCTAssertEqual(sig.lowercased(), wantSig.lowercased(), "ETH signature mismatch")
        XCTAssertTrue(
            EthereumMessageSigning.verify(address: wantAddr, message: message, signature: wantSig),
            "ETH verify failed"
        )
        let recovered = EthereumMessageSigning.recoverAddress(message: message, signature: wantSig)
        XCTAssertEqual(recovered?.lowercased(), wantAddr.lowercased(), "ETH recover mismatch")
    }

    func testTronKATCorpusMatches() throws {
        let c = try corpus()
        let mnemonic = c["mnemonic"] as! String
        let tron = c["tron"] as! [String: Any]
        let message = tron["message"] as! String
        let wantAddr = tron["expectedAddress"] as! String
        let wantSig = tron["expectedSignature"] as! String

        let result = try TronMessageSigning.sign(
            message: message,
            account: 0,
            mnemonic: mnemonic,
            passphrase: ""
        )
        XCTAssertEqual(result.address, wantAddr, "Tron address mismatch")
        XCTAssertEqual(result.signature.lowercased(), wantSig.lowercased(), "Tron signature mismatch")
        XCTAssertTrue(
            TronMessageSigning.verify(address: wantAddr, message: message, signature: wantSig),
            "Tron verify failed"
        )
    }

    func testSolanaKATCorpusMatches() throws {
        let c = try corpus()
        let mnemonic = c["mnemonic"] as! String
        let sol = c["solana"] as! [String: Any]
        let message = sol["message"] as! String
        let wantAddr = sol["expectedAddress"] as! String
        let wantSig = sol["expectedSignature"] as! String

        // Solana OCMS: ed25519 (base58 address + base58 signature). This also
        // exercises WalletCore's SLIP-0010 ed25519 derivation matching the Rust
        // core + Ledger/Trezor on-device.
        let result = try SolanaMessageSigning.sign(
            message: message,
            account: 0,
            mnemonic: mnemonic,
            passphrase: ""
        )
        XCTAssertEqual(result.address, wantAddr, "Solana address mismatch")
        XCTAssertEqual(result.signature, wantSig, "Solana signature mismatch")
        XCTAssertTrue(
            SolanaMessageSigning.verify(address: wantAddr, message: message, signature: wantSig),
            "Solana verify failed"
        )
    }

    // Copy of ledger-btc-rs/ledger-btc-core/test-vectors/message-signing-kat.json
    // (+ the Tron vector from ledger-tron-core/test-vectors/tron-message-signing-kat.json)
    private static let kat = """
    {
      "mnemonic": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
      "seedHex": "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4",
      "bitcoin": [
        { "scriptType": "legacy", "network": "mainnet", "path": "m/44'/0'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA", "expectedSignature": "IKb48tGJtoDQNTQF8zOQMvJFBjBclP6HozblDcZmSwTzaN5a85GlRoYQLZs3bsRDp19uxZC67yyDsmUFtBvCjas=" },
        { "scriptType": "legacy", "network": "testnet3", "path": "m/44'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "mkpZhYtJu2r87Js3pDiWJDmPte2NRZ8bJV", "expectedSignature": "ILPJGv5cA4+dbSEYyG0HImFXpDNePy0m/Y+HYyZt1NXtTLDTTiRduxea3oGV02BNDQfKAbrrUu6EOzdAmRjINd4=" },
        { "scriptType": "legacy", "network": "signet", "path": "m/44'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "mkpZhYtJu2r87Js3pDiWJDmPte2NRZ8bJV", "expectedSignature": "ILPJGv5cA4+dbSEYyG0HImFXpDNePy0m/Y+HYyZt1NXtTLDTTiRduxea3oGV02BNDQfKAbrrUu6EOzdAmRjINd4=" },
        { "scriptType": "nestedSegwit", "network": "mainnet", "path": "m/49'/0'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf", "expectedSignature": "Izrp4l2j6808a/bQx+g38/Lqh95ePdfY8HkIc7Du3QlsVzsTu6nXcZtfraxsU8WSGvV4ruwFeRvfVUcau9mWIUg=" },
        { "scriptType": "nestedSegwit", "network": "testnet3", "path": "m/49'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "2Mww8dCYPUpKHofjgcXcBCEGmniw9CoaiD2", "expectedSignature": "JM636Rfgu/qcDayN2HCNYc38fS84c7PLtaguATqOv+ncLypJk6ekbwL6+2RYGQ5yREjrxopoj5SvjT97DUqe4Yw=" },
        { "scriptType": "nestedSegwit", "network": "signet", "path": "m/49'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "2Mww8dCYPUpKHofjgcXcBCEGmniw9CoaiD2", "expectedSignature": "JM636Rfgu/qcDayN2HCNYc38fS84c7PLtaguATqOv+ncLypJk6ekbwL6+2RYGQ5yREjrxopoj5SvjT97DUqe4Yw=" },
        { "scriptType": "nativeSegwit", "network": "mainnet", "path": "m/84'/0'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", "expectedSignature": "KAfvVQIHilPUf2NvB0C+0svA7/plCTnpPxPzA/RzJ3ccWGUVFjqP1eeIqW8FvtxrKz1WlUnBDXszIJNn972+HWc=" },
        { "scriptType": "nativeSegwit", "network": "testnet3", "path": "m/84'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl", "expectedSignature": "J5P2r9aVuqLpfzDHQ5i3uOQwsiKpbL/75ETMCE8TT7vlC/2gRjMDSxfSMAO8r2l7AfIR0J0Z0FeFnkEN3r2Fjvk=" },
        { "scriptType": "nativeSegwit", "network": "signet", "path": "m/84'/1'/0'/0/0", "message": "Maknoon BIP-137 KAT v1", "expectedAddress": "tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl", "expectedSignature": "J5P2r9aVuqLpfzDHQ5i3uOQwsiKpbL/75ETMCE8TT7vlC/2gRjMDSxfSMAO8r2l7AfIR0J0Z0FeFnkEN3r2Fjvk=" }
      ],
      "ethereum": {
        "path": "m/44'/60'/0'/0/0",
        "message": "Maknoon EIP-191 KAT v1",
        "expectedAddress": "0x9858effd232b4033e47d90003d41ec34ecaeda94",
        "expectedSignature": "0x05f931462fa127cf210566731eb75621d27c22d00ec4e8095ed5854be8b569e5283452c1af3090888070bd90ff5725a2ff0eb6bf2bd96814b888ae50ccc1e7a51c"
      },
      "tron": {
        "path": "m/44'/195'/0'/0/0",
        "message": "Maknoon TIP-191 KAT v1",
        "expectedAddress": "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
        "expectedSignature": "0x662b8557ae98615a73b7335788c141933b8faf76159ae7d4ec473b6308c2f8e81f28f0902832bd72776991f5e8c1bc28f87ab1ea6cc6a6dfd3ff138c072d59731c"
      },
      "solana": {
        "path": "m/44'/501'/0'/0'",
        "message": "Maknoon Solana OCMS KAT v1",
        "expectedAddress": "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk",
        "expectedSignature": "4CTqqGJKWv1BtBThe7vXLreNZMbcFQnLt2DLWaFj7QD5Yy2cgNxqszFmP9yVjETNEAgp1Brb7ePU4EqEiupwFWVd"
      }
    }
    """
}
