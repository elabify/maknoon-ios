// Minimal RLP (Recursive Length Prefix) encoder. We need it for one
// thing: producing the EIP-1559 unsigned-transaction payload that a
// Ledger Ethereum app signs via SIGN_TRANSACTION (CLA=0xE0 INS=0x04).
// Trust Wallet Core handles RLP internally for the software signing
// path; for the hardware path we have to materialise the unsigned
// envelope ourselves so the device can ingest it.
//
// EIP-2718 typed envelopes (type 0x02 for EIP-1559) wrap a single
// RLP list. The "data" we hand to Ledger is `0x02 || rlp(payload)`;
// the signed transaction we broadcast is `0x02 || rlp(payload || v ||
// r || s)`.
//
// Reference: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/

import Foundation

enum EthereumRLP {
    /// Encode a single item: either bytes (Data) or a list ([RLPItem]).
    indirect enum Item {
        case bytes(Data)
        case list([Item])

        /// Convenience: encode an integer as its minimal big-endian
        /// representation. Zero collapses to empty bytes (RLP's
        /// canonical encoding of 0; do NOT use a 0x00 byte).
        static func uint(_ v: UInt64) -> Item {
            if v == 0 { return .bytes(Data()) }
            var bytes: [UInt8] = []
            var x = v
            while x > 0 { bytes.append(UInt8(x & 0xff)); x >>= 8 }
            return .bytes(Data(bytes.reversed()))
        }

        /// Big-endian wei value, leading zeros stripped. Same canonical
        /// form RLP wants. 0 → empty bytes.
        static func wei(_ v: EthereumWeiValue) -> Item {
            let raw = v.bigEndianBytes
            // bigEndianBytes already strips leading zeros except for
            // an exact-zero value which collapses to a single 0x00
            // byte. RLP wants empty bytes for zero.
            if raw.count == 1 && raw[0] == 0 { return .bytes(Data()) }
            return .bytes(raw)
        }

        /// Hex address (0x… or raw) → 20 fixed bytes. Empty input
        /// (contract creation) → empty bytes.
        static func address(_ hex: String) -> Item {
            var s = hex
            if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
            if s.isEmpty { return .bytes(Data()) }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(20)
            var idx = s.startIndex
            while idx < s.endIndex {
                let next = s.index(idx, offsetBy: 2)
                bytes.append(UInt8(s[idx..<next], radix: 16) ?? 0)
                idx = next
            }
            return .bytes(Data(bytes))
        }
    }

    /// Encode an item into RLP bytes.
    static func encode(_ item: Item) -> Data {
        switch item {
        case .bytes(let data):
            return encodeBytes(data)
        case .list(let items):
            var inner = Data()
            for child in items { inner.append(encode(child)) }
            return encodeListPrefix(payloadLen: inner.count) + inner
        }
    }

    private static func encodeBytes(_ data: Data) -> Data {
        if data.count == 1 && data[0] < 0x80 {
            // Single byte under 0x80 encodes as itself.
            return data
        }
        return encodeStringPrefix(payloadLen: data.count) + data
    }

    private static func encodeStringPrefix(payloadLen: Int) -> Data {
        if payloadLen < 56 {
            return Data([UInt8(0x80 + payloadLen)])
        }
        let lenBytes = bigEndianLength(payloadLen)
        return Data([UInt8(0xB7 + lenBytes.count)]) + lenBytes
    }

    private static func encodeListPrefix(payloadLen: Int) -> Data {
        if payloadLen < 56 {
            return Data([UInt8(0xC0 + payloadLen)])
        }
        let lenBytes = bigEndianLength(payloadLen)
        return Data([UInt8(0xF7 + lenBytes.count)]) + lenBytes
    }

    private static func bigEndianLength(_ n: Int) -> Data {
        var bytes: [UInt8] = []
        var x = n
        while x > 0 { bytes.append(UInt8(x & 0xff)); x >>= 8 }
        return Data(bytes.reversed())
    }
}
