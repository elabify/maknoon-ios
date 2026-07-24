import XCTest
@testable import Maknoon

// Locks the cross-network address classifier (byte-identical corpus with the
// canonical address-network-kat.json in the Android app test resources) plus
// the mismatch rule and EIP-55 checksum validation of pasted Ethereum input.
final class AddressNetworkGuardTests: XCTestCase {

    private static let katJSON = """
    {
      "_comment": "Cross-platform known-answer test for AddressNetworkGuard.detect: classify a recipient address by unambiguous prefix/shape so a send screen can block an address from the wrong network. Conservative: only EVM (0x + 40 hex), Tron (T + 33 base58), and Bitcoin bech32 (bc1/tb1/bcrt1) are recognised; a bare base58 string (Solana or legacy Bitcoin, which overlap) is left unclassified (null) so no false wrong-network warning fires. iOS AddressNetworkGuard.detect and Android AddressNetworkGuard.detect must both satisfy this table. Keep byte-identical with the inline copy in iOS MaknoonTests/AddressNetworkGuardTests.swift.",
      "cases": [
        { "address": "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f", "family": "ethereum" },
        { "address": "0xAF88D065E77C8CC2239327C5EDB3A432268E5831", "family": "ethereum" },
        { "address": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "family": "tron" },
        { "address": "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", "family": "bitcoin" },
        { "address": "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "family": "bitcoin" },
        { "address": "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", "family": null },
        { "address": "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", "family": null },
        { "address": "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2", "family": null },
        { "address": "hello", "family": null },
        { "address": "", "family": null }
      ]
    }
    """

    func testDetectKAT() throws {
        let root = try JSONSerialization.jsonObject(with: Data(Self.katJSON.utf8)) as! [String: Any]
        for c in root["cases"] as! [[String: Any]] {
            let address = c["address"] as! String
            let expected = c["family"] as? String
            XCTAssertEqual(AddressNetworkGuard.detect(address)?.rawValue, expected, "address=\(address)")
        }
    }

    func testCrossNetworkMismatch() {
        // A Bitcoin bech32 pasted into an Ethereum send is a mismatch.
        XCTAssertEqual(
            AddressNetworkGuard.crossNetworkMismatch("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", current: .ethereum),
            .bitcoin)
        // A correct Ethereum address on the Ethereum screen is not a mismatch.
        XCTAssertNil(
            AddressNetworkGuard.crossNetworkMismatch("0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f", current: .ethereum))
        // On the Solana screen (current = nil), any recognised family is a mismatch.
        XCTAssertEqual(
            AddressNetworkGuard.crossNetworkMismatch("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", current: nil),
            .tron)
        // An unclassified (bare base58, could be Solana) address is never a mismatch.
        XCTAssertNil(
            AddressNetworkGuard.crossNetworkMismatch("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", current: nil))
    }

    // EIP-55: all-lower and all-upper carry no checksum (accepted); a mixed-case
    // address must match the checksum exactly or it is rejected. Uses native
    // keccak (available in the app-hosted test target).
    func testEIP55ChecksumValidation() {
        let lower = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        let correct = EIP55.checksum(lower) // canonical mixed-case
        XCTAssertTrue(EIP55.passesChecksum(lower), "all-lower is accepted")
        XCTAssertTrue(EIP55.passesChecksum(lower.uppercased().replacingOccurrences(of: "0X", with: "0x")),
                      "all-upper is accepted")
        XCTAssertTrue(EIP55.passesChecksum(correct), "the canonical checksum passes")

        // Flip the case of one letter in the address BODY (past "0x") -> mixed
        // case that no longer matches the checksum -> rejected.
        var bodyChars = Array(correct.dropFirst(2))
        for (i, ch) in bodyChars.enumerated() where ch.isLetter {
            bodyChars[i] = ch.isUppercase ? Character(ch.lowercased()) : Character(ch.uppercased())
            break
        }
        XCTAssertFalse(EIP55.passesChecksum("0x" + String(bodyChars)),
                       "a bad-checksum mixed-case address is rejected")
        XCTAssertFalse(EIP55.passesChecksum("0x123"), "wrong length is rejected")
    }
}
