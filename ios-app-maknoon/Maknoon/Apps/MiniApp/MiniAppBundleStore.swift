// Downloads, integrity-checks, caches, and locates mini-app bundles.
//
// A mini app is a set of static files (HTML/CSS/JS/images). Rather than
// ship a zip (Foundation has no public unzip and we avoid adding an SPM
// archive dependency in a wallet), a bundle is described by a
// `manifest.json` that lists every file with its SHA-256. Trust chains
// from a single hash the catalog curator pins (`AppStoreEntry.manifestSha256`):
//
//   catalog entry  --manifestSha256-->  manifest.json
//   manifest.json  --per-file sha256-->  each file
//
// Download flow (`ensureBundle`):
//   1. GET the manifest, verify sha256(bytes) == entry.manifestSha256.
//   2. For each listed file, GET it relative to the manifest directory,
//      verify its sha256, write it under the per-(app,version) cache dir.
//   3. Any mismatch, transport error, or path-traversal attempt aborts
//      the whole install and removes the partial dir. We never serve a
//      half-verified bundle.
//
// Cache layout (NOT user-visible, excluded from iCloud backup):
//   <AppSupport>/miniapps/<storeId>__<appId>/<version>/<files...>
//
// Re-download only happens when the version is absent from the cache, so
// opening an installed app offline serves the cached copy.

import Foundation
import CryptoKit

/// Wire format of a mini app's manifest.json.
struct MiniAppManifest: Codable, Sendable {
    /// App version string. Used as the cache-dir name; bump to force a
    /// re-download. Free-form but should be monotonic (e.g. "1.0.3").
    let version: String
    /// Relative path of the page WKWebView loads first. Defaults to
    /// "index.html" when omitted.
    let entry: String?
    /// Every file the bundle ships. Paths are relative, forward-slashed,
    /// and must stay inside the bundle (validated).
    let files: [FileEntry]

    struct FileEntry: Codable, Sendable {
        let path: String
        let sha256: String  // lowercase hex of the file bytes
    }

    var entryPath: String { entry ?? "index.html" }
}

/// On-disk, integrity-verified mini-app bundle ready to serve.
struct MiniAppBundle: Sendable {
    let appId: String
    let version: String
    /// Directory holding the verified files. Serve paths relative to here.
    let rootDir: URL
    let entryPath: String
}

enum MiniAppBundleError: LocalizedError {
    case badManifestURL
    case manifestHashMismatch
    case fileHashMismatch(String)
    case pathTraversal(String)
    case transport(String)
    case decode(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badManifestURL:        return "This app has no valid bundle URL."
        case .manifestHashMismatch:  return "The app manifest failed its integrity check."
        case .fileHashMismatch(let p): return "App file \(p) failed its integrity check."
        case .pathTraversal(let p):  return "App file path \(p) is not allowed."
        case .transport(let m):      return "Could not download the app: \(m)"
        case .decode(let m):         return "The app manifest is malformed: \(m)"
        case .empty:                 return "The app manifest lists no files."
        }
    }
}

actor MiniAppBundleStore {
    static let shared = MiniAppBundleStore()

    private static let category = "MiniApp"

    /// Root cache dir: <AppSupport>/miniapps. Created lazily.
    private func miniappsRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("miniapps", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func appCacheDir(installedAppId: String) throws -> URL {
        // installedAppId is "<storeId>::<appId>". Sanitize "::" and any
        // path-hostile characters into a flat directory name.
        let safe = installedAppId.replacingOccurrences(of: "::", with: "__")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return try miniappsRoot().appendingPathComponent(safe, isDirectory: true)
    }

    /// Return a ready-to-serve bundle for the installed app, downloading
    /// and verifying it if the pinned version is not already cached.
    func ensureBundle(
        installedAppId: String,
        appId: String,
        manifestURL: URL,
        manifestSha256: String
    ) async throws -> MiniAppBundle {
        let session = URLSession(configuration: .ephemeral)

        // 1. Fetch + pin the manifest.
        let manifestData = try await fetch(session: session, url: manifestURL)
        guard Self.hexSHA256(manifestData) == manifestSha256.lowercased() else {
            LogStore.shared.error(Self.category, "manifest hash mismatch for \(appId)")
            throw MiniAppBundleError.manifestHashMismatch
        }
        let manifest: MiniAppManifest
        do {
            manifest = try JSONDecoder().decode(MiniAppManifest.self, from: manifestData)
        } catch {
            throw MiniAppBundleError.decode(error.localizedDescription)
        }
        guard !manifest.files.isEmpty else { throw MiniAppBundleError.empty }

        let appDir = try appCacheDir(installedAppId: installedAppId)
        let versionDir = appDir.appendingPathComponent(sanitizeComponent(manifest.version), isDirectory: true)

        // Already cached + complete? Serve it without touching the network.
        if FileManager.default.fileExists(atPath: versionDir.appendingPathComponent(manifest.entryPath).path) {
            LogStore.shared.info(Self.category, "serving cached \(appId) v\(manifest.version)")
            return MiniAppBundle(appId: appId, version: manifest.version, rootDir: versionDir, entryPath: manifest.entryPath)
        }

        // 2. Download into a temp dir, verifying each file, then move into
        //    place atomically so a crash mid-download never leaves a
        //    partial bundle that looks complete.
        let tmpDir = appDir.appendingPathComponent(".tmp-\(sanitizeComponent(manifest.version))", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let manifestDir = manifestURL.deletingLastPathComponent()
        do {
            for file in manifest.files {
                let dest = try safeDestination(root: tmpDir, relativePath: file.path)
                let fileURL = manifestDir.appendingPathComponent(file.path)
                let data = try await fetch(session: session, url: fileURL)
                guard Self.hexSHA256(data) == file.sha256.lowercased() else {
                    throw MiniAppBundleError.fileHashMismatch(file.path)
                }
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: dest, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpDir)
            if let e = error as? MiniAppBundleError { throw e }
            throw MiniAppBundleError.transport(error.localizedDescription)
        }

        // Require the entry file to exist after verifying everything.
        guard FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(manifest.entryPath).path) else {
            try? FileManager.default.removeItem(at: tmpDir)
            throw MiniAppBundleError.fileHashMismatch(manifest.entryPath)
        }

        // 3. Swap temp -> versionDir.
        try? FileManager.default.removeItem(at: versionDir)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tmpDir, to: versionDir)
        excludeFromBackup(appDir)

        LogStore.shared.info(Self.category, "installed \(appId) v\(manifest.version), \(manifest.files.count) files")
        return MiniAppBundle(appId: appId, version: manifest.version, rootDir: versionDir, entryPath: manifest.entryPath)
    }

    /// Remove every cached version of an app (called on uninstall).
    func evict(installedAppId: String) {
        if let dir = try? appCacheDir(installedAppId: installedAppId) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: -- helpers

    private func fetch(session: URLSession, url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MiniAppBundleError.transport("HTTP \(code) for \(url.lastPathComponent)")
        }
        return data
    }

    /// Resolve `relativePath` under `root`, rejecting absolute paths,
    /// "..", and anything that escapes the bundle directory.
    private func safeDestination(root: URL, relativePath: String) throws -> URL {
        let comps = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !relativePath.hasPrefix("/"),
              !comps.contains(".."),
              !comps.contains("."),
              !comps.isEmpty else {
            throw MiniAppBundleError.pathTraversal(relativePath)
        }
        var dest = root
        for c in comps { dest = dest.appendingPathComponent(c) }
        // Final belt-and-suspenders: the resolved path must stay under root.
        let rootStd = root.standardizedFileURL.path
        let destStd = dest.standardizedFileURL.path
        guard destStd == rootStd || destStd.hasPrefix(rootStd + "/") else {
            throw MiniAppBundleError.pathTraversal(relativePath)
        }
        return dest
    }

    private func sanitizeComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        let cleaned = String(s.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "0" : cleaned
    }

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
