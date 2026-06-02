// Sparrow-style label store: a user-editable label per address and
// per transaction output (txid:vout). Backed by UserDefaults JSON.

import Foundation
import Observation

@Observable
final class BitcoinLabelStore {
    private(set) var addressLabels: [String: String] = [:]
    private(set) var outputLabels: [String: String] = [:]    // key = "txid:vout"

    // Persistence root under "networks.bitcoin.*".
    private static let addressKey = "networks.bitcoin.labels.address.v1"
    private static let outputKey  = "networks.bitcoin.labels.output.v1"

    init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.addressKey),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            addressLabels = m
        } else {
            addressLabels = [:]
        }
        if let data = UserDefaults.standard.data(forKey: Self.outputKey),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            outputLabels = m
        } else {
            outputLabels = [:]
        }
    }

    /// Re-read from UserDefaults after a backup restore.
    func reload() { load() }

    func label(forAddress addr: String) -> String? { addressLabels[addr] }
    func label(forOutput txid: String, vout: UInt32) -> String? {
        outputLabels["\(txid):\(vout)"]
    }

    func setLabel(_ label: String, forAddress addr: String) {
        addressLabels[addr] = label
        if let data = try? JSONEncoder().encode(addressLabels) {
            UserDefaults.standard.set(data, forKey: Self.addressKey)
        }
    }

    func setLabel(_ label: String, forOutput txid: String, vout: UInt32) {
        outputLabels["\(txid):\(vout)"] = label
        if let data = try? JSONEncoder().encode(outputLabels) {
            UserDefaults.standard.set(data, forKey: Self.outputKey)
        }
    }
}
