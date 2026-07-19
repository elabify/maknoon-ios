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
    /// The RPC is NOT hardcoded here: the registries live on Sepolia, so the
    /// caller passes the app's effective Sepolia RPC (Settings > Networks >
    /// Ethereum, which honors the user's per-network override and otherwise
    /// falls back to EthereumNetwork.sepolia.defaultRPCURL). This keeps the
    /// on-chain verifier on the same endpoint the wallet already uses instead of
    /// a private hardcoded URL.
    static func sepolia(rpcURL: String) -> RegistryConfig {
        RegistryConfig(
            rpcURL: rpcURL,
            identityRegistry: "0x8ca4260A49F4B05c652F926Cc402D909CA0881dB",
            revocationRegistry: "0x56CCaCEf210fc24007a8C327C10540Ea0d5ac52A",
            cscaRegistry: nil
        )
    }
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

    /// Full keccak256 of a UTF-8 string as 0x-hex. Used for an event-signature
    /// topic0 and for an indexed dynamic-string topic (keccak of the value).
    static func keccakHex(_ s: String) -> String {
        "0x" + Hash.keccak256(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Normalize a hex value to a 32-byte (0x + 64 lowercase) topic form.
    static func topic32(_ hex: String) -> String {
        var h = (hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex).lowercased()
        if h.count > 64 { h = String(h.suffix(64)) }
        if h.count < 64 { h = String(repeating: "0", count: 64 - h.count) + h }
        return "0x" + h
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
    /// `anchorBatchRoot` is the credential's ANCHOR batch root for this registry's
    /// chain (from `presentation.anchor.anchors[].batchRoot`), NOT `header.root`:
    /// the issuer anchors a Merkle-of-roots `batchRoot` per epoch (ADR-0022), and
    /// `header.root` (the per-credential root) is never an on-chain epoch root, so
    /// isRootRecent must be checked against the batchRoot.
    /// Identity checks (isActive / getIssuerPubkey) run on the issuer's identity
    /// chain (`config`, Sepolia). Revocation + root run on the chain the credential
    /// is ACTUALLY anchored on: `anchorRevocationRegistry` + `anchorRPCURL` +
    /// `anchorBatchRoot` come from the presented anchor entry, so a Base-Sepolia
    /// anchored credential is checked on Base Sepolia, not Sepolia.
    func verify(
        header: CredentialHeader,
        headerSig: String,
        cscaCertIdHex: String?,
        anchorBatchRoot: String?,
        anchorRPCURL: String?,
        anchorRevocationRegistry: String?,
        anchorTxHash: String?
    ) async -> OnChainVerdict {
        // Reuse the reference pass (which also fetches the on-chain issuer key),
        // then layer headerSigValid on top using the full header + signature.
        let ref = await verifyReference(
            did: header.iss, cid: header.cid, iat: header.iat,
            cscaCertIdHex: cscaCertIdHex, anchorBatchRoot: anchorBatchRoot,
            anchorRPCURL: anchorRPCURL, anchorRevocationRegistry: anchorRevocationRegistry,
            anchorTxHash: anchorTxHash
        )
        var v = ref.verdict
        if let pk = ref.issuerPubkey, !pk.isEmpty,
           let headerBytes = Self.canonicalHeaderBytes(header),
           let sig = ChainABI.dataFromHexOrNil(headerSig) {
            v.headerSigValid = MLDSAClient.verify(publicKey: pk, signature: sig, message: headerBytes)
                ? .pass
                : .fail("Header signature does not verify against the on-chain issuer key")
        } else if v.reachedChain {
            v.headerSigValid = .unknown("Issuer key not published on-chain")
        }
        return v
    }

    /// The result of a REFERENCE pass: the verdict (with headerSigValid left
    /// "unknown", since a reference/badge carries no full header to verify) plus
    /// the on-chain issuer pubkey (so the caller can bind HAVID via the on-chain
    /// key instead of a credential signature).
    struct ReferenceResult { var verdict: OnChainVerdict; var issuerPubkey: Data? }

    /// True iff `receipt` contains a RevocationRegistry `RootUpdated` log from
    /// `registry` binding this issuer `did` + `batchRoot`. Topics only:
    /// topic0 = keccak256 of the event signature, topic1 = keccak256(utf8(did))
    /// (the indexed dynamic string), topic2 = the indexed bytes32 root.
    private static func rootWasAnchored(_ receipt: EthereumTxReceipt, registry: String, did: String, batchRoot: String) -> Bool {
        let topic0 = ChainABI.keccakHex("RootUpdated(string,string,bytes32,uint256,uint256)").lowercased()
        let topic1 = ChainABI.keccakHex(did).lowercased()
        let wantRoot = ChainABI.topic32(batchRoot)
        let reg = registry.lowercased()
        for log in receipt.logs where log.address.lowercased() == reg && log.topics.count >= 3 {
            if log.topics[0].lowercased() == topic0
                && log.topics[1].lowercased() == topic1
                && ChainABI.topic32(log.topics[2]) == wantRoot {
                return true
            }
        }
        return false
    }

    /// On-chain checks that need only a credential REFERENCE (did + cid + iat +
    /// anchor): issuerRegistered, notRevoked, rootCurrent, cscaProvenance. Also
    /// fetches the issuer's on-chain pubkey. Used directly by the badge flow.
    func verifyReference(
        did: String,
        cid: String,
        iat: Int64,
        cscaCertIdHex: String?,
        anchorBatchRoot: String?,
        anchorRPCURL: String?,
        anchorRevocationRegistry: String?,
        anchorTxHash: String?
    ) async -> ReferenceResult {
        guard let rpc = EthereumRPCClient(urlString: config.rpcURL) else {
            return ReferenceResult(verdict: .unreachable("No RPC configured"), issuerPubkey: nil)
        }
        // Revocation + root live on the anchor's chain (may differ from identity).
        let anchorRPC = anchorRPCURL.flatMap { EthereumRPCClient(urlString: $0) }
        let revRegistry = anchorRevocationRegistry ?? config.revocationRegistry
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

        // notRevoked + rootCurrent run on the anchor's chain (anchorRPC + the
        // RevocationRegistry the anchor names). Without a reachable anchor chain we
        // leave them "unknown" (not failed).
        var notRevoked: OnChainTier = .unknown("No reachable anchor chain")
        var rootCurrent: OnChainTier = .unknown("Carries no on-chain anchor for a supported network")
        if let arpc = anchorRPC {
            let cidData = ChainABI.bytes32(hex: cid)
            if let hex = try? await arpc.ethCall(
                to: revRegistry,
                data: ChainABI.selector("isRevoked(string,bytes32)") + ChainABI.word(0x40) + cidData + ChainABI.stringTail(did)
            ), let revoked = ChainABI.decodeBool(hex) {
                reached = true
                notRevoked = revoked ? .fail("Credential has been revoked on-chain") : .pass
            } else {
                notRevoked = .unknown("Could not read the revocation registry")
            }

            if let batchRoot = anchorBatchRoot, !batchRoot.isEmpty,
               let txHash = anchorTxHash, !txHash.isEmpty {
                // ADR-0022 amendment: a v2 batch root is valid if it was genuinely
                // anchored by the issuer (not merely "recent"). Confirm the anchor
                // tx emitted RevocationRegistry RootUpdated(did, root) from the
                // expected registry. Matches the server's wasRootAnchored.
                if let receipt = try? await arpc.getTransactionReceipt(txHash) {
                    reached = true
                    rootCurrent = Self.rootWasAnchored(receipt, registry: revRegistry, did: did, batchRoot: batchRoot)
                        ? .pass
                        : .fail("Credential anchor root was not published in the anchor transaction on-chain")
                } else {
                    rootCurrent = .unknown("Could not read the anchor transaction on-chain")
                }
            }
        }

        // On-chain issuer pubkey (for headerSigValid in verify(), and for the
        // caller to bind HAVID via the on-chain key).
        var issuerPubkey: Data?
        if let hex = try? await rpc.ethCall(
            to: config.identityRegistry,
            data: ChainABI.selector("getIssuerPubkey(string)") + ChainABI.word(0x20) + ChainABI.stringTail(did)
        ) {
            reached = true
            issuerPubkey = ChainABI.decodeFirstBytes(hex)
        }

        // cscaProvenance (passports only): isValidAt(bytes32,uint64)
        var cscaProvenance: OnChainTier?
        if let certIdHex = cscaCertIdHex, let cscaRegistry = config.cscaRegistry {
            let ts = UInt64(max(0, iat))
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

        let verdict = OnChainVerdict(
            reachedChain: reached,
            issuerRegistered: issuerRegistered,
            notRevoked: notRevoked,
            rootCurrent: rootCurrent,
            headerSigValid: .unknown("Needs the full credential (a badge is a reference)"),
            cscaProvenance: cscaProvenance
        )
        return ReferenceResult(verdict: verdict, issuerPubkey: issuerPubkey)
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
