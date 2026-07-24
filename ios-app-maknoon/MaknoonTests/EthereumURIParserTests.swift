import XCTest
@testable import Maknoon

/// Locks the EIP-681 URI parser: a scanned token-payment QR
/// `ethereum:0x<TOKEN>@<chain>/transfer?address=0x<RECIPIENT>...` must resolve
/// the recipient from the `address=` param, NOT the URI target (the token
/// contract). Returning the target would build transfer(<contract>, amount) and
/// send the tokens to the contract instead of the recipient.
///
/// `kat` is the cross-platform contract: it is byte-identical to
/// android-app-elabify/app/src/test/resources/eip681-parse-kat.json. Keep the
/// two in sync.
final class EthereumURIParserTests: XCTestCase {

    static let kat = """
    [
      {"name":"token transfer with chain hint","uri":"ethereum:0x449b3317a6d1efb1bc3ba0700c9eaa4ffff4ae65@8453/transfer?address=0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f&uint256=14461320000","recipient":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","tokenContract":"0x449b3317a6d1efb1bc3ba0700c9eaa4ffff4ae65","amountBaseUnits":"14461320000"},
      {"name":"token transfer no chain hint","uri":"ethereum:0xaf88d065e77c8cc2239327c5edb3a432268e5831/transfer?address=0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f&uint256=200000000","recipient":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","tokenContract":"0xaf88d065e77c8cc2239327c5edb3a432268e5831","amountBaseUnits":"200000000"},
      {"name":"plain address","uri":"ethereum:0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","recipient":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","tokenContract":null,"amountBaseUnits":null},
      {"name":"native value with chain","uri":"ethereum:0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f@1?value=1000000000000000000","recipient":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","tokenContract":null,"amountBaseUnits":"1000000000000000000"},
      {"name":"bare address no scheme","uri":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","recipient":"0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f","tokenContract":null,"amountBaseUnits":null},
      {"name":"ens name","uri":"vitalik.eth","recipient":"vitalik.eth","tokenContract":null,"amountBaseUnits":null}
    ]
    """

    func testParserKAT() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(Self.kat.utf8)) as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let uri = c["uri"] as! String
            let parsed = EthereumURIParser.parse(uri)
            XCTAssertEqual(parsed.recipient, c["recipient"] as? String, "recipient mismatch: \(name)")
            XCTAssertEqual(parsed.tokenContract, c["tokenContract"] as? String, "tokenContract mismatch: \(name)")
            XCTAssertEqual(parsed.amountBaseUnits, c["amountBaseUnits"] as? String, "amount mismatch: \(name)")
        }
    }

    /// A token-transfer URI: the recipient must be the address= param, never the
    /// URI target (the token contract).
    func testTokenTransferURIResolvesAddressParamNotContract() {
        let uri = "ethereum:0x449b3317a6d1efb1bc3ba0700c9eaa4ffff4ae65@8453/transfer?address=0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f&uint256=14461320000"
        let parsed = EthereumURIParser.parse(uri)
        XCTAssertEqual(parsed.recipient.lowercased(), "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f")
        XCTAssertNotEqual(parsed.recipient.lowercased(), "0x449b3317a6d1efb1bc3ba0700c9eaa4ffff4ae65")
        XCTAssertEqual(parsed.tokenContract?.lowercased(), "0x449b3317a6d1efb1bc3ba0700c9eaa4ffff4ae65")
    }
}
