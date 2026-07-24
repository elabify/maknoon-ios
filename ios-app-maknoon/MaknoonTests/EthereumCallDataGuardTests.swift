import XCTest
@testable import Maknoon

/// Locks the blind-sign guard: a dApp-provided eth_sendTransaction whose calldata
/// is an ERC-20 transfer/transferFrom to the call target (the token contract
/// itself) must be flagged so the send path can refuse it, rather than
/// blind-signing tokens to the contract.
final class EthereumCallDataGuardTests: XCTestCase {
    let contract = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    let eoa = "0x1bd4e1b715213bd0c43d2623af4d77c46a6e5c2f"

    private func addr32(_ a: String) -> [UInt8] {
        let hex = a.hasPrefix("0x") ? String(a.dropFirst(2)) : a
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return [UInt8](repeating: 0, count: 12) + bytes
    }
    private func word(_ v: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 32); var x = v; var idx = 31
        while x > 0 { b[idx] = UInt8(x & 0xff); x >>= 8; idx -= 1 }
        return b
    }
    private func transfer(_ to: String, _ amt: UInt64) -> Data { Data([0xa9, 0x05, 0x9c, 0xbb] + addr32(to) + word(amt)) }
    private func transferFrom(_ from: String, _ to: String, _ amt: UInt64) -> Data { Data([0x23, 0xb8, 0x72, 0xdd] + addr32(from) + addr32(to) + word(amt)) }
    private func approve(_ spender: String, _ amt: UInt64) -> Data { Data([0x09, 0x5e, 0xa7, 0xb3] + addr32(spender) + word(amt)) }

    func testTransferToCalleeIsBlocked() {
        XCTAssertTrue(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: transfer(contract, 100)))
    }
    func testTransferToEOAIsAllowed() {
        XCTAssertFalse(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: transfer(eoa, 100)))
    }
    func testTransferFromToCalleeIsBlocked() {
        XCTAssertTrue(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: transferFrom(eoa, contract, 100)))
    }
    func testApproveToSelfIsNotBlocked() {
        // approve is a legitimate swap step and moves no tokens; never blocked.
        XCTAssertFalse(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: approve(contract, 100)))
    }
    func testEmptyOrShortDataIsNotBlocked() {
        XCTAssertFalse(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: Data()))
        XCTAssertFalse(EthereumCallDataDecoder.transferTargetsCallee(to: contract, data: Data([0xa9, 0x05, 0x9c, 0xbb])))
    }
}
