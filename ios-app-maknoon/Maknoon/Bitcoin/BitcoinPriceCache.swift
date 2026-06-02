// Per-fiat BTC price cache backed by CoinGecko's simple/price endpoint.
// Aggressively cached so we stay under the free-tier rate limit.

import Foundation
import Observation

@Observable
final class BitcoinPriceCache: @unchecked Sendable {
    private(set) var priceByFiat: [String: Double] = [:]
    private(set) var lastFetchAt: [String: Date] = [:]
    private let ttl: TimeInterval = 5 * 60

    /// Returns the cached BTC price in the requested fiat. If the
    /// cache is older than `ttl`, kicks off an async refresh; the
    /// caller receives the stale value (or nil if there is none) on
    /// this call and the new value on the next render after the
    /// async fetch lands.
    func currentPrice(in fiat: String, baseURL: String) -> Double? {
        let key = fiat.lowercased()
        if let last = lastFetchAt[key], Date().timeIntervalSince(last) < ttl {
            return priceByFiat[key]
        }
        Task { @MainActor [weak self] in
            await self?.fetch(fiat: key, baseURL: baseURL)
        }
        return priceByFiat[key]
    }

    private func fetch(fiat: String, baseURL: String) async {
        let urlString = "\(baseURL)/simple/price?ids=bitcoin&vs_currencies=\(fiat)"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let bitcoin = json?["bitcoin"] as? [String: Any],
               let value = bitcoin[fiat] as? Double {
                priceByFiat[fiat] = value
                lastFetchAt[fiat] = Date()
            }
        } catch {
            // Soft-fail; UI hides the fiat row until the next refresh.
        }
    }
}
