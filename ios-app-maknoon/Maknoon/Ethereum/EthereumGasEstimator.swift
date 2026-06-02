// Three-tier EIP-1559 gas estimator. Pulls the next-block base fee
// and the network's priority-fee suggestion from the RPC, then
// produces Slow / Standard / Fast cuts. Mirrors the pattern Sparrow
// uses on the Bitcoin side: one estimator type, three labelled
// outputs the UI can render in a segmented picker.
//
// Multipliers are tuned for a holder app, not a high-frequency
// trader: Standard prioritises landing in the next ~1-2 blocks
// without overpaying; Fast deliberately overbids the suggested tip
// to absorb spikes between estimate and broadcast.

import Foundation

struct EthereumGasEstimator: Sendable {
    enum Tier: String, CaseIterable, Identifiable, Sendable {
        case slow = "Slow"
        case standard = "Standard"
        case fast = "Fast"
        var id: String { rawValue }
    }

    struct Estimate: Sendable, Equatable {
        let tier: Tier
        let baseFeePerGas: EthereumWeiValue
        let maxPriorityFeePerGas: EthereumWeiValue
        let maxFeePerGas: EthereumWeiValue
    }

    /// Pulls baseFee + tip from RPC, returns all three tiers.
    static func estimate(rpcURL: String) async throws -> [Estimate] {
        guard let client = EthereumRPCClient(urlString: rpcURL) else {
            throw EthereumRPCClient.Error.malformedResponse("Bad RPC URL")
        }
        let baseFee = try await client.nextBlockBaseFee()
        let tip: EthereumWeiValue
        do {
            tip = try await client.maxPriorityFeePerGas()
        } catch {
            // Some chains (older Polygon RPCs, niche L2s) reject
            // eth_maxPriorityFeePerGas. 2 gwei is a reasonable
            // floor; users can pick Fast if it underdelivers.
            tip = EthereumWeiValue.fromGwei("2") ?? .zero
        }
        return tiers(baseFee: baseFee, tip: tip)
    }

    private static func tiers(
        baseFee: EthereumWeiValue,
        tip: EthereumWeiValue
    ) -> [Estimate] {
        let slowTip = scale(tip, percent: 80)
        let stdTip = tip
        let fastTip = scale(tip, percent: 150)

        // maxFeePerGas = 2 × baseFee + tip is the EIP-1559 textbook
        // "should land soon" cap. Slow drops baseFee multiplier to
        // 1.25× to save fees at the cost of latency; Fast bumps to
        // 3× for headroom against base-fee spikes.
        let slowMax  = scale(baseFee, percent: 125) + slowTip
        let stdMax   = scale(baseFee, percent: 200) + stdTip
        let fastMax  = scale(baseFee, percent: 300) + fastTip

        return [
            Estimate(tier: .slow,     baseFeePerGas: baseFee, maxPriorityFeePerGas: slowTip, maxFeePerGas: slowMax),
            Estimate(tier: .standard, baseFeePerGas: baseFee, maxPriorityFeePerGas: stdTip,  maxFeePerGas: stdMax),
            Estimate(tier: .fast,     baseFeePerGas: baseFee, maxPriorityFeePerGas: fastTip, maxFeePerGas: fastMax),
        ]
    }

    /// Multiply a wei value by an integer percentage. 80% = ×0.8.
    private static func scale(_ v: EthereumWeiValue, percent: Int) -> EthereumWeiValue {
        let pct = EthereumWeiValue(decimal: Decimal(percent))
        let hundred = EthereumWeiValue(decimal: Decimal(100))
        let scaled = v * pct
        return EthereumWeiValue(decimal: scaled.decimal / hundred.decimal)
    }
}
