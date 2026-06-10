// Maknoon Pay protocol-type tests (ADR-0031). Exercises the net-new commerce
// wrapper types' Codable + invariants without fabricating a full Presentation /
// VerifierRequest (those are covered elsewhere).

import XCTest
@testable import Maknoon

final class CommerceTests: XCTestCase {

    func testPaymentTermsRoundTrips() throws {
        let terms = PaymentTerms(
            fiatAmount: "12.50",
            fiatCode: "USD",
            acceptedRails: [
                PaymentRail(chain: "ethereum", network: "sepolia", asset: "USDC",
                            address: "0xabc0000000000000000000000000000000000001"),
                PaymentRail(chain: "bitcoin", network: "mainnet", asset: "BTC",
                            address: "bc1qexample"),
                PaymentRail(chain: "lightning", network: nil, asset: "sat",
                            address: "acct-1"),
            ],
            reference: "order-42",
            nonce: "0xdeadbeef",
            floorMinor: 5000,
            expiresAt: 1_900_000_000
        )
        let data = try JSONEncoder().encode(terms)
        let back = try JSONDecoder().decode(PaymentTerms.self, from: data)
        XCTAssertEqual(back.fiatAmount, "12.50")
        XCTAssertEqual(back.acceptedRails.count, 3)
        XCTAssertEqual(back.acceptedRails[0], terms.acceptedRails[0])
        XCTAssertNil(back.acceptedRails[2].network)          // Lightning has no network
        XCTAssertEqual(back.floorMinor, 5000)
        XCTAssertEqual(back.nonce, "0xdeadbeef")
    }

    func testLaneRawValues() throws {
        XCTAssertEqual(CommerceLane.tap.rawValue, "tap")
        XCTAssertEqual(CommerceLane.full.rawValue, "full")
        XCTAssertEqual(try JSONDecoder().decode(CommerceLane.self,
                       from: Data("\"full\"".utf8)), .full)
    }

    func testCommercePaymentOfflineVsOnline() throws {
        let offline = CommercePayment(
            rail: PaymentRail(chain: "ethereum", network: "sepolia", asset: "ETH",
                              address: "0xfee0000000000000000000000000000000000002"),
            signedTx: "0x02f8...signed", settlementRef: nil)
        let online = CommercePayment(
            rail: offline.rail, signedTx: nil, settlementRef: "0xhash123")

        let o1 = try JSONDecoder().decode(CommercePayment.self,
                    from: try JSONEncoder().encode(offline))
        let o2 = try JSONDecoder().decode(CommercePayment.self,
                    from: try JSONEncoder().encode(online))
        XCTAssertNotNil(o1.signedTx); XCTAssertNil(o1.settlementRef)   // offline path
        XCTAssertNil(o2.signedTx); XCTAssertNotNil(o2.settlementRef)   // online path
    }

    // MARK: -- EVM payment leg

    func testSmallestUnitsUSDCAndETH() throws {
        let usdc = CommerceEVMPayment.Asset(symbol: "USDC", contract: "0xUSDC", decimals: 6)
        // 12.50 USDC -> 12_500_000 base units (round-trips back to 12.5).
        XCTAssertEqual(try CommerceEVMPayment.smallestUnits("12.50", asset: usdc).units(decimals: 6),
                       Decimal(string: "12.5"))
        // 1 ETH -> 1e18 wei.
        XCTAssertEqual(try CommerceEVMPayment.smallestUnits("1", asset: .eth).units(decimals: 18),
                       Decimal(1))
        XCTAssertThrowsError(try CommerceEVMPayment.smallestUnits("0", asset: usdc))    // non-positive
        XCTAssertThrowsError(try CommerceEVMPayment.smallestUnits("abc", asset: usdc))  // unparseable
    }

    func testPlanFieldSemantics() throws {
        let usdc = CommerceEVMPayment.Asset(symbol: "USDC", contract: "0xCONTRACT", decimals: 6)
        let v = try CommerceEVMPayment.smallestUnits("5", asset: usdc)
        let erc = CommerceEVMPayment.plan(
            chainId: 11_155_111, nonce: 3, recipient: "0xRECIPIENT", value: v, asset: usdc,
            gasLimit: 90_000, maxFeePerGas: EthereumWeiValue(uint64: 100),
            maxPriorityFeePerGas: EthereumWeiValue(uint64: 2))
        XCTAssertEqual(erc.toAddress, "0xCONTRACT")            // ERC-20: tx `to` is the token contract
        if case .erc20(let r) = erc.payload { XCTAssertEqual(r, "0xRECIPIENT") }
        else { XCTFail("expected erc20 payload") }

        let nat = CommerceEVMPayment.plan(
            chainId: 11_155_111, nonce: 3, recipient: "0xRECIPIENT",
            value: EthereumWeiValue(uint64: 1_000), asset: .eth, gasLimit: 21_000,
            maxFeePerGas: EthereumWeiValue(uint64: 100),
            maxPriorityFeePerGas: EthereumWeiValue(uint64: 2))
        XCTAssertEqual(nat.toAddress, "0xRECIPIENT")           // native: tx `to` is the recipient
        if case .native = nat.payload {} else { XCTFail("expected native payload") }
    }

    // MARK: -- merchant accept policy

    private func makeReq(schemaAllow: [String]?, required: [String], rails: [PaymentRail],
                         nonce: String, maxAge: Int64?) -> CommerceRequest {
        let filter = VerifierFilter(
            issuers: nil,
            schemas: schemaAllow.map { VerifierFilterClause(mode: "allow", list: $0) },
            requiredClaims: required)
        let vr = VerifierRequest(
            v: 1, verifierDid: "did:elabify:merchant", verifierName: "Acme",
            verifierPublicKey: nil, requestId: "req-1", issuedAt: 1, expiresAt: 9_999_999_999,
            challenge: "0x00", filter: filter,
            response: VerifierResponseDirective(mode: "qrBack", callbackUrl: nil), signature: nil)
        let terms = PaymentTerms(
            fiatAmount: "10.00", fiatCode: "USD", acceptedRails: rails,
            reference: nil, nonce: nonce, floorMinor: nil, expiresAt: 9_999_999_999)
        return CommerceRequest(v: 1, verifierRequest: vr, paymentTerms: terms, lane: .full,
                               merchantName: "Acme", identityMaxAgeSec: maxAge, merchantSig: nil)
    }

    func testPolicyAcceptsMatching() {
        let rail = PaymentRail(chain: "ethereum", network: "sepolia", asset: "USDC", address: "0xMerchant")
        let now = Int64(Date().timeIntervalSince1970)
        let req = makeReq(schemaAllow: ["sch/sanctions"], required: ["sanctionsScreenedAt"],
                          rails: [rail], nonce: "0xnonce", maxAge: 31_536_000)
        let (reasons, missing) = CommerceMerchantPolicy.policyReasons(
            schema: "sch/sanctions", disclosedKeys: ["sanctionsScreenedAt"], rail: rail,
            responseNonce: "0xnonce",
            sanctions: CommerceMerchantPolicy.SanctionsDisclosure(result: "clean", screenedAt: ISO8601DateFormatter().string(from: Date())),
            request: req, nowSec: now)
        XCTAssertTrue(reasons.isEmpty, "unexpected reasons: \(reasons)")
        XCTAssertTrue(missing.isEmpty)
    }

    func testPolicyFlagsEveryViolation() {
        let rail = PaymentRail(chain: "ethereum", network: "sepolia", asset: "USDC", address: "0xMerchant")
        let other = PaymentRail(chain: "bitcoin", network: "mainnet", asset: "BTC", address: "bc1q")
        let now = Int64(Date().timeIntervalSince1970)
        let req = makeReq(schemaAllow: ["sch/sanctions"], required: ["sanctionsScreenedAt", "isPep"],
                          rails: [rail], nonce: "0xnonce", maxAge: 100)
        let (reasons, missing) = CommerceMerchantPolicy.policyReasons(
            schema: "sch/other", disclosedKeys: ["sanctionsScreenedAt"], rail: other,
            responseNonce: "0xWRONG",
            sanctions: CommerceMerchantPolicy.SanctionsDisclosure(result: "clean", screenedAt: "2000-01-01T00:00:00Z"),
            request: req, nowSec: now)
        XCTAssertTrue(reasons.contains("nonce_mismatch"))
        XCTAssertTrue(reasons.contains("wrong_schema"))
        XCTAssertTrue(reasons.contains("missing_claims"))
        XCTAssertEqual(missing, ["isPep"])
        XCTAssertTrue(reasons.contains("stale_screening"))
        XCTAssertTrue(reasons.contains("rail_not_accepted"))
    }

    func testRailAcceptedIsCaseInsensitiveOnAddress() {
        let a = PaymentRail(chain: "ethereum", network: "sepolia", asset: "USDC", address: "0xABCdef")
        let echoed = PaymentRail(chain: "ethereum", network: "sepolia", asset: "USDC", address: "0xabcDEF")
        XCTAssertTrue(CommerceMerchantPolicy.railAccepted(echoed, in: [a]))
        let wrongNet = PaymentRail(chain: "ethereum", network: "mainnet", asset: "USDC", address: "0xABCdef")
        XCTAssertFalse(CommerceMerchantPolicy.railAccepted(wrongNet, in: [a]))
    }

    // MARK: -- sanctions gate (passport sdnScreen)

    func testSdnScreenSanctionsGate() {
        let now = Int64(Date().timeIntervalSince1970)
        let iso = ISO8601DateFormatter().string(from: Date())

        // Extract from the passport `sdnScreen` object.
        let disclosed: [String: Any] = ["sdnScreen": ["result": "clean", "screenedAt": iso]]
        let s = CommerceMerchantPolicy.extractSanctions(fromDisclosed: disclosed)
        XCTAssertEqual(s?.result, "clean")
        XCTAssertEqual(s?.screenedAt, iso)

        // clean + fresh -> pass
        XCTAssertNil(CommerceMerchantPolicy.sanctionsReason(s, maxAgeSec: 31_536_000, nowSec: now))
        // sanctioned / pep -> blocked (fail-closed)
        XCTAssertEqual(CommerceMerchantPolicy.sanctionsReason(
            .init(result: "sanctioned", screenedAt: iso), maxAgeSec: 31_536_000, nowSec: now), "sanctioned")
        XCTAssertEqual(CommerceMerchantPolicy.sanctionsReason(
            .init(result: "pep", screenedAt: iso), maxAgeSec: 31_536_000, nowSec: now), "sanctioned")
        // clean but stale -> stale
        XCTAssertEqual(CommerceMerchantPolicy.sanctionsReason(
            .init(result: "clean", screenedAt: "2000-01-01T00:00:00Z"), maxAgeSec: 100, nowSec: now), "stale_screening")
        // gate requested but nothing disclosed -> fail-closed
        XCTAssertEqual(CommerceMerchantPolicy.sanctionsReason(nil, maxAgeSec: 100, nowSec: now), "stale_screening")
        // no gate requested -> pass
        XCTAssertNil(CommerceMerchantPolicy.sanctionsReason(nil, maxAgeSec: nil, nowSec: now))
        // legacy flat key is treated as a clean screen
        let legacy: [String: Any] = ["sanctionsScreenedAt": iso]
        XCTAssertEqual(CommerceMerchantPolicy.extractSanctions(fromDisclosed: legacy)?.result, "clean")
    }

    func testLooksLikeNameRejectsURLs() {
        XCTAssertTrue(ENSResolver.looksLikeName("vitalik.eth"))
        XCTAssertFalse(ENSResolver.looksLikeName("https://api.example.com/commerce"))
        XCTAssertFalse(ENSResolver.looksLikeName("ethereum:0xabc"))
        XCTAssertFalse(ENSResolver.looksLikeName("example.com/path"))
        XCTAssertFalse(ENSResolver.looksLikeName("0xABCDEF1234"))
    }
}
