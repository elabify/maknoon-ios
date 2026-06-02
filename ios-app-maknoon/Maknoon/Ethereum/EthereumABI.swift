// Thin wrapper around Trust Wallet Core's `EthereumAbiFunction` for
// the three off-chain reads we need to support ERC-20 tokens:
//   • balanceOf(address) → uint256
//   • symbol() → string
//   • decimals() → uint8
//
// All three use the same pattern: build an `EthereumAbiFunction`,
// add params, call `EthereumAbi.encode(fn:)` for the request bytes
// (sent via `eth_call`), and parse the response bytes manually
// because TWC's `decodeOutput(fn:encoded:)` mutates an existing
// function instance which is awkward to thread through async code.

import Foundation
import WalletCore

enum EthereumABI {

    /// Build call data for `balanceOf(address)`. Recipient is encoded
    /// as a 20-byte big-endian address; selector is added by TWC.
    static func balanceOfData(holderAddress: String) -> Data? {
        guard let holder = hexToBytes(holderAddress) else { return nil }
        let fn = EthereumAbiFunction(name: "balanceOf")
        fn.addParamAddress(val: holder, isOutput: false)
        fn.addParamUInt256(val: Data(), isOutput: true)
        return EthereumAbi.encode(fn: fn)
    }

    /// Build call data for `symbol()`. No inputs; one dynamic-string
    /// output we decode manually on the response side.
    static func symbolData() -> Data {
        let fn = EthereumAbiFunction(name: "symbol")
        fn.addParamString(val: "", isOutput: true)
        return EthereumAbi.encode(fn: fn)
    }

    /// Build call data for `decimals()`.
    static func decimalsData() -> Data {
        let fn = EthereumAbiFunction(name: "decimals")
        fn.addParamUInt8(val: 0, isOutput: true)
        return EthereumAbi.encode(fn: fn)
    }

    /// Build call data for `name()`. Same dynamic-string return as
    /// `symbol()`; we share `parseSymbol` for the decode.
    static func nameData() -> Data {
        let fn = EthereumAbiFunction(name: "name")
        fn.addParamString(val: "", isOutput: true)
        return EthereumAbi.encode(fn: fn)
    }

    /// Build call data for ERC-20 `transfer(address,uint256)`. Used
    /// by `eth_estimateGas` to get a realistic gas estimate for a
    /// token transfer; the actual broadcast signs via TWC's
    /// `EthereumTransaction.ERC20Transfer` (which encodes the same
    /// payload under the hood).
    static func transferData(to recipient: String, amount: EthereumWeiValue) -> Data? {
        guard let r = hexToBytes(recipient) else { return nil }
        let fn = EthereumAbiFunction(name: "transfer")
        fn.addParamAddress(val: r, isOutput: false)
        fn.addParamUInt256(val: amount.bigEndianBytes, isOutput: false)
        fn.addParamBool(val: false, isOutput: true)
        return EthereumAbi.encode(fn: fn)
    }

    /// Parse the 32-byte big-endian uint256 returned by `balanceOf`.
    /// Leading zeros are stripped on the way into EthereumWeiValue.
    static func parseUint256(_ hex: String) -> EthereumWeiValue? {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        // Single-byte zero, sometimes returned by RPCs for empty
        // balances on contract addresses.
        if s.isEmpty || s.allSatisfy({ $0 == "0" }) { return .zero }
        return try? EthereumWeiValue(hex: s)
    }

    /// Parse the dynamic-string return of `symbol()`. ABI dynamic
    /// strings are: 32-byte offset (always 0x20 here) + 32-byte
    /// length + N bytes string + zero pad. Real-world tokens
    /// occasionally use a non-standard `bytes32` symbol; we fall
    /// back to that decode when the dynamic-string path fails.
    static func parseSymbol(_ hex: String) -> String? {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard let bytes = hexBytes(s) else { return nil }
        if bytes.count >= 64 {
            // bytes[0..32] = offset, bytes[32..64] = length, then
            // bytes[64..(64+length)] = the actual string.
            let lenBE = bytes[32..<64]
            guard let len = lenBE.reduce(into: UInt64(0), { $0 = $0 << 8 | UInt64($1) }).safeIntInRange(0, 256),
                  bytes.count >= 64 + len
            else { return parseBytes32String(bytes) }
            let strBytes = bytes[64..<(64 + len)]
            return String(bytes: strBytes, encoding: .utf8)
        }
        return parseBytes32String(bytes)
    }

    /// Some legacy tokens (MKR, OMG, …) declare `symbol` as `bytes32`
    /// rather than `string`. Strip trailing nulls.
    private static func parseBytes32String(_ bytes: [UInt8]) -> String? {
        let stripped = bytes.prefix(32).reversed().drop(while: { $0 == 0 }).reversed()
        let arr = Array(stripped)
        return String(bytes: arr, encoding: .utf8)
    }

    /// Parse the uint8 return of `decimals()`. Response is 32-byte
    /// big-endian; the meaningful byte is the last one.
    static func parseDecimals(_ hex: String) -> Int? {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard let bytes = hexBytes(s), let last = bytes.last else { return nil }
        return Int(last)
    }

    // MARK: -- hex utilities

    private static func hexToBytes(_ addr: String) -> Data? {
        var s = addr
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 40, let arr = hexBytes(s) else { return nil }
        return Data(arr)
    }

    private static func hexBytes(_ s: String) -> [UInt8]? {
        var hex = s
        if hex.count % 2 == 1 { hex = "0" + hex }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }
}

private extension UInt64 {
    func safeIntInRange(_ lo: Int, _ hi: Int) -> Int? {
        if self > UInt64(Int.max) { return nil }
        let v = Int(self)
        return (lo...hi).contains(v) ? v : nil
    }
}
