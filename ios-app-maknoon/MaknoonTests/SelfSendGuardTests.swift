import XCTest
@testable import Maknoon

final class SelfSendGuardTests: XCTestCase {
    func testExactMatchBase58() {
        let own = ["9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"]
        XCTAssertTrue(SelfSendGuard.isSelfSend(recipient: "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM", ownAddresses: own, caseInsensitive: false))
        XCTAssertTrue(SelfSendGuard.isSelfSend(recipient: "  9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM  ", ownAddresses: own, caseInsensitive: false))
        XCTAssertFalse(SelfSendGuard.isSelfSend(recipient: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", ownAddresses: own, caseInsensitive: false))
    }

    func testCaseInsensitiveHexForEthereum() {
        let own = ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"]
        // A lowercased paste of the same address is still a self-send.
        XCTAssertTrue(SelfSendGuard.isSelfSend(recipient: "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed", ownAddresses: own, caseInsensitive: true))
        XCTAssertFalse(SelfSendGuard.isSelfSend(recipient: "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f", ownAddresses: own, caseInsensitive: true))
    }

    func testEmptyRecipientIsNotSelfSend() {
        XCTAssertFalse(SelfSendGuard.isSelfSend(recipient: "", ownAddresses: ["abc"], caseInsensitive: false))
        XCTAssertFalse(SelfSendGuard.isSelfSend(recipient: "abc", ownAddresses: [], caseInsensitive: false))
    }
}
