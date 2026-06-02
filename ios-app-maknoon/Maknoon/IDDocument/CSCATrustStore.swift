// CSCA trust store for on-device Passive Authentication.
//
// Fetches the issuer's signed CSCA bundle (GET /v1/issuer/csca-bundle), verifies
// the issuer's ML-DSA-65 signature over the manifest (which commits to the
// bundle's SHA-256), and caches the concatenated-PEM CAFile on disk for
// NFCPassportReader's verifyPassport(masterListURL:). Throttled refresh.
//
// Trust model (v1, soft-badge): the bundle is fetched over TLS from a known
// issuer host and the manifest signature is self-consistent against the embedded
// issuer pubkey. The on-device verdict is advisory only; the issuer backend
// re-runs Passive Auth authoritatively at issuance. Hardening (pinning the
// issuer pubkey to the verified well-known doc / on-chain key) is a follow-up.

import Foundation
import CryptoKit
import ElabifyCore

actor CSCATrustStore {
    static let shared = CSCATrustStore()

    private let fm = FileManager.default
    private static let refreshIntervalSec: TimeInterval = 7 * 24 * 3600
    private static let versionKey = "csca.bundle.version"
    private static let refreshedAtKey = "csca.bundle.refreshedAt"
    private static let countKey = "csca.bundle.count"

    /// Directory + file for the cached CAFile (concatenated PEM).
    private var cacheDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("csca", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    private var cafilePath: URL { cacheDir.appendingPathComponent("csca-bundle.pem") }

    /// The cached CAFile URL if present (nil before the first successful fetch).
    var cafileURL: URL? {
        let url = cafilePath
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    var version: String? { UserDefaults.standard.string(forKey: Self.versionKey) }
    var lastRefreshedAt: Date? {
        let t = UserDefaults.standard.double(forKey: Self.refreshedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    var certCount: Int? {
        let c = UserDefaults.standard.integer(forKey: Self.countKey)
        return c > 0 ? c : nil
    }

    /// Fetch + verify + cache the bundle from a known issuer host. Throttled to
    /// once per refresh interval unless `force`. Returns true if a fresh bundle
    /// was installed. Failures are swallowed (keep any existing cache).
    @discardableResult
    func refresh(from baseURL: URL, force: Bool = false) async -> Bool {
        if !force, cafileURL != nil, let last = lastRefreshedAt,
           Date().timeIntervalSince(last) < Self.refreshIntervalSec {
            return false // cache is fresh enough
        }
        guard let url = URL(string: baseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/v1/issuer/csca-bundle") else {
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        guard let installed = installVerifiedBundle(from: data) else { return false }
        UserDefaults.standard.set(installed.version, forKey: Self.versionKey)
        UserDefaults.standard.set(installed.count, forKey: Self.countKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.refreshedAtKey)
        return true
    }

    /// Verify the signed bundle and write the CAFile. Returns (version, count)
    /// on success, nil on any verification failure.
    private func installVerifiedBundle(from data: Data) -> (version: String, count: Int)? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let manifest = top["manifest"] as? [String: Any],
              let pkHex = top["mlDsaPubkey"] as? String, let pubkey = Self.hexData(pkHex),
              let sigHex = top["signature"] as? String, let sig = Self.hexData(sigHex),
              let bundlePem = top["bundlePem"] as? String,
              let expectedSha = manifest["sha256"] as? String
        else { return nil }

        // 1. ML-DSA signature over canonicalize(manifest).
        guard let canonical = try? ElabifyCore.canonicalize(manifest),
              MLDSAClient.verify(publicKey: pubkey, signature: sig, message: canonical)
        else { return nil }

        // 2. The PEM must match the sha256 the manifest committed to.
        let digest = SHA256.hash(data: Data(bundlePem.utf8))
        let shaHex = digest.map { String(format: "%02x", $0) }.joined()
        guard shaHex == expectedSha.lowercased() else { return nil }

        // 3. Write the CAFile atomically.
        guard (try? Data(bundlePem.utf8).write(to: cafilePath, options: .atomic)) != nil else {
            return nil
        }
        let count = manifest["count"] as? Int ?? 0
        // Version label: prefer generatedAt; fall back to the sha prefix.
        let version = (manifest["generatedAt"] as? Int).map { "gen-\($0)" } ?? String(expectedSha.prefix(12))
        return (version, count)
    }

    private static func hexData(_ s: String) -> Data? {
        let h = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard h.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(h.count / 2)
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return Data(bytes)
    }
}
