// Verified issuer identity (Track 3). Resolves a credential's issuer DID to a
// human-readable name we can TRUST, without an on-chain read, by binding the
// issuer's SIGNED well-known doc to the credential the holder already holds:
//
//   1. fetch {host}/v1/issuer/well-known-doc from a known-issuer host whose
//      doc.did matches the credential's header.iss
//   2. verify the doc's ML-DSA-65 self-signature with the embedded pubkey P
//   3. verify the held credential's headerSig with the SAME P over
//      canonicalize(header)
//
// If all pass, P provably signed both the doc and this credential, so the doc's
// humanLabel is trustworthy with no chain read. A MITM serving a fake doc would
// need the key that signed the real credential. Mirrors the React
// shared/issuerIdentity.ts and the verifier-server checks (canonicalize(header)
// in checks.ts, canonicalize(doc - signature) in issuer-doc.ts).
//
// iOS does not store a per-credential issuer URL, so we probe the known-issuer
// hosts and match on DID. Failure (offline, no match, verify fail) -> nil; the
// card falls back to the DID heuristic, marked unverified.

import Foundation
import ElabifyCore

struct VerifiedIssuer: Sendable {
    let did: String
    let humanLabel: String
    let chain: String
}

actor IssuerIdentityResolver {
    static let shared = IssuerIdentityResolver()

    /// Cache by issuer DID for the session. A verified label is stable within a
    /// run; re-probing per card render would hammer the issuer hosts.
    private var cache: [String: VerifiedIssuer] = [:]

    func resolve(credential: Credential, candidateBaseURLs: [URL]) async -> VerifiedIssuer? {
        let did = credential.header.iss
        if let hit = cache[did] { return hit }

        // Reconstruct the exact bytes the issuer signed for the header. iOS keeps
        // only the decoded struct, so we re-encode + canonicalize (the header
        // schema is fixed, so the field set matches what the issuer signed).
        guard let headerBytes = Self.canonicalHeaderBytes(credential.header),
              let headerSig = Self.hexData(credential.headerSig) else { return nil }

        for base in candidateBaseURLs {
            guard let doc = await Self.fetchDoc(base: base) else { continue }
            guard doc.did == did else { continue } // not this credential's issuer

            // 2. doc self-signature over canonicalize(doc minus signature).
            var unsigned = doc.full
            unsigned.removeValue(forKey: "signature")
            guard let docBytes = try? ElabifyCore.canonicalize(unsigned),
                  MLDSAClient.verify(publicKey: doc.pubkey, signature: doc.signature, message: docBytes)
            else { return nil }

            // 3. the held credential's headerSig under the same key.
            guard MLDSAClient.verify(publicKey: doc.pubkey, signature: headerSig, message: headerBytes)
            else { return nil }

            let verified = VerifiedIssuer(did: did, humanLabel: doc.humanLabel, chain: doc.chain)
            cache[did] = verified
            return verified
        }
        return nil
    }

    // MARK: -- helpers

    private struct FetchedDoc {
        let full: [String: Any]
        let did: String
        let pubkey: Data
        let humanLabel: String
        let chain: String
        let signature: Data
    }

    private static func canonicalHeaderBytes(_ header: CredentialHeader) -> Data? {
        guard let raw = try? JSONEncoder().encode(header),
              let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        return try? ElabifyCore.canonicalize(dict)
    }

    private static func fetchDoc(base: URL) async -> FetchedDoc? {
        guard let url = URL(string: base.absoluteString + "/v1/issuer/well-known-doc") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let did = dict["did"] as? String,
              let pkHex = dict["mlDsaPubkey"] as? String, let pubkey = hexData(pkHex),
              let humanLabel = dict["humanLabel"] as? String,
              let chain = dict["chain"] as? String,
              let sigHex = dict["signature"] as? String, let signature = hexData(sigHex)
        else { return nil }
        return FetchedDoc(full: dict, did: did, pubkey: pubkey, humanLabel: humanLabel, chain: chain, signature: signature)
    }

    private static func hexData(_ hex: String) -> Data? {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}

/// CAIP-2 chain id -> friendly name (mirrors shared/networkLabels.ts).
func caip2Label(_ chain: String) -> String {
    switch chain {
    case "eip155:1": return "Ethereum mainnet"
    case "eip155:11155111": return "Sepolia"
    case "eip155:8453": return "Base"
    case "eip155:84532": return "Base Sepolia"
    case "eip155:31337": return "Local anvil"
    default: return chain
    }
}

/// De-duplicated, comma-joined friendly names for a set of CAIP-2 ids.
func caip2LabelList(_ chains: [String]) -> String {
    var seen = Set<String>()
    var out = [String]()
    for c in chains {
        let label = caip2Label(c)
        if seen.insert(label).inserted { out.append(label) }
    }
    return out.joined(separator: ", ")
}
