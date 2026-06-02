// Persists enrolled YubiKey records (credential id, label, enrolled-at)
// to UserDefaults JSON. Multiple keys supported so a user can keep a
// primary + backup pair on hand.
//
// Note: the actual cryptographic material (the AES-GCM-wrapped BIP39
// entropy + the hmac-secret salts) lives in the Keychain via KeyStore,
// not here. This file only tracks which keys are enrolled so the UI
// can render them.

import Foundation

enum YubiKeyEnrollment {

    struct Record: Codable, Identifiable, Hashable {
        let id: UUID
        let label: String
        /// Hex-encoded FIDO2 credential id assigned by the YubiKey.
        let credentialIdHex: String
        /// Unix-seconds at enrollment time.
        let enrolledAt: Int64

        init(id: UUID = UUID(), label: String, credentialIdHex: String, enrolledAt: Int64 = Int64(Date().timeIntervalSince1970)) {
            self.id = id
            self.label = label
            self.credentialIdHex = credentialIdHex
            self.enrolledAt = enrolledAt
        }
    }

    private static let key = "yubikey.enrollments.v1"

    static func load() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records
    }

    static func append(_ record: Record) {
        var current = load()
        current.append(record)
        persist(current)
    }

    static func remove(id: UUID) {
        var current = load()
        current.removeAll { $0.id == id }
        persist(current)
    }

    private static func persist(_ list: [Record]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
