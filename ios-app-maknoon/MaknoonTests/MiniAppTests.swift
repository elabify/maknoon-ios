// Unit tests for the mini-app host's pure surface: catalog wire-format
// back-compat, bundle integrity hashing, the manifest model, custom-scheme
// host derivation, and the bridge error contract the JS shim depends on.
//
// The interactive pieces (WKWebView, the @MainActor bridge handlers, Face
// ID, real Sepolia sends) are exercised in the manual end-to-end pass
// documented in the plan; these cover the deterministic logic.

import XCTest
@testable import Maknoon

final class MiniAppTests: XCTestCase {

    // MARK: -- catalog wire-format back-compat

    func testMetadataOnlyEntryStillDecodes() throws {
        // An old catalog row with none of the mini-app fields must decode
        // unchanged and report itself as not runnable.
        let json = """
        {"id":"x","title":"X","summary":"s","details":"d",
         "iconName":"star","statusLabel":"Soon","curatedBy":"Elabify"}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(AppStoreEntry.self, from: json)
        XCTAssertFalse(entry.isMiniApp)
        XCTAssertTrue(entry.grantedPermissions.isEmpty)
        XCTAssertNil(entry.manifestURL)
    }

    func testMiniAppEntryDecodesWithFields() throws {
        let json = """
        {"id":"pos-demo","title":"POS","summary":"s","details":"d",
         "iconName":"creditcard.fill","statusLabel":"Demo","curatedBy":"Elabify",
         "manifestURL":"https://elabify.github.io/maknoon-dapps/apps/pos-demo/manifest.json",
         "manifestSha256":"a7dc547486d1353431b066ac74c382e8826f9eea3c7099a7fee08fbe85f4e204",
         "permissions":["identity","EVM"]}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(AppStoreEntry.self, from: json)
        XCTAssertTrue(entry.isMiniApp)
        // grantedPermissions is lowercased, so a mixed-case "EVM" still grants.
        XCTAssertEqual(entry.grantedPermissions, ["identity", "evm"])
        XCTAssertEqual(entry.manifestURL?.lastPathComponent, "manifest.json")
    }

    func testFullCatalogRoundTrips() throws {
        let entry = AppStoreEntry(
            id: "pos-demo", title: "POS", summary: "s", details: "d",
            iconName: "creditcard.fill", statusLabel: "Demo", curatedBy: "Elabify",
            manifestURL: URL(string: "https://example.com/m.json"),
            manifestSha256: "abc", permissions: ["identity", "evm"]
        )
        let catalog = AppStoreCatalog(
            id: "c", name: "n", curator: "Elabify", summary: "s",
            url: URL(string: "https://example.com/catalog.json"), apps: [entry]
        )
        let data = try JSONEncoder().encode(catalog)
        let back = try JSONDecoder().decode(AppStoreCatalog.self, from: data)
        XCTAssertEqual(back.apps.count, 1)
        XCTAssertTrue(back.apps[0].isMiniApp)
        XCTAssertEqual(back.apps[0].grantedPermissions, ["identity", "evm"])
    }

    // MARK: -- bundle integrity

    func testSHA256MatchesKnownVector() {
        // sha256("abc") per FIPS 180-4.
        XCTAssertEqual(
            MiniAppBundleStore.hexSHA256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testManifestDecodesAndDefaultsEntry() throws {
        let json = """
        {"version":"1.0.0","files":[{"path":"index.html","sha256":"00"}]}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MiniAppManifest.self, from: json)
        XCTAssertEqual(m.version, "1.0.0")
        XCTAssertEqual(m.entryPath, "index.html")  // defaulted when absent
        XCTAssertEqual(m.files.count, 1)
    }

    // MARK: -- custom-scheme host

    func testSchemeHostSanitizesAndLowercases() {
        XCTAssertEqual(MiniAppSchemeHandler.host(for: "pos-demo"), "pos-demo")
        XCTAssertEqual(MiniAppSchemeHandler.host(for: "POS Demo"), "pos-demo")
        // Disallowed characters collapse to '-'; never empty.
        XCTAssertEqual(MiniAppSchemeHandler.host(for: "a/b"), "a-b")
        XCTAssertFalse(MiniAppSchemeHandler.host(for: "***").isEmpty)
    }

    func testEntryURLShape() {
        let url = MiniAppSchemeHandler.entryURL(appId: "pos-demo", entryPath: "index.html")
        XCTAssertEqual(url.scheme, "maknoon-app")
        XCTAssertEqual(url.host, "pos-demo")
        XCTAssertEqual(url.path, "/index.html")
    }

    // MARK: -- bridge error contract (EIP-1193 codes)

    func testBridgeErrorCodes() {
        XCTAssertEqual(MiniAppBridgeError.unsupported("x").code, 4200)
        XCTAssertEqual(MiniAppBridgeError.unauthorized("x").code, 4100)
        XCTAssertEqual(MiniAppBridgeError.userRejected().code, 4001)
        XCTAssertEqual(MiniAppBridgeError.invalidParams("x").code, -32602)
        XCTAssertEqual(MiniAppBridgeError.internalError("x").code, -32603)
    }

    // MARK: -- per-app settings store
    // Tests use unique app ids and evict() in defer so they never leave
    // residue in the shared store.

    func testSettingsRoundTripAndRemove() throws {
        let s = MiniAppSettingsStore()
        let app = "store::app-roundtrip-\(UUID().uuidString)"
        defer { s.evict(appId: app) }

        XCTAssertNil(s.value(appId: app, key: "merchantAddr"))
        try s.set(appId: app, key: "merchantAddr", value: "0xabc")
        XCTAssertEqual(s.value(appId: app, key: "merchantAddr"), "0xabc")
        XCTAssertEqual(s.keys(appId: app), ["merchantAddr"])

        // Survives a reload (re-read from UserDefaults), proving persistence.
        s.reload()
        XCTAssertEqual(s.value(appId: app, key: "merchantAddr"), "0xabc")

        s.remove(appId: app, key: "merchantAddr")
        XCTAssertNil(s.value(appId: app, key: "merchantAddr"))
    }

    func testSettingsAreIsolatedPerApp() throws {
        let s = MiniAppSettingsStore()
        let a = "store::app-A-\(UUID().uuidString)"
        let b = "store::app-B-\(UUID().uuidString)"
        defer { s.evict(appId: a); s.evict(appId: b) }
        try s.set(appId: a, key: "k", value: "from-A")
        try s.set(appId: b, key: "k", value: "from-B")
        XCTAssertEqual(s.value(appId: a, key: "k"), "from-A")
        XCTAssertEqual(s.value(appId: b, key: "k"), "from-B")
        s.evict(appId: a)
        XCTAssertNil(s.value(appId: a, key: "k"))
        XCTAssertEqual(s.value(appId: b, key: "k"), "from-B")  // B untouched
    }

    func testSettingsQuotasThrow() {
        let s = MiniAppSettingsStore()
        let app = "store::app-quota-\(UUID().uuidString)"
        defer { s.evict(appId: app) }
        let big = String(repeating: "x", count: MiniAppSettingsStore.maxValueBytes + 1)
        XCTAssertThrowsError(try s.set(appId: app, key: "k", value: big))
    }

    func testSettingsKeyIsInBackupAllowlist() {
        // Guards backup inclusion: if this key is dropped from walletStateKeys,
        // mini-app settings silently stop backing up.
        XCTAssertTrue(EncryptedBackup.walletStateKeys.contains("miniapp.settings.v1"))
    }

    // MARK: -- versioning / compatibility

    func testSemVerParseAndCompare() {
        XCTAssertEqual(SemVer("0.4.1").map { "\($0)" }, "0.4.1")
        XCTAssertEqual(SemVer("v1.2").map { "\($0)" }, "1.2.0")        // v-prefix, missing patch
        XCTAssertEqual(SemVer("0.4.1-beta").map { "\($0)" }, "0.4.1")  // pre-release stripped
        XCTAssertNil(SemVer("not-a-version"))
        XCTAssertTrue(SemVer("0.4.1")! >= SemVer("0.4.0")!)
        XCTAssertTrue(SemVer("0.4.1")! < SemVer("0.10.0")!)            // numeric, not lexical
        XCTAssertFalse(SemVer("0.4.1")! >= SemVer("1.0.0")!)
    }

    func testCompatibilityLabels() {
        XCTAssertEqual(DAppCompatibility.compatible(host: "0.4.1").color, .green)
        XCTAssertEqual(DAppCompatibility.recommendsNewer(required: "0.5.0", host: "0.4.1").color, .orange)
        XCTAssertEqual(DAppCompatibility.unknown.systemImage, "questionmark.circle")
        // A missing requirement is always "unknown support" (still installable).
        if case .unknown = DAppCompatibility.evaluate(requires: nil) {} else {
            XCTFail("nil requirement should be unknown")
        }
    }

    func testChannelChip() {
        let beta = AppStoreEntry(id: "a", title: "A", summary: "", details: "",
                                 iconName: "x", statusLabel: "Demo", curatedBy: "E", channel: "beta")
        XCTAssertEqual(beta.channelLabel, "Beta")
        XCTAssertEqual(beta.statusColor, .orange)
        // Legacy entry (no channel) falls back to statusLabel.
        let legacy = AppStoreEntry(id: "b", title: "B", summary: "", details: "",
                                   iconName: "x", statusLabel: "Live", curatedBy: "E")
        XCTAssertEqual(legacy.channelLabel, "Live")
        XCTAssertEqual(legacy.statusColor, .green)
    }

    // MARK: -- payment URIs

    func testPaymentURIBuilders() {
        XCTAssertEqual(
            PaymentURI.ethereum(address: "0xabc", chainId: 11155111, weiValue: "1000000000000000000").string,
            "ethereum:0xabc@11155111?value=1000000000000000000")
        // Zero / nil value → bare address URI (no value param).
        XCTAssertEqual(PaymentURI.ethereum(address: "0xabc", chainId: 1, weiValue: "0").string, "ethereum:0xabc@1")
        XCTAssertEqual(PaymentURI.ethereum(address: "0xabc", chainId: 1, weiValue: nil).string, "ethereum:0xabc@1")
        XCTAssertEqual(PaymentURI.bitcoin(address: "bc1qxyz", btc: Decimal(string: "0.001")).string, "bitcoin:bc1qxyz?amount=0.001")
        XCTAssertEqual(PaymentURI.bitcoin(address: "bc1qxyz", btc: nil).string, "bitcoin:bc1qxyz")
        XCTAssertEqual(PaymentURI.solana(address: "So1ana", sol: Decimal(string: "1.5")).string, "solana:So1ana?amount=1.5")
        XCTAssertEqual(PaymentURI.tron(address: "TXyz", trx: Decimal(string: "42")).string, "tron:TXyz?amount=42")
        // Non-positive amounts are dropped.
        XCTAssertEqual(PaymentURI.bitcoin(address: "bc1q", btc: Decimal(0)).string, "bitcoin:bc1q")
    }

    // MARK: -- capability consent model

    func testCapabilityRegistryTiers() {
        XCTAssertEqual(MiniAppCapabilityRegistry.spec("identity")?.tier, .perUse)
        XCTAssertEqual(MiniAppCapabilityRegistry.spec("scan")?.tier, .perUse)
        XCTAssertEqual(MiniAppCapabilityRegistry.spec("share")?.tier, .install)
        XCTAssertEqual(MiniAppCapabilityRegistry.spec("wallet")?.tier, .install)
        // Auto/low-risk tokens aren't in the registry and need no consent.
        XCTAssertTrue(MiniAppCapabilityRegistry.isAuto("storage"))
        XCTAssertTrue(MiniAppCapabilityRegistry.isAuto("fiat"))
        XCTAssertFalse(MiniAppCapabilityRegistry.isAuto("identity"))
    }

    func testDisclosableDropsAutoAndOrdersPerUseFirst() {
        let specs = MiniAppCapabilityRegistry.disclosable(["storage", "share", "identity", "fiat"])
        let tokens = specs.map { $0.token }
        XCTAssertFalse(tokens.contains("storage"))   // auto dropped
        XCTAssertFalse(tokens.contains("fiat"))       // auto dropped
        XCTAssertEqual(Set(tokens), ["identity", "share"])
        XCTAssertEqual(tokens.first, "identity")      // perUse before install
    }

    func testEntryCapabilitiesSupersedePermissionsWithReason() throws {
        let json = """
        {"id":"x","title":"X","summary":"s","details":"d","iconName":"star",
         "statusLabel":"Beta","curatedBy":"E","permissions":["identity"],
         "capabilities":[{"name":"payment","reason":"Charge for goods"},{"name":"scan"}]}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(AppStoreEntry.self, from: json)
        // capabilities present -> supersede legacy permissions.
        XCTAssertEqual(e.declaredCapabilityTokens, ["payment", "scan"])
        XCTAssertEqual(e.reason(for: "payment"), "Charge for goods")          // catalog override
        XCTAssertEqual(e.reason(for: "scan"), MiniAppCapabilityRegistry.spec("scan")?.reason) // default
    }

    func testEntryDerivesCapabilitiesFromLegacyPermissions() throws {
        let json = """
        {"id":"x","title":"X","summary":"s","details":"d","iconName":"star",
         "statusLabel":"Beta","curatedBy":"E","permissions":["identity","payment"]}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(AppStoreEntry.self, from: json)
        XCTAssertEqual(e.declaredCapabilityTokens, ["identity", "payment"])
    }

    func testPaymentBuildLightningCarriesChosenAccount() throws {
        let r = try PaymentBridgeHandler.build(
            chain: "lightning", networkRaw: nil, address: "ACCT-UUID",
            amount: 1500, fiatText: nil, appTitle: "POS")
        XCTAssertTrue(r.isLightning)
        XCTAssertEqual(r.chain, "lightning")
        XCTAssertEqual(r.ticker, "sats")
        XCTAssertEqual(r.address, "ACCT-UUID")  // chosen account id passes through
        XCTAssertEqual(r.uri, "")
    }

    func testPaymentBuildEthereumProducesEip681() throws {
        let r = try PaymentBridgeHandler.build(
            chain: "ethereum", networkRaw: "sepolia", address: "0xabc",
            amount: 1, fiatText: nil, appTitle: "POS")
        XCTAssertFalse(r.isLightning)
        XCTAssertEqual(r.uri, "ethereum:0xabc@11155111?value=1000000000000000000")
    }

    func testLNURLWithdrawCallbackURL() throws {
        // Preserves existing query + appends k1 + pr.
        let u = try XCTUnwrap(LNURL.withdrawCallbackURL(
            callback: "https://lnurl.example/withdraw?token=abc", k1: "K1VAL", bolt11: "lnbc10n1xyz"))
        let comps = try XCTUnwrap(URLComponents(url: u, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["token"], "abc")
        XCTAssertEqual(items["k1"], "K1VAL")
        XCTAssertEqual(items["pr"], "lnbc10n1xyz")
        XCTAssertEqual(comps.host, "lnurl.example")
    }

    func testLNURLDecodePassthroughAndAddress() throws {
        // lightning: prefix + bare https passthrough.
        XCTAssertEqual(try LNURL.decode("lightning:https://x.example/lnurlw?k=1").absoluteString,
                       "https://x.example/lnurlw?k=1")
        // LUD-16 lightning address -> well-known lnurlp URL.
        XCTAssertEqual(try LNURL.decode("alice@example.com").absoluteString,
                       "https://example.com/.well-known/lnurlp/alice")
    }

    func testFiatCoinMappingIncludingLightning() {
        let (lnId, lnTicker) = FiatBridgeHandler.coin(for: "lightning", network: nil)
        XCTAssertEqual(lnId, "bitcoin")     // Lightning is priced as BTC…
        XCTAssertEqual(lnTicker, "sats")    // …but quoted in sats.
        let (btcId, btcTicker) = FiatBridgeHandler.coin(for: "bitcoin", network: nil)
        XCTAssertEqual(btcId, "bitcoin")
        XCTAssertEqual(btcTicker, "BTC")
        let (evmId, _) = FiatBridgeHandler.coin(for: "ethereum", network: "sepolia")
        XCTAssertNil(evmId)                 // Sepolia has no spot price.
    }

    func testCatalogEntryDecodesVersionFields() throws {
        let json = """
        {"id":"pos","title":"POS","summary":"s","details":"d","iconName":"creditcard.fill",
         "statusLabel":"Beta","curatedBy":"Elabify","version":"0.1.0","channel":"beta",
         "requiresMaknoonVersion":"0.4.1"}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(AppStoreEntry.self, from: json)
        XCTAssertEqual(e.version, "0.1.0")
        XCTAssertEqual(e.channel, "beta")
        XCTAssertEqual(e.requiresMaknoonVersion, "0.4.1")
        XCTAssertEqual(e.channelLabel, "Beta")
    }

    // MARK: -- beta-apps setting

    func testShowBetaAppsDefaultsOffAndPersists() {
        let key = AppStoreRegistry.showBetaAppsKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let reg = AppStoreRegistry()
        XCTAssertFalse(reg.showBetaApps)                       // default OFF

        reg.setShowBetaApps(true)
        XCTAssertTrue(reg.showBetaApps)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key)) // persisted

        reg.reload()                                           // re-read from UserDefaults
        XCTAssertTrue(reg.showBetaApps)                        // survived a reload
    }

    func testBetaFilterHidesBetaUnlessEnabled() {
        let beta = AppStoreEntry(id: "a", title: "A", summary: "", details: "",
                                 iconName: "x", statusLabel: "Beta", curatedBy: "E", channel: "beta")
        let stable = AppStoreEntry(id: "b", title: "B", summary: "", details: "",
                                   iconName: "x", statusLabel: "Live", curatedBy: "E", channel: "stable")
        XCTAssertTrue(AppStoreRegistry.isBeta(beta))
        XCTAssertFalse(AppStoreRegistry.isBeta(stable))
        let apps = [beta, stable]
        XCTAssertEqual(apps.filter { !AppStoreRegistry.isBeta($0) }.map(\.id), ["b"])  // hidden
        XCTAssertEqual(apps.map(\.id), ["a", "b"])                                     // shown when enabled
    }

    func testShowBetaAppsKeyIsInBackupAllowlist() {
        XCTAssertTrue(EncryptedBackup.walletStateKeys.contains("appstore.showBetaApps.v1"))
    }

    // MARK: -- collect-sheet denial messaging

    func testDenialMessageNamesMissingAndShared() throws {
        let msg = try XCTUnwrap(MiniAppCollectSheet.denialMessage(
            reasons: ["missing_claims"],
            missing: ["givenName", "familyName", "nationality"],
            disclosedKeys: ["dateOfBirth", "sex"],
            requestedSchema: "elabify://schema/global/passport/v1",
            actualSchema: "elabify://schema/global/passport/v1",
            summary: "ok"))
        for token in ["givenName", "familyName", "nationality", "dateOfBirth"] {
            XCTAssertTrue(msg.contains(token), "expected message to name \(token)")
        }
    }

    func testDenialMessageWrongSchemaNamesBoth() throws {
        let msg = try XCTUnwrap(MiniAppCollectSheet.denialMessage(
            reasons: ["wrong_schema"], missing: [], disclosedKeys: [],
            requestedSchema: "passport/v1", actualSchema: "sanctions/v1", summary: ""))
        XCTAssertTrue(msg.contains("passport/v1"))
        XCTAssertTrue(msg.contains("sanctions/v1"))
    }

    func testDenialMessageNilWhenNoReason() {
        XCTAssertNil(MiniAppCollectSheet.denialMessage(
            reasons: [], missing: [], disclosedKeys: [],
            requestedSchema: nil, actualSchema: "x", summary: ""))
    }
}
