// EVM payment leg for Maknoon Pay (ADR-0031). The holder assembles + signs a raw
// EIP-1559 transaction; the merchant broadcasts it (offline-capable: the holder
// can sign with a cached nonce/fee and the merchant broadcasts when next online).
//
// This is a thin orchestrator over the EXISTING send-path primitives so there is
// exactly one Ethereum signing path:
//   - EthereumWeiValue.fromUnits  (precise decimal -> smallest-unit parse)
//   - EthereumRPCClient           (nonce / fees / gas estimate / broadcast)
//   - EthereumDescriptors.signTransactionFromSandwich (TWC signing, key never escapes)
//   - EthereumABI.transferData    (ERC-20 transfer calldata, for gas estimation)

import Foundation

enum CommerceEVMPayment {
    enum Failure: LocalizedError {
        case badAmount
        case badRPCURL
        var errorDescription: String? {
            switch self {
            case .badAmount: return "Payment amount is not a positive number."
            case .badRPCURL: return "The network RPC URL is invalid."
            }
        }
    }

    /// An EVM asset on a chain. `contract == nil` means the native coin (ETH);
    /// otherwise it is an ERC-20 contract (e.g. USDC). `decimals`: ETH=18, USDC=6.
    struct Asset: Equatable, Sendable {
        let symbol: String
        let contract: String?
        let decimals: Int

        static let eth = Asset(symbol: "ETH", contract: nil, decimals: 18)
        var isNative: Bool { contract == nil }
    }

    /// Parse a human decimal amount into the asset's smallest unit (wei / token
    /// base units). Throws on non-positive or unparseable input.
    static func smallestUnits(_ amount: String, asset: Asset) throws -> EthereumWeiValue {
        guard let v = EthereumWeiValue.fromUnits(amount, decimals: asset.decimals), v > .zero else {
            throw Failure.badAmount
        }
        return v
    }

    /// Assemble the signer plan for (recipient, value, asset) given resolved chain
    /// params. Native: `toAddress` = recipient. ERC-20: `toAddress` = the token
    /// contract and the recipient rides in the `transfer(to,amount)` calldata
    /// (the encoder forces the tx `value` to zero for ERC-20).
    static func plan(
        chainId: UInt64, nonce: UInt64, recipient: String, value: EthereumWeiValue,
        asset: Asset, gasLimit: UInt64,
        maxFeePerGas: EthereumWeiValue, maxPriorityFeePerGas: EthereumWeiValue
    ) -> EthereumTxPlan {
        if let contract = asset.contract {
            return EthereumTxPlan(
                chainId: chainId, nonce: nonce, toAddress: contract, value: value,
                gasLimit: gasLimit, maxFeePerGas: maxFeePerGas,
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                payload: .erc20(recipient: recipient))
        }
        return EthereumTxPlan(
            chainId: chainId, nonce: nonce, toAddress: recipient, value: value,
            gasLimit: gasLimit, maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas, payload: .native)
    }

    /// Resolve chainId + nonce + fees + gas via RPC and assemble the unsigned
    /// EIP-1559 plan, WITHOUT signing. Shared by the software (sandwich) and
    /// hardware (Ledger) signing paths so both estimate fees identically.
    static func buildPlan(
        from: String, rpcURLString: String, recipient: String,
        amount: String, asset: Asset
    ) async throws -> EthereumTxPlan {
        guard let rpc = EthereumRPCClient(urlString: rpcURLString) else { throw Failure.badRPCURL }
        let value = try smallestUnits(amount, asset: asset)
        let chainId = try await rpc.chainId()
        let nonce = try await rpc.transactionCount(from, block: "pending")
        let priority = try await rpc.maxPriorityFeePerGas()
        let baseFee = try await rpc.nextBlockBaseFee()
        // 2x base fee headroom + the priority tip, the standard EIP-1559 ceiling.
        let maxFee = baseFee + baseFee + priority

        let estTo = asset.contract ?? recipient
        let estValue: EthereumWeiValue = asset.isNative ? value : .zero
        let estData: Data? = asset.isNative ? nil : EthereumABI.transferData(to: recipient, amount: value)
        let fallbackGas: UInt64 = asset.isNative ? 21_000 : 90_000
        let gasLimit = (try? await rpc.estimateGas(from: from, to: estTo, value: estValue, data: estData)) ?? fallbackGas

        return plan(chainId: chainId, nonce: nonce, recipient: recipient, value: value,
                    asset: asset, gasLimit: gasLimit, maxFeePerGas: maxFee,
                    maxPriorityFeePerGas: priority)
    }

    /// Online build for a SOFTWARE wallet: resolve the plan, then sign with the
    /// Trust-Wallet-Core key derived from the unlocked sandwich (needs biometric).
    /// Returns the raw signed transaction hex `eth_sendRawTransaction` expects.
    static func buildSignedTransfer(
        sandwich: IdentitySandwich, account: UInt32, from: String,
        rpcURLString: String, recipient: String, amount: String, asset: Asset,
        biometricReason: String
    ) async throws -> String {
        let p = try await buildPlan(from: from, rpcURLString: rpcURLString,
                                    recipient: recipient, amount: amount, asset: asset)
        return try EthereumDescriptors.signTransactionFromSandwich(
            sandwich: sandwich, account: account, plan: p, biometricReason: biometricReason)
    }

    /// Merchant broadcasts the holder's signed transaction. Returns the tx hash.
    static func broadcast(_ rawHex: String, rpcURLString: String) async throws -> String {
        guard let rpc = EthereumRPCClient(urlString: rpcURLString) else { throw Failure.badRPCURL }
        return try await rpc.sendRawTransaction(rawHex)
    }
}
