// Thin shims around URKit so the rest of the SeedSigner module
// doesn't have to learn URKit's API. Everything outside this file
// talks bytes and "UR strings"; URKit's types stay contained here.
//
// The encoder side splits a PSBT into fountain-encoded fragments
// for animated QR display. The decoder side collects fragments
// from a live camera scan and returns the assembled PSBT bytes
// once it has enough.
//
// FORMAT NOTE: SeedSigner accepts `ur:crypto-psbt` (CBOR-tagged,
// BCR-2020-006). Older SeedSigner firmware predates the newer
// untagged `ur:psbt` Blockchain Commons later standardised on,
// so we emit the tagged variant for maximum signer compatibility.
// CBOR tag 310 is the registered tag for PSBT under crypto-psbt.
// Decoder accepts both ur:crypto-psbt and ur:psbt so the receive
// side keeps working regardless of which dialect the signer
// emits back.

import Foundation
import URKit

enum URPSBTCodecError: LocalizedError {
    case notPSBT
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notPSBT:       return "That QR isn't a PSBT. Try scanning the signed transaction QR shown on the SeedSigner."
        case .decode(let s): return s
        }
    }
}

enum URPSBTCodec {

    // MARK: -- encode

    /// Encode raw PSBT bytes as a UR fountain stream that
    /// SeedSigner can parse. `maxFragmentLen` caps the size of
    /// each fragment so the resulting QR code stays small enough
    /// to scan reliably on a SeedSigner screen.
    static func makeEncoder(psbt: Data, maxFragmentLen: Int = 100) throws -> UREncoder {
        // BCR-2020-006 ur:crypto-psbt format. The CBOR payload is
        // a byteString WRAPPED in CBOR tag 310. Older SeedSigner
        // firmware only recognised this tagged form; the untagged
        // ur:psbt was added later and isn't universally supported.
        let inner = CBOR.bytes(psbt)
        let tagged = CBOR.tagged(Tag(310, "crypto-psbt"), inner)
        let ur = try UR(type: "crypto-psbt", cbor: tagged)
        return UREncoder(ur, maxFragmentLen: maxFragmentLen)
    }

    // MARK: -- decode

    /// Stateful decoder that accumulates QR fragments scanned from
    /// the camera. Call `receivePart(_:)` for every QR string the
    /// scanner emits. When `isComplete` becomes true,
    /// `assembledPSBT` returns the raw PSBT bytes.
    final class StreamingDecoder {
        private let decoder = URDecoder()

        var progress: Double { decoder.estimatedPercentComplete }
        var expectedPartCount: Int? {
            let n = decoder.expectedFragmentCount
            return n == 0 ? nil : n
        }
        var receivedPartIndexes: Set<Int> { decoder.receivedFragmentIndexes }
        var isComplete: Bool { decoder.result != nil }

        @discardableResult
        func receivePart(_ part: String) -> Bool {
            decoder.receivePart(part)
            return decoder.result != nil
        }

        func assembledPSBT() throws -> Data {
            guard let result = decoder.result else {
                throw URPSBTCodecError.decode("Scan isn't complete yet.")
            }
            switch result {
            case .success(let ur):
                guard ur.type == "psbt" || ur.type == "crypto-psbt" else {
                    throw URPSBTCodecError.notPSBT
                }
                // The CBOR payload may be either a tagged
                // byteString (crypto-psbt per BCR-2020-006) or a
                // bare byteString (untagged psbt per the newer
                // spec). Unwrap the tag if present, then decode.
                let inner: CBOR
                if case .tagged(let tag, let wrapped) = ur.cbor, tag.value == 310 {
                    inner = wrapped
                } else {
                    inner = ur.cbor
                }
                do {
                    return try Data(cbor: inner)
                } catch {
                    throw URPSBTCodecError.decode("Couldn't read the PSBT from the QR. \(error.localizedDescription)")
                }
            case .failure(let err):
                throw URPSBTCodecError.decode(err.localizedDescription)
            }
        }
    }
}

private extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}
