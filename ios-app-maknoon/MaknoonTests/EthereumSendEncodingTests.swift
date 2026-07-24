import XCTest
@testable import Maknoon

/// Locks the ERC-20 encode boundary: the transfer calldata must carry the real
/// RECIPIENT (not the token contract), the tx `value` must be zero for a token
/// send (the amount lives in the calldata), and a parsed token URI must encode
/// to the real recipient end to end.
final class EthereumSendEncodingTests: XCTestCase {
    let contract = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    let recipient = "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f"

    /// Address bytes are the last 20 of the first 32-byte word after the 4-byte
    /// selector: [4+12 ..< 4+32) == [16 ..< 36).
    private func encodedAddress(_ calldata: Data) -> String {
        "0x" + calldata[16..<36].map { String(format: "%02x", $0) }.joined()
    }

    func testTransferDataCarriesRecipientNotContract() throws {
        let amount = EthereumWeiValue(uint64: 200_000_000) // 200 USDC (6dp)
        let data = try XCTUnwrap(EthereumABI.transferData(to: recipient, amount: amount))
        XCTAssertEqual(data.count, 4 + 32 + 32)
        XCTAssertEqual(Array(data.prefix(4)), [0xa9, 0x05, 0x9c, 0xbb]) // transfer(address,uint256)
        XCTAssertEqual(encodedAddress(data).lowercased(), recipient.lowercased())
        XCTAssertNotEqual(encodedAddress(data).lowercased(), contract.lowercased())
    }

    func testEncoderZeroValueAndRecipientCalldataForERC20() {
        let amount = EthereumWeiValue(uint64: 200_000_000)
        let plan = EthereumTxPlan(
            chainId: 42161, nonce: 0, toAddress: contract, value: amount,
            gasLimit: 90_000, maxFeePerGas: EthereumWeiValue(uint64: 1_000_000_000),
            maxPriorityFeePerGas: EthereumWeiValue(uint64: 100_000_000),
            payload: .erc20(recipient: recipient))
        // A token send carries ZERO native value; the amount is in the calldata.
        XCTAssertEqual(EthereumTxEncoder.ethValueWei(for: plan).hex, EthereumWeiValue.zero.hex)
        let cd = EthereumTxEncoder.callData(for: plan)
        XCTAssertEqual(cd, EthereumABI.transferData(to: recipient, amount: amount))
        XCTAssertEqual(encodedAddress(cd).lowercased(), recipient.lowercased())
    }

    func testParsedTokenURIEncodesRealRecipientEndToEnd() throws {
        // A token-transfer URI (target = token contract, recipient in address=).
        let uri = "ethereum:\(contract)@42161/transfer?address=\(recipient)&uint256=200000000"
        let parsed = EthereumURIParser.parse(uri)
        let raw = try XCTUnwrap(parsed.amountBaseUnits.flatMap { UInt64($0) })
        let cd = try XCTUnwrap(EthereumABI.transferData(to: parsed.recipient, amount: EthereumWeiValue(uint64: raw)))
        XCTAssertEqual(encodedAddress(cd).lowercased(), recipient.lowercased())
        XCTAssertNotEqual(encodedAddress(cd).lowercased(), contract.lowercased())
    }

    func testNativePlanHasEmptyCalldataAndKeepsValue() {
        let amount = EthereumWeiValue(uint64: 1_000_000)
        let plan = EthereumTxPlan(
            chainId: 1, nonce: 0, toAddress: recipient, value: amount,
            gasLimit: 21_000, maxFeePerGas: EthereumWeiValue(uint64: 1),
            maxPriorityFeePerGas: EthereumWeiValue(uint64: 1), payload: .native)
        XCTAssertEqual(EthereumTxEncoder.callData(for: plan).count, 0)
        XCTAssertEqual(EthereumTxEncoder.ethValueWei(for: plan).hex, amount.hex)
    }
}
