// Reading + writing the backup-related Keychain flags
// (verifiedAt, lastReminderAt, lockdownEnabled).
//
// Pulled out of `IdentitySandwich` and `HolderStore` so the UI layer
// can ask plain questions like `isVerified` and `shouldShowReminder`
// without dealing with Keychain plumbing.

import Foundation

enum BackupState {
    /// Unix-seconds. nil means "never".
    static var verifiedAt: Int64? {
        get { readInt(KeyStoreKeys.verifiedAt) }
    }

    /// Unix-seconds. nil means "never reminded".
    static var lastReminderAt: Int64? {
        get { readInt(KeyStoreKeys.lastReminderAt) }
    }

    /// True iff the user has irreversibly enabled Lockdown mode.
    static var lockdownEnabled: Bool {
        get { (try? KeyStore.load(forKey: KeyStoreKeys.lockdownEnabled)).flatMap { $0 } != nil }
    }

    /// True iff the user set a passphrase. Cached as a non-biometric
    /// flag so the UI can branch on it without a Face ID prompt.
    static var hasPassphrase: Bool {
        guard let data = (try? KeyStore.load(forKey: KeyStoreKeys.hasPassphrase)).flatMap({ $0 }) else { return false }
        return String(data: data, encoding: .utf8) == "1"
    }

    /// True iff the recovery phrase has been verified at least once.
    static var isVerified: Bool { verifiedAt != nil }

    /// True iff the wallet should nudge the user to verify: the phrase
    /// has never been verified AND either we have never reminded OR
    /// the last reminder was more than 7 days ago.
    static func shouldShowReminder(now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        if isVerified { return false }
        guard let last = lastReminderAt else { return true }
        return now - last >= 7 * 24 * 3600
    }

    static func markVerified(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let bytes = String(now).data(using: .utf8) ?? Data()
        try KeyStore.save(bytes, forKey: KeyStoreKeys.verifiedAt, requireBiometric: false)
    }

    static func markReminded(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let bytes = String(now).data(using: .utf8) ?? Data()
        try KeyStore.save(bytes, forKey: KeyStoreKeys.lastReminderAt, requireBiometric: false)
    }

    static func enableLockdown() throws {
        let bytes = "1".data(using: .utf8) ?? Data()
        try KeyStore.save(bytes, forKey: KeyStoreKeys.lockdownEnabled, requireBiometric: false)
    }

    private static func readInt(_ key: String) -> Int64? {
        // Swift 6 collapses `try? f()` where f returns Data? into a single
        // Optional, so one `guard let` unwraps the full chain.
        guard let data = try? KeyStore.load(forKey: key),
              let str = String(data: data, encoding: .utf8),
              let n = Int64(str) else { return nil }
        return n
    }
}
