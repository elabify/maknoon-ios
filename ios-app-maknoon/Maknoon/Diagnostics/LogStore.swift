// In-process diagnostic log buffer for troubleshooting. Ring-style
// retention of the last `maxEntries` events; call sites add via
// `LogStore.shared.info / warn / error`.
//
// CRITICAL SECURITY RULE, read before adding new log calls:
//
//   * NEVER log: BIP39 entropy, BIP39 mnemonic, sandwich passphrase,
//     AES wrap keys, sandwich master keys, raw private keys.
//   * It IS OK to log: chain addresses, tx hashes, RPC URLs, BLE
//     device serials / peripheral UUIDs, APDU status words, error
//     messages from URLSession / RPC / explorers, timestamps.
//
// The About → "Share diagnostic logs" affordance warns the user
// about exactly that public-but-sensitive information before
// invoking the iOS share sheet.

import Foundation

final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    enum Level: String, Sendable { case info, warn, error }

    struct Entry: Sendable {
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []
    private let maxEntries = 500

    // MARK: -- ingest

    func info(_ category: String, _ message: String) {
        log(level: .info, category: category, message: message)
    }
    func warn(_ category: String, _ message: String) {
        log(level: .warn, category: category, message: message)
    }
    func error(_ category: String, _ message: String) {
        log(level: .error, category: category, message: message)
    }

    private func log(level: Level, category: String, message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        lock.lock()
        defer { lock.unlock() }
        _entries.append(entry)
        if _entries.count > maxEntries {
            _entries.removeFirst(_entries.count - maxEntries)
        }
    }

    // MARK: -- read

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _entries.count
    }

    func clear() {
        lock.lock()
        _entries.removeAll()
        lock.unlock()
    }

    /// Text shape used by the About share-logs flow. One line per
    /// entry: ISO-8601 timestamp + level + category + message.
    /// Plain UTF-8 so AirDrop / Mail / Files all render cleanly.
    func formatted() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot = entries
        let header = "Maknoon diagnostic logs (\(snapshot.count) entries)\n"
            + "Generated: \(fmt.string(from: Date()))\n"
            + "Build: \((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?")"
            + " (\((Bundle.main.object(forInfoDictionaryKey: "ELABIFY_BUILD_COMMIT") as? String) ?? "dev"))\n"
            + "\n"
        let body = snapshot.map { e in
            "[\(fmt.string(from: e.timestamp))] [\(e.level.rawValue.uppercased())] [\(e.category)] \(e.message)"
        }.joined(separator: "\n")
        return header + body
    }
}
