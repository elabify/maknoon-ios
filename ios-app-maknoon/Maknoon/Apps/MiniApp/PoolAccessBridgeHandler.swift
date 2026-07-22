// "poolAccess" namespace handler (window.maknoon.poolAccess).
//
// poolAccess.grant({ issuerUrl, issuerDid, chain, gateAddress? }) performs the whole
// credential-gated access grant NATIVELY, mirroring commerce.collectAndCharge
// (disclose + sign + submit in one confirm):
//   1. build a passport, sanctions-clean presentation (same stack as identity.request);
//   2. prove control of the active EVM address with an EIP-712 WalletControl signature;
//   3. POST both to the Access Issuer's /v1/networks/{chain}/access-issuer/grant, which
//      provisions the ONCHAINID + writes the ERC-735 claim (ADR-0058).
//
// This is an ISSUER action: verifying the credential is only the gate; writing on-chain
// access is issuance, so the WalletControl proof binds the ISSUER DID and the request
// goes to the issuer server (not the verifier). The presentation and all key material
// stay native; the mini-app JS only ever receives { granted, walletAddress, txHash,
// expiry }. The server, not the page, decides GRANT/DENY (it re-verifies both).

import Foundation
import ElabifyCore

@MainActor
final class PoolAccessBridgeHandler: MiniAppNamespaceHandler {
    let namespace = "poolAccess"
    // Discloses a credential, so it is gated by the identity permission (it also
    // uses the EVM wallet; registration additionally requires the evm grant).
    let requiredPermission: String? = "identity"

    private let store: HolderStore
    private let appTitle: String
    private let coordinator: MiniAppIdentityCoordinator
    /// Presents the pre-sign "Prepare Device" sheet for a hardware wallet, so a
    /// Trezor hidden wallet can supply its passphrase before the WalletControl
    /// signature; nil BLE prompt is what made a hidden wallet hang/throw.
    private let hardwareSignCoordinator: MiniAppHardwareSignCoordinator

    // The passport schema + sanctions claim the pool gate requires (personhood +
    // not-sanctioned; matches PASSPORT_SCHEMA_URI in the verifier's pool-access.ts).
    private static let passportSchema = "elabify://schema/global/passport/v1"
    private static let sdnClaim = "sdnScreen"

    init(store: HolderStore, appTitle: String, coordinator: MiniAppIdentityCoordinator,
         hardwareSignCoordinator: MiniAppHardwareSignCoordinator) {
        self.store = store
        self.appTitle = appTitle
        self.coordinator = coordinator
        self.hardwareSignCoordinator = hardwareSignCoordinator
    }

    func handle(method: String, params: Any?) async throws -> Any? {
        switch method {
        case "poolAccess.grant":
            return try await grant(params: params)
        default:
            throw MiniAppBridgeError.unsupported("poolAccess.\(method)")
        }
    }

    private func grant(params: Any?) async throws -> [String: Any] {
        // Issuer-centric params (ADR-0058). Legacy verifier* aliases are still
        // accepted so an already-published mini-app bundle keeps working.
        guard let opts = params as? [String: Any],
              let issuerURLString = (opts["issuerUrl"] as? String) ?? (opts["verifierUrl"] as? String),
              let issuerURL = URL(string: issuerURLString) else {
            throw MiniAppBridgeError.invalidParams("poolAccess.grant requires { issuerUrl }")
        }
        // Bound into both the presentation audience and the WalletControl proof; the
        // Access Issuer checks the proof against its own ELABIFY_ISSUER_DID.
        let issuerDid = (opts["issuerDid"] as? String) ?? (opts["verifierDid"] as? String) ?? "did:elabify:open"
        // CAIP-2 of the target chain whose ONCHAINID stack issues the access claim.
        let chain = (opts["chain"] as? String) ?? "eip155:84532"

        guard let sandwich = store.sandwich else {
            throw MiniAppBridgeError.unauthorized("wallet is locked")
        }

        // 1. A passport, sanctions-screened credential must exist.
        let requiredClaims = [Self.sdnClaim]
        let filter = VerifierFilter(
            issuers: nil,
            schemas: VerifierFilterClause(mode: "allow", list: [Self.passportSchema]),
            requiredClaims: requiredClaims
        )
        let matches = MatchingEngine.match(credentials: store.credentials, filter: filter)
        guard !matches.isEmpty else {
            LogStore.shared.info("MiniApp", "poolAccess.grant: no passport credential for \(appTitle)")
            return ["granted": false, "reason": "no_passport_credential"]
        }

        // 2. Resolve the active EVM wallet up front, so the consent sheet can show
        //    the exact address being shared and its permanent KYC association.
        guard let desc = store.ethereumWalletStore.activeWallet,
              let walletAddress = desc.address, !walletAddress.isEmpty else {
            throw MiniAppBridgeError.unauthorized("no active Ethereum wallet in this app")
        }

        // 3. Consent: the sheet shows the recipient host, the disclosed values
        //    (expanded), the wallet being shared + its permanence warning, the
        //    holder 0x per credential, then a credential pick + Face ID.
        let chosen = try await coordinator.present(
            appTitle: appTitle,
            purpose: "Verify to access the pool",
            requiredClaims: requiredClaims,
            maxAgeSec: nil,
            matches: matches,
            recipientHost: issuerURL.host,
            walletAddress: walletAddress,
            showsDisclosedValues: true
        )

        // 3. Server challenge -> signed presentation (we keep the raw presentation
        //    for the grant endpoint rather than calling /v1/verify). The challenge
        //    signature must bind the DID the server minted the challenge under
        //    (challengeSig is checked against the server's verifier DID), which can
        //    differ from the issuer DID used for the wallet-control proof below.
        let ch = try await VerifierClient.challenge(verifierBase: issuerURL, requestedClaims: requiredClaims)
        let presentation = try await PresentationFactory.build(
            credential: chosen,
            selectedClaims: Set(requiredClaims),
            challenge: ch.challenge,
            verifierDid: ch.verifierDid ?? issuerDid,
            pendingRequest: nil,
            store: store
        )

        // 4. EVM wallet-control proof (EIP-712), bound to this holder + presentation.
        //    (desc + walletAddress were resolved in step 2 for the consent sheet.)
        let typedDataJSON = Self.walletControlTypedData(
            holderDid: presentation.header.sub, verifierDid: issuerDid, nonce: presentation.challenge,
            walletAddress: walletAddress)
        // The proof is signed by the active wallet, software or hardware; the
        // Access Issuer verifies it identically (recover signer == wallet address).
        let signature: String
        do {
            switch desc.kind {
            case .software(let account):
                signature = try EthereumDescriptors.signTypedDataFromSandwich(
                    sandwich: sandwich, account: account, typedDataJSON: typedDataJSON,
                    biometricReason: "Prove you control this wallet for pool access")
            case .hardware(let deviceId, let account, _):
                guard let device = store.devices.find(id: deviceId) else {
                    throw MiniAppBridgeError.unauthorized("the paired device for this wallet was not found")
                }
                // Prepare the device (and collect the hidden-wallet passphrase)
                // before opening BLE, then sign the WalletControl proof with it.
                let hostPass = try await hardwareSignCoordinator.present(
                    device: device, purpose: .ethereumSign,
                    requiresPassphrase: desc.hidden?.needsHostPassphrase == true)
                defer { hardwareSignCoordinator.finish() }
                signature = try await EthereumMessageSigning.signTypedDataOverBLE(
                    device: device, account: account, typedDataJSON: typedDataJSON,
                    hidden: desc.hidden, hostEntered: hostPass)
            }
        } catch let e as MiniAppBridgeError {
            throw e
        } catch {
            throw MiniAppBridgeError.internalError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        // 5. Submit to the verifier's grant endpoint (writes the on-chain grant).
        let body = PoolAccessGrantRequest(
            v: 1,
            challengeContext: ChallengeContext(requestId: ch.requestId, issuedAt: ch.issuedAt, expiresAt: ch.expiresAt),
            presentation: presentation,
            ethProof: .init(walletAddress: walletAddress, signature: signature, addressType: "eoa")
        )
        // Access Issuer endpoint, per target chain. Encode the CAIP-2 colon so the
        // whole id is one path segment (the server decodeURIComponent's :caip2).
        let encodedChain = chain.replacingOccurrences(of: ":", with: "%3A")
        let base = issuerURL.absoluteString.hasSuffix("/")
            ? String(issuerURL.absoluteString.dropLast()) : issuerURL.absoluteString
        guard let grantURL = URL(string: "\(base)/v1/networks/\(encodedChain)/access-issuer/grant") else {
            throw MiniAppBridgeError.invalidParams("poolAccess.grant: bad issuerUrl/chain")
        }
        var post = URLRequest(url: grantURL)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONEncoder().encode(body)
        // The server does three sequential on-chain writes (create identity ->
        // register -> add claim). On slow chains (Sepolia ~12s blocks) that runs
        // well past URLSession's 60s default, so give the grant a generous ceiling.
        post.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: post)
        guard let http = resp as? HTTPURLResponse else {
            throw MiniAppBridgeError.internalError("no response from the verifier")
        }
        guard 200..<300 ~= http.statusCode else {
            let msg = (try? JSONDecoder().decode(PoolAccessErrorEnvelope.self, from: data))?.error.message
                ?? "pool-access grant failed (\(http.statusCode))"
            throw MiniAppBridgeError.internalError(msg)
        }
        let out = try JSONDecoder().decode(PoolAccessGrantResponse.self, from: data)
        LogStore.shared.info("MiniApp", "poolAccess.grant: decision \(out.decision ?? "?") for \(appTitle)")
        return [
            "granted": (out.decision == "GRANT"),
            "walletAddress": out.walletAddress ?? walletAddress,
            "txHash": out.txHash ?? NSNull(),
            "expiry": out.expiry.map { NSNumber(value: $0) } ?? NSNull(),
        ]
    }

    /// The exact eth_signTypedData_v4 JSON the verifier's verifyWalletControl
    /// re-derives: domain {name, version} only, WalletControl(holderDid, verifierDid, nonce).
    private static func walletControlTypedData(holderDid: String, verifierDid: String, nonce: String, walletAddress: String) -> String {
        let obj: [String: Any] = [
            "types": [
                "EIP712Domain": [
                    ["name": "name", "type": "string"],
                    ["name": "version", "type": "string"],
                ],
                // walletAddress binds the signed intent to the exact address being
                // registered (defense-in-depth). The issuer also accepts the legacy
                // 3-field struct during rollout (ADR-0065 hardening).
                "WalletControl": [
                    ["name": "holderDid", "type": "string"],
                    ["name": "verifierDid", "type": "string"],
                    ["name": "nonce", "type": "string"],
                    ["name": "walletAddress", "type": "string"],
                ],
            ],
            "primaryType": "WalletControl",
            "domain": ["name": "MaknoonPoolAccess", "version": "1"],
            "message": ["holderDid": holderDid, "verifierDid": verifierDid, "nonce": nonce, "walletAddress": walletAddress],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private struct PoolAccessGrantRequest: Codable {
    let v: Int
    let challengeContext: ChallengeContext
    let presentation: Presentation
    let ethProof: EthProof
    struct EthProof: Codable {
        let walletAddress: String
        let signature: String
        let addressType: String
    }
}

private struct PoolAccessGrantResponse: Codable {
    let decision: String?
    let walletAddress: String?
    let expiry: Int64?
    let txHash: String?
}

private struct PoolAccessErrorEnvelope: Codable {
    struct E: Codable { let code: String?; let message: String? }
    let error: E
}
