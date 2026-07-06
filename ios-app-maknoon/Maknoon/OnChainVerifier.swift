// Holder-independent on-chain verification (ADR-0054). The holder confirms the
// three chain-gated checks the offline verifier can only mark UNVERIFIED, by
// talking DIRECTLY to a public EVM RPC + the registry contracts. No issuer or
// verifier server is in the loop:
//
//   * issuerRegistered  -> IdentityRegistry.isActive(string did)
//   * notRevoked        -> RevocationRegistry.isRevoked(string did, bytes32 cid)
//   * rootCurrent       -> RevocationRegistry.isRootRecent(string,bytes32,uint256)
//   * headerSigValid    -> IdentityRegistry.getIssuerPubkey(string) + ML-DSA verify
//   * cscaProvenance    -> CscaRegistry.isValidAt(bytes32 certHash, uint64 ts)
//
// Registry addresses + RPC resolve bundle-then-discover (RegistryConfig): the
// bundled Sepolia deployment is the default; the issuer well-known doc / verifier
// /v1/info and the user's Settings RPC override can replace them.
//
// Trust notes (surfaced to the user in the ADR): a malicious RPC could lie about
// chain state (mitigation: user-configurable RPC), and querying isRevoked(did,
// cid) discloses the credential id to the RPC provider (a privacy tradeoff; a
// self-hosted RPC avoids it).

import Foundation
import WalletCore
import ElabifyCore

/// Registry addresses + RPC endpoint for one chain. Bundled Sepolia defaults;
/// override via the issuer well-known doc / verifier info / Settings.
struct RegistryConfig: Sendable {
    var rpcURL: String
    var identityRegistry: String
    var revocationRegistry: String
    var cscaRegistry: String?

    /// The committed Sepolia deployment (the smart contracts).
    static let sepoliaDefault = RegistryConfig(
        rpcURL: "https://eth-sepolia.public.blastapi.io",
        identityRegistry: "0x8ca4260A49F4B05c652F926Cc402D909CA0881dB",
        revocationRegistry: "0x56CCaCEf210fc24007a8C327C10540Ea0d5ac52A",
        cscaRegistry: nil
    )
}

/// Result of one on-chain check.
enum OnChainTier: Sendable, Equatable {
    case pass
    case fail(String)
    case unknown(String) // RPC unreachable, or not enough info to check online
}

/// The online augmentation of the offline verdict.
struct OnChainVerdict: Sendable {
    var reachedChain: Bool
    var issuerRegistered: OnChainTier
    var notRevoked: OnChainTier
    var rootCurrent: OnChainTier
    var headerSigValid: OnChainTier
    var cscaProvenance: OnChainTier? // passports that carry a CSCA cert id only

    static func unreachable(_ why: String) -> OnChainVerdict {
        OnChainVerdict(
            reachedChain: false,
            issuerRegistered: .unknown(why),
            notRevoked: .unknown(why),
            rootCurrent: .unknown(why),
            headerSigValid: .unknown(why),
            cscaProvenance: nil
        )
    }

    /// True when the credential is fully valid online: the three chain gates and
    /// the on-chain header signature all pass.
    var fullyVerified: Bool {
        issuerRegistered == .pass && notRevoked == .pass &&
            rootCurrent == .pass && headerSigValid == .pass
    }
}

/// Minimal, dependency-free ABI encode/decode for the read-only registry calls.
/// Selectors are computed from the exact Solidity signature so they always match
/// the on-chain function (no reliance on a wrapper's type inference).
enum ChainABI {
    /// keccak256(signature)[0..<4].
    static func selector(_ signature: String) -> Data {
        Hash.keccak256(data: Data(signature.utf8)).prefix(4)
    }

    /// Right-most 32-byte word (left-padded) for a uint / offset.
    static func word(_ value: UInt64) -> Data {
        let be = withUnsafeBytes(of: value.bigEndian) { Data($0) } // 8 bytes
        return Data(repeating: 0, count: 24) + be
    }

    /// A `bytes32` value from hex: exactly 32 bytes, right-padded if short
    /// (fixed bytesN are left-aligned in a word).
    static func bytes32(hex: String) -> Data {
        let d = dataFromHex(hex)
        if d.count >= 32 { return d.prefix(32) }
        return d + Data(repeating: 0, count: 32 - d.count)
    }

    /// The head+tail encoding of a dynamic `string` (length word + padded bytes).
    static func stringTail(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        let pad = (32 - bytes.count % 32) % 32
        return word(UInt64(bytes.count)) + bytes + Data(repeating: 0, count: pad)
    }

    static func dataFromHex(_ hex: String) -> Data {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return Data(hexString: s) ?? Data()
    }

    /// Decode a `bool` return (last byte non-zero).
    static func decodeBool(_ hexResult: String) -> Bool? {
        let d = dataFromHex(hexResult)
        guard d.count >= 32 else { return nil }
        return d.suffix(32).contains { $0 != 0 }
    }

    /// Decode the FIRST `bytes` value of a `(bytes, bytes)` return (the ML-DSA
    /// pubkey from getIssuerPubkey). Head has two offsets; follow the first.
    static func decodeFirstBytes(_ hexResult: String) -> Data? {
        let d = dataFromHex(hexResult)
        guard d.count >= 32 else { return nil }
        let off = Int(d.prefix(32).suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        guard d.count >= off + 32 else { return nil }
        let len = Int(d[off..<off + 32].suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        let start = off + 32
        guard d.count >= start + len else { return nil }
        return d.subdata(in: start..<start + len)
    }
}

struct OnChainVerifier {
    let config: RegistryConfig
    /// Root-freshness window. Generous so a valid, recently-rotated root still
    /// reads as current for a holder-side sanity check.
    var rootFreshnessWindowSec: UInt64 = 90 * 24 * 3600

    /// Run the online pass for a presented credential. `cscaCertIdHex` is the
    /// passport's on-chain CSCA cert id when the credential carries one.
    func verify(header: CredentialHeader, headerSig: String, cscaCertIdHex: String?) async -> OnChainVerdict {
        guard let rpc = EthereumRPCClient(urlString: config.rpcURL) else {
            return .unreachable("No RPC configured")
        }
        let did = header.iss
        var reached = false

        // issuerRegistered: isActive(string)
        var issuerRegistered: OnChainTier = .unknown("RPC unreachable")
        if let hex = try? await rpc.ethCall(
            to: config.identityRegistry,
            data: ChainABI.selector("isActive(string)") + ChainABI.word(0x20) + ChainABI.stringTail(did)
        ), let ok = ChainABI.decodeBool(hex) {
            reached = true
            issuerRegistered = ok ? .pass : .fail("Issuer is not registered / not active on-chain")
        }

        // notRevoked: isRevoked(string,bytes32) -> invert
        var notRevoked: OnChainTier = .unknown("RPC unreachable")
        let cidData = ChainABI.bytes32(hex: header.cid)
        if let hex = try? await rpc.ethCall(
            to: config.revocationRegistry,
            data: ChainABI.selector("isRevoked(string,bytes32)") + ChainABI.word(0x40) + cidData + ChainABI.stringTail(did)
        ), let revoked = ChainABI.decodeBool(hex) {
            reached = true
            notRevoked = revoked ? .fail("Credential has been revoked on-chain") : .pass
        }

        // rootCurrent: isRootRecent(string,bytes32,uint256)
        var rootCurrent: OnChainTier = .unknown("RPC unreachable")
        let rootData = ChainABI.bytes32(hex: header.root)
        if let hex = try? await rpc.ethCall(
            to: config.revocationRegistry,
            data: ChainABI.selector("isRootRecent(string,bytes32,uint256)")
                + ChainABI.word(0x60) + rootData + ChainABI.word(rootFreshnessWindowSec)
                + ChainABI.stringTail(did)
        ), let recent = ChainABI.decodeBool(hex) {
            reached = true
            rootCurrent = recent ? .pass : .fail("Credential root is not current on-chain")
        }

        // headerSigValid: fetch the on-chain issuer pubkey, verify the header sig
        // against it. This is the anchor that upgrades the offline UNVERIFIED
        // header signature to a chain-backed PASS.
        var headerSigValid: OnChainTier = .unknown("RPC unreachable")
        if let hex = try? await rpc.ethCall(
            to: config.identityRegistry,
            data: ChainABI.selector("getIssuerPubkey(string)") + ChainABI.word(0x20) + ChainABI.stringTail(did)
        ) {
            reached = true
            if let pubkey = ChainABI.decodeFirstBytes(hex), !pubkey.isEmpty,
               let headerBytes = Self.canonicalHeaderBytes(header),
               let sig = ChainABI.dataFromHexOrNil(headerSig) {
                headerSigValid = MLDSAClient.verify(publicKey: pubkey, signature: sig, message: headerBytes)
                    ? .pass
                    : .fail("Header signature does not verify against the on-chain issuer key")
            } else {
                headerSigValid = .unknown("Issuer key not published on-chain")
            }
        }

        // cscaProvenance (passports only): isValidAt(bytes32,uint64)
        var cscaProvenance: OnChainTier?
        if let certIdHex = cscaCertIdHex, let cscaRegistry = config.cscaRegistry {
            let ts = UInt64(max(0, header.iat))
            if let hex = try? await rpc.ethCall(
                to: cscaRegistry,
                data: ChainABI.selector("isValidAt(bytes32,uint64)") + ChainABI.bytes32(hex: certIdHex) + ChainABI.word(ts)
            ), let valid = ChainABI.decodeBool(hex) {
                reached = true
                cscaProvenance = valid ? .pass : .fail("Passport CSCA certificate was not anchored/valid at issuance")
            } else {
                cscaProvenance = .unknown("Could not read CSCA registry")
            }
        }

        return OnChainVerdict(
            reachedChain: reached,
            issuerRegistered: issuerRegistered,
            notRevoked: notRevoked,
            rootCurrent: rootCurrent,
            headerSigValid: headerSigValid,
            cscaProvenance: cscaProvenance
        )
    }

    /// Canonical bytes the issuer signed for the header (re-encode + canonicalize,
    /// matching IssuerIdentityResolver.canonicalHeaderBytes).
    private static func canonicalHeaderBytes(_ header: CredentialHeader) -> Data? {
        guard let raw = try? JSONEncoder().encode(header),
              let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        return try? ElabifyCore.canonicalize(dict)
    }
}

extension ChainABI {
    static func dataFromHexOrNil(_ hex: String) -> Data? {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return Data(hexString: s)
    }
}
