import XCTest
@testable import Maknoon

// Byte-identical corpus with the canonical payment-uri-kat.json in the Android
// app test resources; both platforms reduce BIP21 / Solana Pay / Tron URIs to
// the identical recipient. Keep the two in sync.
final class PaymentURIStripTests: XCTestCase {

    private static let katJSON = """
    {
      "_comment": "Cross-platform known-answer test for PaymentURIStrip: reduce a scanned/pasted BIP21 / Solana Pay / Tron payment URI to the bare recipient (the URI PATH). Rule: trim, drop a case-insensitive <scheme>: prefix, cut at the first '?'. The Solana Pay transaction-request form solana:https://host/... returns the URL (which then fails address validation loudly). iOS PaymentURIStrip.strip and Android PaymentURIStrip.strip must both satisfy this table. Keep byte-identical with the inline copy in iOS MaknoonTests/PaymentURIStripTests.swift.",
      "cases": [
        { "input": "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.1", "scheme": "bitcoin", "recipient": "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq" },
        { "input": "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", "scheme": "bitcoin", "recipient": "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq" },
        { "input": "  BITCOIN:bc1qAbCdEf  ", "scheme": "bitcoin", "recipient": "bc1qAbCdEf" },
        { "input": "solana:9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM?amount=1&spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "scheme": "solana", "recipient": "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM" },
        { "input": "solana:https://example.com/pay", "scheme": "solana", "recipient": "https://example.com/pay" },
        { "input": "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t?amount=5", "scheme": "tron", "recipient": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" },
        { "input": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "scheme": "tron", "recipient": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" }
      ]
    }
    """

    func testStripKAT() throws {
        let root = try JSONSerialization.jsonObject(with: Data(Self.katJSON.utf8)) as! [String: Any]
        for c in root["cases"] as! [[String: Any]] {
            let input = c["input"] as! String
            let scheme = c["scheme"] as! String
            let recipient = c["recipient"] as! String
            XCTAssertEqual(PaymentURIStrip.strip(input, scheme: scheme), recipient, "input=\(input)")
        }
    }
}
