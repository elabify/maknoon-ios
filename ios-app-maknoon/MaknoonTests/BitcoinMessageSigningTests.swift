// Known-answer + round-trip tests for the legacy "Bitcoin Signed
// Message" implementation in BitcoinMessageSigning. Exercises the real
// app code path (the pure, sandbox-free overloads), which is the same
// Trust Wallet Core primitive the Sign/Verify sheets call.

import XCTest
@testable import Maknoon

final class BitcoinMessageSigningTests: XCTestCase {

    // Standard BIP39 test vector. Valid mnemonic, no passphrase.
    private let testMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    /// Trust Wallet Core's own known-answer vector for verifyMessage,
    /// run through our wrapper to prove the primitive works in this
    /// build (matches WalletCore's BitcoinTests.testBitcoinMessageSigner).
    func testVerifyKnownAnswer() {
        let ok = BitcoinMessageSigning.verify(
            address: "1B8Qea79tsxmn4dTiKKRVvsJpHwL2fMQnr",
            message: "test signature",
            signature: "H+3L5IbSVcejp4S2VwLXCxLEMQAWDvKbE8lQyq0ocdvyM1aoEudkzN/S/qLI3vnNOFY6V13BXWSFrPr3OjGa5Dk="
        )
        XCTAssertTrue(ok, "WalletCore known-answer vector should verify")
    }

    func testVerifyRejectsWrongMessage() {
        let ok = BitcoinMessageSigning.verify(
            address: "1B8Qea79tsxmn4dTiKKRVvsJpHwL2fMQnr",
            message: "a different message",
            signature: "H+3L5IbSVcejp4S2VwLXCxLEMQAWDvKbE8lQyq0ocdvyM1aoEudkzN/S/qLI3vnNOFY6V13BXWSFrPr3OjGa5Dk="
        )
        XCTAssertFalse(ok, "verification must fail when the message does not match")
    }

    func testSignThenVerifyRoundTripMainnet() throws {
        let message = "Maknoon mainnet message-signing round trip"
        let (address, signature) = try BitcoinMessageSigning.sign(
            message: message,
            mnemonic: testMnemonic,
            passphrase: "",
            account: 0,
            network: .mainnet
        )
        XCTAssertTrue(address.hasPrefix("1"), "mainnet legacy P2PKH address starts with 1, got \(address)")
        XCTAssertFalse(signature.isEmpty)
        XCTAssertTrue(
            BitcoinMessageSigning.verify(address: address, message: message, signature: signature),
            "a freshly produced signature must verify against its own address + message"
        )
        XCTAssertFalse(
            BitcoinMessageSigning.verify(address: address, message: message + " tampered", signature: signature),
            "verification must fail for a tampered message"
        )
    }

    /// WalletCore's BitcoinMessageSigner is mainnet-only, so signing a
    /// testnet wallet is a clear capability boundary, not a silent
    /// empty signature.
    func testSignOnTestnetThrowsNetworkUnsupported() {
        XCTAssertThrowsError(
            try BitcoinMessageSigning.sign(
                message: "should not sign",
                mnemonic: testMnemonic,
                passphrase: "",
                account: 0,
                network: .testnet3
            )
        ) { error in
            guard case BitcoinMessageSigningError.networkUnsupported = error else {
                return XCTFail("expected networkUnsupported, got \(error)")
            }
        }
    }

    /// A passphrase changes the derived key, so the same mnemonic with a
    /// passphrase signs from a different address than without one.
    func testPassphraseChangesAddress() throws {
        let message = "passphrase isolation"
        let (addrNoPass, _) = try BitcoinMessageSigning.sign(
            message: message, mnemonic: testMnemonic, passphrase: "", account: 0, network: .mainnet
        )
        let (addrWithPass, _) = try BitcoinMessageSigning.sign(
            message: message, mnemonic: testMnemonic, passphrase: "TREZOR", account: 0, network: .mainnet
        )
        XCTAssertNotEqual(addrNoPass, addrWithPass)
    }
}
