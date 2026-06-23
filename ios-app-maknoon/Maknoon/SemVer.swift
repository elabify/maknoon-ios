// Minimal semantic-version parse/compare, plus the running Maknoon app
// version and a app-compatibility verdict for the catalog UI.
//
// A app catalog entry may declare `requiresMaknoonVersion` (e.g. "0.4.1").
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

/// Compatibility of a app entry with the running Maknoon app. The entry may
/// declare a lower bound (`requiresMaknoonVersion`, min host) AND an upper bound
/// (`supersededAtMaknoonVersion`, the host version at/above which this app
/// version is no longer supported). Compatible iff required <= host < superseded.
enum DAppCompatibility {
    case compatible(host: String)
    case recommendsNewer(required: String, host: String)
    /// Host is at or beyond the version where this app version was superseded
    /// (the app needs an update for this newer Maknoon).
    case superseded(supersededAt: String, host: String)
    case unknown

    static func evaluate(requires entryRequirement: String?, supersededAt: String? = nil) -> DAppCompatibility {
        // Evaluate against the REAL parsed marketing version
        // (CFBundleShortVersionString) regardless of isSourceBuild: a local
        // 0.6.0 build is still a 0.6.0 host. We only fall back to .unknown when
        // the entry declares no bounds or the host version cannot be parsed.
        guard let host = MaknoonVersion.current else { return .unknown }
        if let req = entryRequirement, let required = SemVer(req), host < required {
            return .recommendsNewer(required: required.description, host: host.description)
        }
        if let sup = supersededAt, let superseded = SemVer(sup), host >= superseded {
            return .superseded(supersededAt: superseded.description, host: host.description)
        }
        if entryRequirement == nil && supersededAt == nil { return .unknown }
        return .compatible(host: host.description)
    }

    /// Block a fresh install: the host is below the min or at/above the upper bound.
    var blocksInstall: Bool {
        switch self {
        case .recommendsNewer, .superseded: return true
        case .compatible, .unknown:         return false
        }
    }

    /// Warn (non-blocking) when an already-installed app is opened on a host that
    /// has since moved out of the supported range.
    var warnsAtOpen: Bool { blocksInstall }

    var label: String {
        switch self {
        case .compatible(let host):                  return "Compatible (Maknoon \(host))"
        case .recommendsNewer(let req, let host):    return "Requires Maknoon \(req) (you have \(host))"
        case .superseded(let sup, let host):         return "Needs an update for Maknoon \(host) (superseded at \(sup))"
        case .unknown:                               return "Unknown support"
        }
    }

    var systemImage: String {
        switch self {
        case .compatible:      return "checkmark.seal.fill"
        case .recommendsNewer: return "exclamationmark.triangle.fill"
        case .superseded:      return "exclamationmark.triangle.fill"
        case .unknown:         return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .compatible:      return .green
        case .recommendsNewer: return .orange
        case .superseded:      return .orange
        case .unknown:         return .secondary
        }
    }
}

/// Inline compatibility badge for a app's version bounds.
struct DAppCompatibilityRow: View {
    let requires: String?
    var supersededAt: String? = nil

    var body: some View {
        let c = DAppCompatibility.evaluate(requires: requires, supersededAt: supersededAt)
        Label {
            Text(c.label).font(.caption)
        } icon: {
            Image(systemName: c.systemImage)
        }
        .foregroundStyle(c.color)
    }
}
