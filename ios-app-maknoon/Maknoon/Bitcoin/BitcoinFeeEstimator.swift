// Mempool.space (or Esplora-compatible) recommended-fees client.
// Returns the four standard tiers used by Sparrow's fee picker:
// fastest, half-hour, hour, economy. Numbers are sats per vByte,
// rounded up.

import Foundation

struct FeeRecommended: Sendable, Codable {
    let fastestFee: UInt64
    let halfHourFee: UInt64
    let hourFee: UInt64
    let economyFee: UInt64
    let minimumFee: UInt64

    func satsPerVb(for mode: BitcoinSendView.FeeMode) -> UInt64 {
        switch mode {
        case .fastest:  return fastestFee
        case .halfHour: return halfHourFee
        case .hour:     return hourFee
        case .economy:  return economyFee
        case .custom:   return 0
        }
    }
}

enum BitcoinFeeEstimator {

    /// Returns the four recommended fee tiers from mempool.space at
    /// `<baseURL>/api/v1/fees/recommended`. Falls back to safe values
    /// if the network request fails so the Send view never blocks on
    /// the network.
    static func fetch(baseURL: String) async throws -> FeeRecommended {
        guard let url = URL(string: "\(baseURL)/api/v1/fees/recommended") else {
            return Self.fallback
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(FeeRecommended.self, from: data)
        } catch {
            return Self.fallback
        }
    }

    static let fallback = FeeRecommended(
        fastestFee: 25,
        halfHourFee: 10,
        hourFee: 5,
        economyFee: 2,
        minimumFee: 1
    )
}
