import XCTest
@testable import Maknoon

/// Locks the token-send safety guard: a token send whose recipient is a contract
/// (its own contract, another installed token's contract, or any address with
/// bytecode) must be blocked. Native ETH sends to a contract are allowed.
final class EthereumSendGuardTests: XCTestCase {
    let token = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"       // a token contract
    let otherToken = "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8"  // a different token contract
    let eoa = "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f"

    func testBlocksSendingTokenToItsOwnContract() {
        XCTAssertTrue(EthereumSendGuard.blocksTokenSend(
            recipient: token, isTokenSend: true, selectedTokenContract: token,
            knownTokenContracts: [token], recipientHasCode: false))
    }

    func testBlocksSendingToAnotherKnownTokenContract() {
        // Recipient is a different installed token's contract.
        XCTAssertTrue(EthereumSendGuard.blocksTokenSend(
            recipient: otherToken, isTokenSend: true, selectedTokenContract: token,
            knownTokenContracts: [token, otherToken], recipientHasCode: false))
    }

    func testBlocksAnyContractViaGetCodeEvenIfUnknownToken() {
        XCTAssertTrue(EthereumSendGuard.blocksTokenSend(
            recipient: otherToken, isTokenSend: true, selectedTokenContract: token,
            knownTokenContracts: [token], recipientHasCode: true))
    }

    func testAllowsSendingTokenToAnEOA() {
        XCTAssertFalse(EthereumSendGuard.blocksTokenSend(
            recipient: eoa, isTokenSend: true, selectedTokenContract: token,
            knownTokenContracts: [token], recipientHasCode: false))
    }

    func testAllowsNativeEthToAContract() {
        XCTAssertFalse(EthereumSendGuard.blocksTokenSend(
            recipient: token, isTokenSend: false, selectedTokenContract: nil,
            knownTokenContracts: [token], recipientHasCode: true))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(EthereumSendGuard.blocksTokenSend(
            recipient: token.uppercased(), isTokenSend: true, selectedTokenContract: token,
            knownTokenContracts: [], recipientHasCode: false))
    }
}
