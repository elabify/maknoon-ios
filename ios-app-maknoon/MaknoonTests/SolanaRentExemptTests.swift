import XCTest
@testable import Maknoon

// Locks the rent-exempt decision branches for a native SOL transfer, including
// the deliberate fail-open behaviour (an RPC error defaults recipientExists to
// true, so it never blocks). Mirrors Android RentExemptTest.
final class SolanaRentExemptTests: XCTestCase {
    private let min = SolanaWallet.rentExemptMinimumLamports // 890_880

    func testFundedAboveMinimumNeverBlocks() {
        XCTAssertFalse(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: min, recipientExists: false))
        XCTAssertFalse(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: min + 1, recipientExists: false))
        XCTAssertFalse(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: 2_000_000, recipientExists: false))
    }

    func testNewAccountBelowMinimumBlocks() {
        XCTAssertTrue(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: 1, recipientExists: false))
        XCTAssertTrue(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: min - 1, recipientExists: false))
    }

    func testExistingAccountBelowMinimumDoesNotBlock() {
        XCTAssertFalse(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: 1, recipientExists: true))
    }

    // An RPC probe error defaults recipientExists to true -> never blocks.
    func testFailOpenDoesNotBlock() {
        XCTAssertFalse(SolanaWallet.rentExemptBlocksNativeTransfer(lamports: 1, recipientExists: true))
    }
}
