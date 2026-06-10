// Compact wire codec for serverless commerce payloads (ADR-0031).
//
// Encodes a Codable as JSON, then zlib-deflates it. The size win comes from
// recovering binary density: our presentations are dominated by 0x-hex strings
// (ML-DSA-65 signatures are ~3.3 kB each, the holder pubkey ~1.9 kB), and hex
// over a 16-symbol alphabet deflates ~2x. So an ~18 kB JSON+hex single-attribute
// presentation lands near ~9 kB, small enough to move over an NFC ISO-DEP tap in
// ~1-2 s.
//
// It round-trips losslessly to the exact same struct, so signature verification
// (PresentationVerifier) is unaffected. zlib is a built-in system framework on
// iOS, so this adds no dependency and nothing for an iOS peer to special-case.
// The NFC tap lane (P2) may switch to DCBOR/CBOR for ISO-18013-5 alignment and
// non-iOS merchants; this is the P1 implementation.

import Foundation

enum CompactCodec {
    enum Error: Swift.Error { case compressionFailed, decompressionFailed }

    /// JSON-encode then zlib-deflate.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        do {
            return try (json as NSData).compressed(using: .zlib) as Data
        } catch {
            throw Error.compressionFailed
        }
    }

    /// zlib-inflate then JSON-decode back to the original type.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let json: Data
        do {
            json = try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Error.decompressionFailed
        }
        return try JSONDecoder().decode(type, from: json)
    }
}
