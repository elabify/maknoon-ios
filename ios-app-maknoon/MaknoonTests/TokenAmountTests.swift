import XCTest
@testable import Maknoon

// Locks the exact decimal -> base-unit scaling used by the Solana and Tron send
// paths. The corpus below is byte-identical to the canonical
// amount-scaling-kat.json in the Android app test resources; the Android tests
// drive parseSolToLamports / parseTokenToRaw / tronTokenToRaw against the same
// table so both platforms produce identical base units. Keep the two in sync.
final class TokenAmountTests: XCTestCase {

    private static let katJSON = """
    {
      "_comment": "Cross-platform known-answer test for converting a user-entered decimal token amount (whole units) to integer base units by scaling 10^decimals. Contract: exact string math, NO binary Double. Reject (expected=null) on malformed input, negatives, more than one dot, or more fractional digits than the token supports (never silently truncate sub-unit precision). iOS TokenAmount.baseUnits and Android parseTokenToRaw / parseSolToLamports / tronTokenToRaw must all satisfy this table. Keep byte-identical with the inline copy in iOS MaknoonTests/TokenAmountTests.swift.",
      "cases": [
        { "amount": "1443.927713", "decimals": 6, "expected": "1443927713" },
        { "amount": "1.123456789012345678", "decimals": 18, "expected": "1123456789012345678" },
        { "amount": "0", "decimals": 6, "expected": "0" },
        { "amount": "0.000001", "decimals": 6, "expected": "1" },
        { "amount": "10", "decimals": 9, "expected": "10000000000" },
        { "amount": "0.5", "decimals": 9, "expected": "500000000" },
        { "amount": "123.45", "decimals": 2, "expected": "12345" },
        { "amount": "5", "decimals": 0, "expected": "5" },
        { "amount": "100.000000", "decimals": 6, "expected": "100000000" },
        { "amount": "  12.5  ", "decimals": 2, "expected": "1250" },
        { "amount": "1.5", "decimals": 0, "expected": null },
        { "amount": "0.1234567", "decimals": 6, "expected": null },
        { "amount": "", "decimals": 6, "expected": null },
        { "amount": "abc", "decimals": 6, "expected": null },
        { "amount": "-5", "decimals": 6, "expected": null },
        { "amount": "1.2.3", "decimals": 6, "expected": null }
      ]
    }
    """

    private struct Case {
        let amount: String
        let decimals: Int
        let expected: String?
    }

    private func loadCases() throws -> [Case] {
        let data = Data(Self.katJSON.utf8)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let arr = root["cases"] as! [[String: Any]]
        return arr.map {
            Case(amount: $0["amount"] as! String,
                 decimals: $0["decimals"] as! Int,
                 expected: $0["expected"] as? String)
        }
    }

    func testAmountScalingKAT() throws {
        for c in try loadCases() {
            let got = TokenAmount.baseUnits(c.amount, decimals: c.decimals)
            XCTAssertEqual(got, c.expected,
                           "amount=\(c.amount) decimals=\(c.decimals)")
        }
    }

    // Red-proof: the previous binary-Double path (Double(amount) * pow(10,
    // decimals), rounded) produces the WRONG base units for a high-decimal /
    // high-precision amount that the exact path gets right. This is the class
    // of bug the exact scaler removes.
    func testOldDoublePathWasWrongForHighPrecision() {
        let amount = "1.123456789012345678"
        let decimals = 18
        let exact = TokenAmount.baseUnits(amount, decimals: decimals)
        XCTAssertEqual(exact, "1123456789012345678")

        let oldDouble = UInt64((Double(amount)! * pow(10.0, Double(decimals))).rounded())
        XCTAssertNotEqual(String(oldDouble), exact,
                          "the old Double scaling should differ from the exact value")
    }
}
