// Minimal semantic-version parse/compare, plus the running Maknoon app
// version and a dApp-compatibility verdict for the catalog UI.
//
// A dApp catalog entry may declare `requiresMaknoonVersion` (e.g. "0.4.1").
// We compare it against this app's CFBundleShortVersionString to show a
// compatibility badge. Source/dev builds (ELABIFY_BUILD_COMMIT == "dev")
// and entries that omit the requirement are flagged "unknown support" but
// remain installable, per product intent.

import Foundation
import SwiftUI

struct SemVer: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parse "1.2.3", "v1.2", "0.4.1-beta" (pre-release/build suffix ignored).
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop any pre-release / build metadata.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let first = parts.first, let maj = first else { return nil }
        self.major = maj
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return a.patch < b.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

enum MaknoonVersion {
    /// Marketing version (CFBundleShortVersionString), e.g. "0.4.1".
    static var currentString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
    static var current: SemVer? { SemVer(currentString) }

    /// True for local/source builds where the version isn't a published one.
    static var isSourceBuild: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "ELABIFY_BUILD_COMMIT") as? String) == "dev"
    }
}

/// Compatibility of a dApp entry with the running Maknoon app.
enum DAppCompatibility {
    case compatible(host: String)
    case recommendsNewer(required: String, host: String)
    case unknown

    static func evaluate(requires entryRequirement: String?) -> DAppCompatibility {
        // Source builds: version isn't meaningful — flag unknown, still allow.
        if MaknoonVersion.isSourceBuild { return .unknown }
        guard let req = entryRequirement, let required = SemVer(req),
              let host = MaknoonVersion.current else {
            return .unknown
        }
        if host >= required { return .compatible(host: host.description) }
        return .recommendsNewer(required: required.description, host: host.description)
    }

    var label: String {
        switch self {
        case .compatible(let host):                  return "Compatible (Maknoon \(host))"
        case .recommendsNewer(let req, let host):    return "Recommends Maknoon \(req)+ (you have \(host))"
        case .unknown:                               return "Unknown support"
        }
    }

    var systemImage: String {
        switch self {
        case .compatible:      return "checkmark.seal.fill"
        case .recommendsNewer: return "exclamationmark.triangle.fill"
        case .unknown:         return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .compatible:      return .green
        case .recommendsNewer: return .orange
        case .unknown:         return .secondary
        }
    }
}

/// Inline compatibility badge for a dApp's `requiresMaknoonVersion`.
struct DAppCompatibilityRow: View {
    let requires: String?

    var body: some View {
        let c = DAppCompatibility.evaluate(requires: requires)
        Label {
            Text(c.label).font(.caption)
        } icon: {
            Image(systemName: c.systemImage)
        }
        .foregroundStyle(c.color)
    }
}
