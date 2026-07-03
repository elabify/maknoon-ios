// CryptoProvider for Reown (ADR-0049). Reown's Sign client needs keccak256 +
// secp256k1 public-key recovery (used by its SIWE / one-click-auth path). We
// back both with Trust Wallet Core, which the app already links, rather than
// pulling Web3.swift + CryptoSwift like the reown example does.

import Foundation
import ReownWalletKit
import WalletCore

struct WCCryptoProvider: CryptoProvider {
    // Qualify the module: WalletCore also defines an `EthereumSignature`, so the
    // bare name resolves to the wrong type and breaks protocol conformance.
    func recoverPubKey(signature: WalletConnectSigner.EthereumSignature, message: Data) throws -> Data {
        // Reassemble the 65-byte r || s || v signature WalletCore expects. `v`
        // is the recovery id (0/1); EthereumSignature already normalizes the
        // 27/31/35 offsets away in its serialized initializer.
        var serialized = Data()
        serialized.append(contentsOf: signature.r)
        serialized.append(contentsOf: signature.s)
        serialized.append(signature.v)
        guard let pub = PublicKey.recover(signature: serialized, message: message) else {
            throw NSError(domain: "WCCryptoProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "secp256k1 recovery failed"])
        }
        // Return the 64-byte uncompressed X || Y (drop the 0x04 prefix), the
        // raw-public-key form the recovering caller hashes to an address.
        let raw = pub.uncompressed.data
        return raw.count == 65 ? raw.dropFirst() : raw
    }

    func keccak256(_ data: Data) -> Data {
        Hash.keccak256(data: data)
    }
}
