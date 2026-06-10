// Maknoon Pay — the client-side, peer-to-peer "verify and pay" protocol
// (ADR-0031). These types COMPOSE around the canonical `VerifierRequest` and
// `Presentation` rather than mutating them, so the byte-for-byte canonicalization
// contract with the verifier server stays intact. The commerce exchange is
// Maknoon-to-Maknoon and serverless: the verifier server is NOT in this path.
//
// Two lanes share these types:
//   - .tap  : a compact (CBOR) sanctions-attribute presentation + an offline-
//             signed payment, exchanged in a single NFC tap (arm-then-tap consent).
//   - .full : full attribute disclosure reviewed on-screen, over QR + BLE.

import Foundation

/// One acceptable way for a merchant to be paid. The merchant fully specifies a
/// payable rail (it computes the fiat->crypto conversion and the RPC endpoint),
/// so the holder needs no rate logic and no network table: it signs `amount` of
/// `asset` to `address` and the merchant broadcasts via `rpcURL`.
struct PaymentRail: Codable, Sendable, Equatable {
    let chain: String         // "bitcoin" | "ethereum" | "solana" | "tron" | "lightning"
    let network: String?      // chain-specific network id, e.g. "sepolia" (nil for Lightning)
    let asset: String         // "ETH" | "USDC" | "BTC" | "SOL" | "TRX" | "sat" ...
    let address: String       // receiving address (or Lightning account ref)
    let amount: String?       // exact crypto amount to pay on this rail (merchant-computed)
    let assetContract: String? // ERC-20/SPL/TRC-20 contract; nil = native coin
    let assetDecimals: Int?   // token decimals; nil defaults to 18 (native EVM)
    let rpcURL: String?       // JSON-RPC endpoint for serverless signing + broadcast

    init(chain: String, network: String?, asset: String, address: String,
         amount: String? = nil, assetContract: String? = nil,
         assetDecimals: Int? = nil, rpcURL: String? = nil) {
        self.chain = chain; self.network = network; self.asset = asset
        self.address = address; self.amount = amount
        self.assetContract = assetContract; self.assetDecimals = assetDecimals
        self.rpcURL = rpcURL
    }
}

/// What the merchant wants paid, presented alongside the identity ask. Signed by
/// the merchant (see `CommerceRequest.merchantSig`) and bound to the identity
/// request via the shared `nonce`, which the holder echoes in its response.
struct PaymentTerms: Codable, Sendable {
    let fiatAmount: String          // decimal notional, e.g. "12.50"
    let fiatCode: String            // "USD" | "AED" ...
    let acceptedRails: [PaymentRail]
    let reference: String?          // merchant order reference
    let nonce: String               // 0x hex anti-replay token, echoed in the response
    let floorMinor: Int64?          // per-tap auto-approve ceiling, minor units of fiatCode
    let expiresAt: Int64            // unix seconds
    /// Merchant's ephemeral X-Wing public key (base64) the holder seals its
    /// response to, so the relay server stays blind (ADR-0031). Signed as part
    /// of paymentTerms via `merchantSig`. nil = legacy plaintext relay.
    let responseKey: String?

    init(fiatAmount: String, fiatCode: String, acceptedRails: [PaymentRail],
         reference: String?, nonce: String, floorMinor: Int64?, expiresAt: Int64,
         responseKey: String? = nil) {
        self.fiatAmount = fiatAmount; self.fiatCode = fiatCode; self.acceptedRails = acceptedRails
        self.reference = reference; self.nonce = nonce; self.floorMinor = floorMinor
        self.expiresAt = expiresAt; self.responseKey = responseKey
    }
}

extension PaymentRail {
    /// Human network label for display: a built-in EVM network's name when the
    /// id matches, else the raw id (custom RPCs), else the chain.
    var displayNetwork: String {
        if let n = network, !n.isEmpty {
            return EthereumNetwork(rawValue: n)?.displayName ?? n
        }
        return chain.capitalized
    }
}

extension PaymentTerms {
    /// Whether a meaningful (non-zero) fiat notional was provided. Testnets have
    /// no fiat rate, so the merchant sends an empty amount and we show crypto only.
    var hasFiatValue: Bool {
        let a = fiatAmount.trimmingCharacters(in: .whitespaces)
        return !a.isEmpty && (Double(a) ?? 0) > 0
    }
}

/// Which lane the merchant is offering for this transaction.
enum CommerceLane: String, Codable, Sendable {
    case tap        // compact sanctions attribute + offline-signed pay, single NFC tap
    case full       // full attribute review, one confirmation, over QR/BLE
}

/// Merchant -> holder. Wraps the (already self/registry-signed) identity request
/// and adds the payment ask. `merchantSig` is an ML-DSA-65 signature over
/// `canonicalize(paymentTerms)` by the merchant key, so the payment ask is
/// independently verifiable and bound to `verifierRequest.requestId`.
struct CommerceRequest: Codable, Sendable {
    let v: Int                      // 1
    let verifierRequest: VerifierRequest
    let paymentTerms: PaymentTerms
    let lane: CommerceLane
    let merchantName: String?
    /// Max age (seconds) for a freshness-gated attribute (e.g. a sanctions
    /// screening's `sanctionsScreenedAt`); nil disables the freshness gate.
    let identityMaxAgeSec: Int64?
    let merchantSig: String?
}

/// What the holder committed to pay.
struct CommercePayment: Codable, Sendable {
    let rail: PaymentRail
    /// Offline path: a fully-signed raw transaction (0x hex) the merchant
    /// broadcasts when next online. Mutually exclusive with `settlementRef`.
    let signedTx: String?
    /// Online path: a settlement reference already produced by the holder
    /// (an on-chain txHash, or a paid BOLT11). Mutually exclusive with `signedTx`.
    let settlementRef: String?
}

/// Holder -> merchant. The identity presentation plus the payment commitment,
/// bound back to the request via `nonce`.
struct CommerceResponse: Codable, Sendable {
    let v: Int                      // 1
    let presentation: Presentation
    let payment: CommercePayment
    let nonce: String               // echoes PaymentTerms.nonce
}
