// Shared error type + CryptoKit-error humanizer for the hardware
// second-factor flows.
//
// ADR-0032 moved the second-factor wrap to the CEK scheme in
// SecondFactorWrap.swift (one random CEK seals the entropy once; each
// device stores only a wrappedCEK). The old per-material WrapEnvelope /
// WrappedMaterialPersisted machinery and the IdentityWrap crypto enum
// were removed. This file keeps only the user-facing error type and
// the CryptoKit-error humanizer, which the device + send views still
// use for serial-mismatch and seal-failure messages.

import Foundation
import CryptoKit

enum IdentityWrapError: LocalizedError {
    case signatureTooShort(Int)
    case sealFailed(String)
    case openFailed(String)
    case deviceSerialMismatch(expected: String, actual: String)
    var errorDescription: String? {
        switch self {
        case .signatureTooShort(let n):
            return "Hardware-wallet wrap signature was \(n) bytes; need at least 32."
        case .sealFailed(let m):
            return "Could not seal the second factor: \(m)"
        case .openFailed(let m):
            // Stay device-agnostic: this error fires for any hardware
            // device whose wrap key didn't match. The "different
            // device" hypothesis is also separately surfaced by
            // `deviceSerialMismatch`, so we don't repeat it here.
            return "Could not unseal the second factor: \(m)."
        case .deviceSerialMismatch(let exp, let act):
            return "Maknoon is locked by a different device (expected \(exp), connected \(act))."
        }
    }
}

/// Map CryptoKit's terse enum-case-name `description` (e.g.
/// `authenticationFailure`) into something a human can read. Falls
/// through to the underlying error description otherwise. Used at the
/// call sites that catch `AES.GCM.open` failures inside the wrap path
/// so the user doesn't see camelCase noise.
func humanReadableWrapError(_ error: Error) -> String {
    if let cryptoErr = error as? CryptoKit.CryptoKitError {
        switch cryptoErr {
        case .authenticationFailure:
            return "wrap key did not match (wrong device, or device signature drifted since enrollment)"
        case .incorrectKeySize:
            return "wrap key was the wrong size"
        case .incorrectParameterSize:
            return "wrap parameter was the wrong size"
        case .underlyingCoreCryptoError(let code):
            return "internal Crypto error (\(code))"
        case .wrapFailure:
            return "wrap failure"
        case .unwrapFailure:
            return "unwrap failure"
        @unknown default:
            return "Crypto error: \(error)"
        }
    }
    return "\(error)"
}

// MARK: -- shared hex helpers for the second-factor wrap call sites

/// Lowercase hex of `data`, no `0x` prefix. Module-internal so the
/// device enroll / unlock call sites (RegisterDeviceSheet,
/// DeviceDetailView, RemoveFromSandwichSheet) can persist the deviceSalt
/// without each redefining a private copy.
func bytesToHexLocal(_ data: Data) -> String {
    let alphabet: [Character] = Array("0123456789abcdef")
    var s = String()
    s.reserveCapacity(data.count * 2)
    for byte in data {
        s.append(alphabet[Int(byte >> 4)])
        s.append(alphabet[Int(byte & 0x0f)])
    }
    return s
}

/// Decode lowercase/uppercase hex (optional `0x`) to bytes. Soft-fails
/// to empty Data on malformed input so a bad stored value surfaces as a
/// recoverable wrap-open failure rather than a crash.
func bytesFromHexLocal(_ hex: String) -> Data {
    var s = hex
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
    guard s.count.isMultiple(of: 2) else { return Data() }
    var out = Data(capacity: s.count / 2)
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return Data() }
        out.append(UInt8((hi << 4) | lo))
        i += 2
    }
    return out
}
