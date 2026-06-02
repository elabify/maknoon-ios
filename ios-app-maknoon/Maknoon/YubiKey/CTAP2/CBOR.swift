// Minimal CBOR encoder/decoder for the CTAP2 shapes Maknoon
// emits and consumes. NOT a complete RFC 8949 implementation; we only
// support the subset CTAP2 actually uses:
//
//   - Unsigned integers (major type 0): 0 .. UInt64.max
//   - Negative integers (major type 1): -1 .. -2^63
//   - Byte strings (major type 2)
//   - Text strings (major type 3)
//   - Arrays (major type 4)
//   - Maps (major type 5)
//   - Simple values (major type 7): false (0xF4), true (0xF5), null (0xF6)
//
// Floating-point, tagged values, indefinite-length items, and the rest
// of the spec are deliberately unsupported and surface as errors. CTAP2
// authenticators emit the deterministic encoding profile by spec
// (RFC 8949 §4.2.1 plus canonical key ordering for maps), so the
// decoder accepts only that.

import Foundation

enum CBORValue: Equatable {
    case unsignedInt(UInt64)
    case negativeInt(Int64)        // value is the signed integer; -1, -2, ...
    case byteString(Data)
    case textString(String)
    case array([CBORValue])
    case map([CBORMapEntry])
    case bool(Bool)
    case null

    /// Convenience for `int` keyed maps with small (< 24) keys.
    static func intKey(_ k: Int) -> CBORValue {
        if k >= 0 {
            return .unsignedInt(UInt64(k))
        }
        return .negativeInt(Int64(k))
    }
}

/// Map entry. The encoder sorts entries by canonical key order
/// (shorter encoding first, then lexicographic over the encoded
/// bytes), matching the CTAP2 canonical CBOR profile.
struct CBORMapEntry: Equatable {
    let key: CBORValue
    let value: CBORValue
}

enum CBORError: LocalizedError {
    case unsupportedType(UInt8)
    case truncated
    case integerOverflow
    case invalidUTF8
    case encodingTooLarge
    case unexpectedMajorType(expected: UInt8, got: UInt8)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let b):
            return "CBOR: unsupported initial byte 0x\(String(format: "%02X", b))"
        case .truncated:
            return "CBOR: input truncated before a complete value was read"
        case .integerOverflow:
            return "CBOR: integer length exceeded UInt64"
        case .invalidUTF8:
            return "CBOR: text string was not valid UTF-8"
        case .encodingTooLarge:
            return "CBOR: encoded value exceeds 64-bit length"
        case .unexpectedMajorType(let expected, let got):
            return "CBOR: expected major type \(expected), got \(got)"
        }
    }
}

// MARK: -- Encoding

enum CBOREncoder {
    static func encode(_ value: CBORValue) throws -> Data {
        var out = Data()
        try append(value, to: &out)
        return out
    }

    private static func append(_ value: CBORValue, to out: inout Data) throws {
        switch value {
        case .unsignedInt(let n):
            appendHead(majorType: 0, n: n, to: &out)
        case .negativeInt(let n):
            // CBOR negative integers encode -1-n where n is the unsigned
            // "info" value; -1 → 0, -2 → 1, etc.
            let mapped = UInt64(bitPattern: -(n + 1))
            appendHead(majorType: 1, n: mapped, to: &out)
        case .byteString(let d):
            appendHead(majorType: 2, n: UInt64(d.count), to: &out)
            out.append(d)
        case .textString(let s):
            let bytes = Data(s.utf8)
            appendHead(majorType: 3, n: UInt64(bytes.count), to: &out)
            out.append(bytes)
        case .array(let items):
            appendHead(majorType: 4, n: UInt64(items.count), to: &out)
            for item in items { try append(item, to: &out) }
        case .map(let entries):
            // Canonical key ordering: shorter encoded key first, then
            // bytewise lexicographic.
            let encodedEntries: [(Data, CBORMapEntry)] = try entries.map {
                (try CBOREncoder.encode($0.key), $0)
            }
            let sorted = encodedEntries.sorted { a, b in
                if a.0.count != b.0.count { return a.0.count < b.0.count }
                return a.0.lexicographicallyPrecedes(b.0)
            }
            appendHead(majorType: 5, n: UInt64(sorted.count), to: &out)
            for (encKey, entry) in sorted {
                out.append(encKey)
                try append(entry.value, to: &out)
            }
        case .bool(let b):
            out.append(b ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        }
    }

    private static func appendHead(majorType: UInt8, n: UInt64, to out: inout Data) {
        let mt = (majorType & 0x07) << 5
        if n < 24 {
            out.append(mt | UInt8(n))
        } else if n <= UInt8.max {
            out.append(mt | 24)
            out.append(UInt8(n))
        } else if n <= UInt16.max {
            out.append(mt | 25)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
        } else if n <= UInt32.max {
            out.append(mt | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xFF))
            }
        } else {
            out.append(mt | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xFF))
            }
        }
    }
}

// MARK: -- Decoding

enum CBORDecoder {
    static func decode(_ data: Data) throws -> CBORValue {
        var index = 0
        let value = try decodeNext(data: data, index: &index)
        return value
    }

    /// Decode one CBOR value from `data` and return how many bytes
    /// it consumed. Useful when an authenticator response embeds a
    /// CBOR map followed by more bytes (the makeCredential
    /// attestedCred + extensions layout has this shape).
    static func decodeLength(_ data: Data) throws -> Int {
        var index = 0
        _ = try decodeNext(data: data, index: &index)
        return index
    }

    private static func decodeNext(data: Data, index: inout Int) throws -> CBORValue {
        guard index < data.count else { throw CBORError.truncated }
        let initial = data[data.startIndex + index]
        index += 1
        let majorType = initial >> 5
        let info = initial & 0x1F
        switch majorType {
        case 0:
            let n = try readArg(info: info, data: data, index: &index)
            return .unsignedInt(n)
        case 1:
            let n = try readArg(info: info, data: data, index: &index)
            // -(n+1), where n is unsigned. Clamp to Int64 for the
            // CTAP2 ranges we expect (small negative integers used as
            // map keys).
            if n > UInt64(Int64.max) { throw CBORError.integerOverflow }
            return .negativeInt(-(Int64(n) + 1))
        case 2:
            let n = try readArg(info: info, data: data, index: &index)
            let length = Int(n)
            guard index + length <= data.count else { throw CBORError.truncated }
            let slice = data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + length))
            index += length
            return .byteString(slice)
        case 3:
            let n = try readArg(info: info, data: data, index: &index)
            let length = Int(n)
            guard index + length <= data.count else { throw CBORError.truncated }
            let slice = data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + length))
            index += length
            guard let s = String(data: slice, encoding: .utf8) else {
                throw CBORError.invalidUTF8
            }
            return .textString(s)
        case 4:
            let n = try readArg(info: info, data: data, index: &index)
            var arr: [CBORValue] = []
            arr.reserveCapacity(Int(n))
            for _ in 0..<Int(n) {
                arr.append(try decodeNext(data: data, index: &index))
            }
            return .array(arr)
        case 5:
            let n = try readArg(info: info, data: data, index: &index)
            var entries: [CBORMapEntry] = []
            entries.reserveCapacity(Int(n))
            for _ in 0..<Int(n) {
                let key = try decodeNext(data: data, index: &index)
                let val = try decodeNext(data: data, index: &index)
                entries.append(CBORMapEntry(key: key, value: val))
            }
            return .map(entries)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .null
            default:
                throw CBORError.unsupportedType(initial)
            }
        default:
            throw CBORError.unsupportedType(initial)
        }
    }

    private static func readArg(info: UInt8, data: Data, index: inout Int) throws -> UInt64 {
        switch info {
        case 0...23:
            return UInt64(info)
        case 24:
            guard index < data.count else { throw CBORError.truncated }
            let v = UInt64(data[data.startIndex + index])
            index += 1
            return v
        case 25:
            guard index + 2 <= data.count else { throw CBORError.truncated }
            let hi = UInt64(data[data.startIndex + index])
            let lo = UInt64(data[data.startIndex + index + 1])
            index += 2
            return (hi << 8) | lo
        case 26:
            guard index + 4 <= data.count else { throw CBORError.truncated }
            var v: UInt64 = 0
            for i in 0..<4 {
                v = (v << 8) | UInt64(data[data.startIndex + index + i])
            }
            index += 4
            return v
        case 27:
            guard index + 8 <= data.count else { throw CBORError.truncated }
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(data[data.startIndex + index + i])
            }
            index += 8
            return v
        default:
            throw CBORError.unsupportedType(info)
        }
    }
}

// MARK: -- Convenience map accessors

extension CBORValue {
    /// Lookup by integer key into a map value. Returns nil if not a
    /// map, or the key isn't present, or stored as a different type.
    func entry(forIntKey k: Int) -> CBORValue? {
        guard case .map(let entries) = self else { return nil }
        for e in entries {
            switch e.key {
            case .unsignedInt(let u) where k >= 0 && u == UInt64(k):
                return e.value
            case .negativeInt(let s) where Int64(k) == s:
                return e.value
            default:
                continue
            }
        }
        return nil
    }

    /// Lookup by text key.
    func entry(forTextKey k: String) -> CBORValue? {
        guard case .map(let entries) = self else { return nil }
        for e in entries {
            if case .textString(let s) = e.key, s == k {
                return e.value
            }
        }
        return nil
    }

    var asBytes: Data? {
        if case .byteString(let d) = self { return d }
        return nil
    }
    var asString: String? {
        if case .textString(let s) = self { return s }
        return nil
    }
    var asUInt: UInt64? {
        if case .unsignedInt(let n) = self { return n }
        return nil
    }
    var asInt: Int? {
        switch self {
        case .unsignedInt(let n): return Int(exactly: n)
        case .negativeInt(let n): return Int(exactly: n)
        default: return nil
        }
    }
    var asArray: [CBORValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
