// Wire-format data types for the Phase C demo. JSON-decoded directly from
// the issuer's /v1/issuance/pickup/{token} and posted directly to the
// verifier's /v1/verify endpoint. Shapes match the live Sepolia stack at
// musnad.elabify.com.

import Foundation

/// Hex string with optional `0x` prefix, what the wire format uses for
/// 32-byte / 65-byte / 1952-byte fields.
public typealias HexString = String

// MARK: -- Issuer pickup response

struct PickupResponse: Codable, Sendable {
    let state: String
    let credential: Credential?
    // M2 / ADR-0030: per-network availability for the credential's
    // allowedNetworks. Present on both `ready` and `pending_anchor`. Optional
    // for backward-compat with pre-M2 issuers.
    let networkAvailability: [NetworkAvailability]?
}

/// M2 / ADR-0030: a declared network and its current anchor status. status is
/// "ready" | "pending" | "gated".
struct NetworkAvailability: Codable, Sendable {
    let chain: String
    let name: String
    let status: String
    let anchoredAt: Int64?
    let estimatedAnchorAt: Int64?
    let expectedFlushIntervalSec: Int?
}

/// Inner credential payload returned by /v1/issuance/pickup. Shape matches
/// the issuer backend pickupCredential() return value.
/// Unknown JSON fields (schemaUri, issuanceMetadata) are ignored.
struct Credential: Codable, Identifiable, Sendable {
    let header: CredentialHeader
    let headerSig: HexString
    let claims: [String: JSONValue]
    let merkleTree: MerkleTreeDescriptor
    // var (not let): later-landing network anchors are merged in post-pickup via
    // the issuer's /v1/credentials/:cid/anchors re-poll (ADR-0030), so the card
    // lights up each network as its batch lands.
    var anchor: AnchorDescriptor?

    var id: String { header.cid }
}

/// Per the issuer backend CredentialHeader.
struct CredentialHeader: Codable, Sendable {
    let v: Int                    // 1 for the current header version
    let alg: String?              // "ML-DSA-65", present but we don't enforce
    let hash: String?             // "RPO-256"
    let iss: String
    let sub: String
    let iat: Int64
    let exp: Int64?
    let cid: String
    let root: HexString
    let schema: String
    // M2 / ADR-0030: CAIP-2 networks this credential may be used on. Absent on
    // pre-M2 (v:1) credentials.
    let allowedNetworks: [String]?
}

struct MerkleTreeDescriptor: Codable, Sendable {
    let sortedKeys: [String]
    let leafHashes: [HexString]
    let root: HexString
    let depth: Int
}

/// ADR-0022 batch-anchoring metadata. The credential carries one or more
/// AnchorEntries pointing at where its per-credential root sits inside the
/// issuer's Merkle-of-roots batch.
struct AnchorDescriptor: Codable, Sendable {
    let v: Int                    // 1
    let anchors: [AnchorEntry]
}

struct AnchorEntry: Codable, Sendable {
    let chain: String             // CAIP-2, e.g. "eip155:11155111"
    let registry: String          // 0x-prefixed contract address
    let batchRoot: HexString
    let batchTxHash: HexString
    let anchoredAt: Int64         // unix seconds
    let batchProof: [ProofEntry]
}

struct ProofEntry: Codable, Sendable {
    let sibling: HexString
    let isRight: Bool
}

// MARK: -- Verifier challenge + verify

struct ChallengeRequest: Codable, Sendable {
    let v: Int
    let requestedClaims: [String]
}

struct ChallengeResponse: Codable, Sendable {
    let requestId: String
    let challenge: HexString
    let issuedAt: Int64
    let expiresAt: Int64
    /// The DID the server minted this challenge under. The holder must sign the
    /// challenge against THIS (the server checks challengeSig against its own
    /// verifier DID), which can differ from an issuer/audience DID. Optional for
    /// back-compat with servers that do not echo it.
    let verifierDid: String?
}

struct VerifyRequest: Codable, Sendable {
    let v: Int
    let challengeContext: ChallengeContext
    let presentation: Presentation
}

struct ChallengeContext: Codable, Sendable {
    let requestId: String
    let issuedAt: Int64
    let expiresAt: Int64
}

/// Wire-format delegation cert that mirrors `DelegationCert` from
/// IdentitySandwich, but Codable + Sendable in the same shape the
/// verifier server expects (`Delegation` in `verifier-server/src/types.ts`).
struct PresentationDelegation: Codable, Sendable {
    let ephemeralPk: HexString
    let validFrom: Int64
    let validUntil: Int64
    let scope: [String]
    let delegationSig: HexString
}

/// Hardware-wallet attestation. A classical secp256k1 signature by a
/// paired hardware wallet that binds the holder's PQ master pubkey to a
/// concrete hardware device the user controls. ADR-0005 hybrid:
/// neither Trezor nor Ledger ship ML-DSA-65 yet, so this is the bridge.
///
/// Wire field is added to `Presentation` so the verifier can run
/// `hardwareAttestationValid`. Absent in normal use; surfaced as a
/// "lower-assurance" presentation when missing.
struct HardwareAttestation: Codable, Sendable {
    /// Discriminator. Recognised values today: `trezor-secp256k1`,
    /// `ledger-secp256k1`, `mock-secp256k1` (demo only).
    let kind: String
    /// Hex of the holder's ML-DSA-65 master pubkey (must match
    /// `Presentation.holderLongTermPk`).
    let masterPubkey: HexString
    /// Hex of the hardware wallet's secp256k1 public key (33 bytes
    /// compressed or 65 bytes uncompressed).
    let attestorPubkey: HexString
    /// Hex of the secp256k1 ECDSA signature over
    /// `canonicalize({kind, masterPubkey, attestorPubkey})`.
    let attestorSig: HexString
}

/// App Attest binding for a SELF-ISSUED credential (issuer == holder),
/// minted from a passport the app read and passive-auth-checked on device.
/// Lets a peer prove a genuine, unmodified Maknoon app instance on real
/// Apple hardware produced this exact credential, distinguishing it from a
/// QR fabricated outside the app. Absent on the simulator / unsupported
/// devices, in which case the self credential degrades to key-only.
struct SelfIssuerAttestation: Codable, Sendable {
    /// App Attest key id (base64), the credential id for the attested key.
    let keyId: String
    /// CBOR attestation object (base64): Apple cert chain (x5c) + authData.
    /// Carried so a peer can validate the chain offline against Apple's
    /// App Attest root and bind it to this Maknoon App ID.
    let attestation: String
    /// CBOR assertion object (base64) over the credential binding bytes.
    let assertion: String
    /// Hex SHA-256 of the binding the assertion signed:
    /// canonicalize({cid, root, holderPk, schema}). The verifier recomputes
    /// it from the presented credential so the assertion can't be replayed.
    let bindingHashHex: String
}

struct Presentation: Codable, Sendable {
    let v: Int
    let header: CredentialHeader
    let headerSig: HexString
    let challenge: HexString
    let challengeSig: HexString
    let disclosed: [DisclosedClaim]
    let timestamp: Int64
    let holderLongTermPk: HexString
    let anchor: AnchorDescriptor?
    /// Open-verifier flow: present iff this presentation was built in
    /// response to a scanned verifier QR. Echoed back so the verifier can
    /// re-authenticate the request server-side.
    let verifierRequest: VerifierRequest?
    /// Identity-Sandwich delegation cert. Present once the SE-resident
    /// ephemeral signs challenges (Step 2.B). The verifier's
    /// `delegationValid` check flips `true` when this is here and valid.
    let delegation: PresentationDelegation?
    /// Optional secp256k1 attestation by a paired hardware wallet.
    /// ADR-0005 hybrid; verifier's `hardwareAttestationValid` flips
    /// `true` when this is here and the signature checks out.
    let hardwareAttestation: HardwareAttestation?
    /// App Attest binding for a self-issued (issuer == holder) credential.
    /// Present only on locally minted credentials produced by a genuine
    /// app instance; lets a peer raise the trust tier to "app-verified".
    let selfIssuerAttestation: SelfIssuerAttestation?

    init(
        v: Int,
        header: CredentialHeader,
        headerSig: HexString,
        challenge: HexString,
        challengeSig: HexString,
        disclosed: [DisclosedClaim],
        timestamp: Int64,
        holderLongTermPk: HexString,
        anchor: AnchorDescriptor?,
        verifierRequest: VerifierRequest? = nil,
        delegation: PresentationDelegation? = nil,
        hardwareAttestation: HardwareAttestation? = nil,
        selfIssuerAttestation: SelfIssuerAttestation? = nil
    ) {
        self.v = v
        self.header = header
        self.headerSig = headerSig
        self.challenge = challenge
        self.challengeSig = challengeSig
        self.disclosed = disclosed
        self.timestamp = timestamp
        self.holderLongTermPk = holderLongTermPk
        self.anchor = anchor
        self.verifierRequest = verifierRequest
        self.delegation = delegation
        self.hardwareAttestation = hardwareAttestation
        self.selfIssuerAttestation = selfIssuerAttestation
    }
}

// MARK: -- Open-verifier flow (matches verifier-server's types.ts byte-for-byte)

/// Filter clause used inside `VerifierFilter`. `wildcard` accepts any value;
/// `allow` accepts only values that appear in `list`.
struct VerifierFilterClause: Codable, Sendable {
    let mode: String          // "wildcard" | "allow"
    let list: [String]?
}

/// Filter spec embedded in a `VerifierRequest`. The holder applies these
/// client-side via `MatchingEngine` to pick a candidate credential.
struct VerifierFilter: Codable, Sendable {
    let issuers: VerifierFilterClause?
    let schemas: VerifierFilterClause?
    let requiredClaims: [String]
}

/// How the verifier wants the holder to deliver the presentation.
struct VerifierResponseDirective: Codable, Sendable {
    let mode: String          // "callback" | "qrBack"
    let callbackUrl: String?
}

/// A verifier-published request, encoded into a QR for a holder to scan.
/// Two trust tiers:
///   - Self-signed: `verifierPublicKey` + `signature` both inline.
///   - Registered: both omitted; holder resolves the DID via the
///     verifier-registry endpoint, server validates against the
///     server-resolved pubkey (the QR still carries a `signature` field
///     so it isn't a bearer token).
struct VerifierRequest: Codable, Sendable {
    let v: Int                // 1
    let verifierDid: String
    let verifierName: String?
    let verifierPublicKey: HexString?
    let requestId: String
    let issuedAt: Int64
    let expiresAt: Int64
    let challenge: HexString
    let filter: VerifierFilter
    let response: VerifierResponseDirective
    let signature: HexString?
}

/// Registry record returned by `GET /v1/verifier-registry/:did`.
struct VerifierRegistryRecord: Codable, Sendable {
    let verifierDid: String
    let verifierName: String
    let verifierPublicKey: HexString
    let addedAt: Int64
}

/// One-shot drop envelope returned by `POST /v1/drop`. The holder renders
/// the envelope as a small QR; the verifier scans it and fetches the
/// actual presentation via `GET /v1/drop/{dropId}` exactly once.
struct DropEnvelope: Codable, Sendable {
    let v: Int                // 1
    let dropId: String
    // Informational only (the drop server enforces expiry). Optional so we can
    // decode envelopes from holders that omit it, e.g. the React wallet's
    // `{v:1,dropId}` single QR.
    let expiresAt: Int64?
}

// MARK: -- BLE engagement (ADR-0028)

/// BLE-specific engagement parameters: the service UUID the holder is
/// advertising and the base64-encoded X-Wing public key the verifier
/// uses to encapsulate the HPKE session.
struct EngagementBLE: Codable, Sendable {
    let service: String                // 128-bit UUID
    let engagementKey: String          // base64 X-Wing pubkey (~1216 bytes)
}

/// Fallback transports advertised alongside the BLE engagement. The
/// verifier may switch to multi-frame QR or a POST callback when BLE
/// fails (denied permission, simulator, browser without Web BT).
struct EngagementFallback: Codable, Sendable {
    let multiframeQr: Bool?
    let callbackUrl: String?
}

/// Holder-published engagement payload, encoded into a single QR for
/// the verifier to scan. Authenticity is established by physical
/// proximity (the QR is read off the holder's screen); the
/// cryptographic chain runs inside the Presentation itself.
struct TransportEngagement: Codable, Sendable {
    static let version = "elabify-engage-1"

    let v: String                      // "elabify-engage-1"
    let sessionId: String              // 16-byte hex
    let issuedAt: Int64
    let expiresAt: Int64
    let ble: EngagementBLE?
    let fallback: EngagementFallback?
}

struct DisclosedClaim: Codable, Sendable {
    let key: String
    let value: JSONValue
    let leafIndex: Int
    let proof: [ProofEntry]
}

struct VerifyResponse: Codable, Sendable {
    let decision: String
    let reason: String
    let ms: Double
    let checks: [String: JSONValue?]
    let disclosed: [String: JSONValue]?
}

// MARK: -- Heterogeneous JSON value

/// Wraps any JSON value (string, number, bool, null, array, object) so we
/// can round-trip claim payloads through Codable without losing types.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSONValue: unsupported")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Convert to a Swift Any suitable for ElabifyCore.canonicalize.
    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v):    return v
        case .double(let v): return v
        case .bool(let v):   return v
        case .null:          return NSNull()
        case .array(let v):  return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }

    /// Human-readable single-line rendering for UI display.
    var displayText: String {
        switch self {
        case .string(let v): return v
        case .int(let v):    return String(v)
        case .double(let v): return String(v)
        case .bool(let v):   return v ? "yes" : "no"
        case .null:          return "-"
        case .array(let v):  return "[\(v.count) item\(v.count == 1 ? "" : "s")]"
        case .object(let v): return "{\(v.count) field\(v.count == 1 ? "" : "s")}"
        }
    }

    /// Multi-line, indented rendering that expands nested objects and
    /// arrays so a structured claim (e.g. `sdnScreen`) shows its fields
    /// instead of collapsing to "{3 fields}". Scalars match
    /// `displayText` (single line).
    var prettyText: String {
        switch self {
        case .string, .int, .double, .bool, .null:
            return displayText
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return items.enumerated()
                .map { Self.prettyEntry(label: "\($0.offset)", value: $0.element) }
                .joined(separator: "\n")
        case .object(let dict):
            guard !dict.isEmpty else { return "{}" }
            return dict.sorted { $0.key < $1.key }
                .map { Self.prettyEntry(label: $0.key, value: $0.value) }
                .joined(separator: "\n")
        }
    }

    /// Render one `label: value` line for `prettyText`. Nested objects
    /// and arrays recurse and indent two spaces per level.
    private static func prettyEntry(label: String, value: JSONValue) -> String {
        switch value {
        case .object, .array:
            let nested = value.prettyText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  " + $0 }
                .joined(separator: "\n")
            return "\(label):\n\(nested)"
        default:
            return "\(label): \(value.displayText)"
        }
    }
}
