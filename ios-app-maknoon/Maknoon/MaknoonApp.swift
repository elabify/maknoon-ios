// PILOT-ONLY (Phase 0): iOS holder demo. The full M4b super-app per
// ../README.md uses TCA + MusnadSDK; this Phase C cut is the minimum
// surface needed to prove the Swift binding works end-to-end against
// the live Sepolia issuer + verifier at musnad.elabify.com.
// See ADR-0019 §"The supersession map".

import SwiftUI
import UIKit
import ReownWalletKit

/// App-wide interface-orientation gate. The onboarding flow locks the device
/// to portrait (the welcome screens are designed portrait-first); the rest of
/// the app keeps the default rotation behaviour. Read by [AppDelegate].
enum AppOrientation {
    /// When true, the app reports `.portrait` as its only supported
    /// orientation. Toggled by OnboardingView on appear / disappear.
    static var lockPortrait = false

    /// Ask UIKit to re-evaluate the supported orientations now (iOS 16+),
    /// so a device already held in landscape snaps back to portrait when the
    /// lock turns on (and is freed when it turns off).
    @MainActor
    static func apply() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = lockPortrait ? .portrait : .allButUpsideDown
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Minimal app delegate whose only job is to report the supported interface
/// orientations from [AppOrientation] (SwiftUI's App has no orientation hook).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientation.lockPortrait ? .portrait : .allButUpsideDown
    }
}

@main
struct MaknoonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = HolderStore()
    @State private var displayPrefs = DisplayPreferences()
    @State private var autoLock = AutoLockManager()
    @State private var bootError: String?

    var body: some Scene {
        WindowGroup {
            ManagedRootView()
                .environment(store)
                .environment(displayPrefs)
                .environment(autoLock)
                .preferredColorScheme(displayPrefs.resolvedColorScheme)
                .environment(\.locale, displayPrefs.language.locale ?? Locale.current)
                .modifier(LanguageLayoutDirectionModifier(language: displayPrefs.language))
                .walletConnectSheets()
                .onOpenURL { url in
                    guard url.scheme == "wc" else { return }
                    Task { await WalletConnectManager.shared.pair(uriString: url.absoluteString) }
                }
                .task {
                    autoLock.configure(timeoutSec: displayPrefs.autoLock.seconds)
                    await bootIdentity()
                    configureWalletConnect()
                }
                .onChange(of: displayPrefs.autoLock) { _, new in
                    autoLock.configure(timeoutSec: new.seconds)
                }
        }
    }

    /// Try to load the Identity Sandwich from Keychain on launch.
    /// Failures are surfaced via `bootError` so the user sees a clear
    /// banner instead of an empty-screen mystery.
    private func bootIdentity() async {
        #if DEBUG
        // ADR-0032: assert the second-factor wrap crypto is still
        // byte-identical to Android before any enroll / unlock is
        // trusted. Cheap, runs once at launch.
        SecondFactorWrap.runParitySelfTest()
        #endif
        wipeStaleKeychainOnFirstLaunchIfNeeded()
        do {
            _ = try store.loadIdentity()
        } catch {
            bootError = "Could not load identity from Keychain: \(error)"
        }
    }

    /// Configure WalletConnect (ADR-0049) and wire it to the existing wallet
    /// store + signer. The project ID comes from Info.plist (overridable in
    /// Settings later); the two closures keep the manager decoupled from the
    /// store. EVM-only; software wallets for signing in this build.
    private func configureWalletConnect() {
        let projectId = Bundle.main.object(forInfoDictionaryKey: "ELABIFY_WC_PROJECT_ID") as? String ?? ""
        let mgr = WalletConnectManager.shared
        // Optional self-hosted relay override (one relay across all networks).
        let relayHost = store.ethereumSettings.walletConnectRelayHost
        mgr.configureIfNeeded(projectId: projectId, relayHost: relayHost)
        mgr.evmAddressesProvider = { [store] in
            // Offer the ACTIVE wallet (the one WalletConnect was opened from), so
            // the dApp signs with exactly that wallet. Offering every wallet let
            // the dApp pick accounts[0] (often a different device), which routed
            // signing to the wrong hardware wallet. Fall back to all if there is
            // no cached active address yet.
            let active = store.ethereumWalletStore.activeWallet
            LogStore.shared.info("walletconnect", "offer active wallet: label=\(active?.label ?? "nil") kind=\(String(describing: active?.kind)) addr=\(active?.cachedAddress ?? "nil")")
            if let addr = active?.cachedAddress, !addr.isEmpty {
                return [addr]
            }
            return store.ethereumWalletStore.wallets.compactMap { $0.cachedAddress }.filter { !$0.isEmpty }
        }
        mgr.connectingWalletId = { [store] in
            store.ethereumWalletStore.activeWallet?.id.uuidString
        }
        mgr.walletRequiresHostPassphrase = { [store] address, walletId in
            guard let d = Self.resolveWallet(wallets: store.ethereumWalletStore.wallets, address: address, walletId: walletId) else { return false }
            return d.hidden?.needsHostPassphrase == true
        }
        mgr.signerContext = { [store] address, walletId in
            guard let d = Self.resolveWallet(wallets: store.ethereumWalletStore.wallets, address: address, walletId: walletId) else {
                return (nil, nil)
            }
            if case .hardware(let deviceId, _, _) = d.kind {
                return (d.label, store.devices.find(id: deviceId))
            }
            return (d.label, nil)
        }
        mgr.personalSign = { [store] message, address, walletId, hostPassphrase in
            guard let descriptor = Self.resolveWallet(wallets: store.ethereumWalletStore.wallets, address: address, walletId: walletId) else {
                LogStore.shared.warn("walletconnect", "sign: no wallet matches requested addr=\(address) walletId=\(walletId ?? "nil")")
                throw WalletConnectSignError.unknownAddress
            }
            LogStore.shared.info("walletconnect", "sign: reqAddr=\(address) resolved label=\(descriptor.label) kind=\(String(describing: descriptor.kind)) hidden=\(String(describing: descriptor.hidden))")
            // personal_sign carries the message as hex; fall back to UTF-8.
            let hex = message.hasPrefix("0x") ? String(message.dropFirst(2)) : message
            let data = Data(wcHexString: hex) ?? Data(message.utf8)
            switch descriptor.kind {
            case .software(let account):
                guard let sandwich = store.sandwich else { throw WalletConnectSignError.locked }
                return try EthereumDescriptors.signPersonalMessageFromSandwich(
                    sandwich: sandwich,
                    account: account,
                    message: data,
                    biometricReason: "Sign this message for the connected app"
                )
            case .hardware(let deviceId, let account, _):
                guard let device = store.devices.find(id: deviceId) else {
                    LogStore.shared.warn("walletconnect", "sign: descriptor deviceId=\(deviceId) not found in registry")
                    throw WalletConnectSignError.unknownAddress
                }
                LogStore.shared.info("walletconnect", "sign over BLE: device label=\(device.label) kind=\(String(describing: device.kind)) account=\(account)")
                // Ledger/Trezor EIP-191 over BLE; Trezor hidden-wallet passphrase
                // is applied via `hidden` + the host-typed passphrase. The user
                // confirms on the device screen.
                return try await EthereumMessageSigning.signOverBLE(
                    device: device,
                    account: account,
                    message: data,
                    hidden: descriptor.hidden,
                    hostEntered: hostPassphrase
                )
            }
        }
        mgr.sendTransaction = { [store] request, address, walletId, broadcast, hostPassphrase in
            try await Self.runWalletConnectTransaction(
                store: store, request: request, address: address,
                walletId: walletId, broadcast: broadcast, hostPassphrase: hostPassphrase
            )
        }
        mgr.isChainConfigured = { [store] chainId in
            Self.resolveNetwork(store: store, chainId: chainId) != nil
        }
        mgr.signTypedData = { [store] typedDataJSON, address, walletId, hostPassphrase in
            guard let descriptor = Self.resolveWallet(wallets: store.ethereumWalletStore.wallets, address: address, walletId: walletId) else {
                LogStore.shared.warn("walletconnect", "typedData: no wallet matches addr=\(address) walletId=\(walletId ?? "nil")")
                throw WalletConnectSignError.unknownAddress
            }
            LogStore.shared.info("walletconnect", "typedData: resolved label=\(descriptor.label) kind=\(String(describing: descriptor.kind))")
            switch descriptor.kind {
            case .software(let account):
                guard let sandwich = store.sandwich else { throw WalletConnectSignError.locked }
                return try EthereumDescriptors.signTypedDataFromSandwich(
                    sandwich: sandwich,
                    account: account,
                    typedDataJSON: typedDataJSON,
                    biometricReason: "Sign typed data for the connected app"
                )
            case .hardware(let deviceId, let account, _):
                guard let device = store.devices.find(id: deviceId) else {
                    throw WalletConnectSignError.unknownAddress
                }
                return try await EthereumMessageSigning.signTypedDataOverBLE(
                    device: device,
                    account: account,
                    typedDataJSON: typedDataJSON,
                    hidden: descriptor.hidden,
                    hostEntered: hostPassphrase
                )
            }
        }
    }

    /// Build, sign and (optionally) broadcast a WalletConnect transaction. Fills
    /// in whatever the dApp omitted (nonce, gas, fees) from the chain the request
    /// names, then runs the SAME software / hardware signer as the in-app send.
    @MainActor
    private static func runWalletConnectTransaction(
        store: HolderStore,
        request: Request,
        address: String,
        walletId: String?,
        broadcast: Bool,
        hostPassphrase: String?
    ) async throws -> String {
        guard let descriptor = resolveWallet(wallets: store.ethereumWalletStore.wallets, address: address, walletId: walletId) else {
            throw WalletConnectSignError.unknownAddress
        }
        guard let txs = try? request.params.get([WCEthTx].self), let tx = txs.first, let to = tx.to else {
            throw WalletConnectSignError.badTransaction
        }
        guard let chainId = UInt64(request.chainId.reference),
              let network = resolveNetwork(store: store, chainId: chainId) else {
            throw WalletConnectSignError.unsupportedChain(request.chainId.absoluteString)
        }
        let rpcURL = network.rpcURL
        let wallet = EthereumWallet(descriptor: descriptor)

        let value = (tx.value.flatMap { try? EthereumWeiValue(hex: $0) }) ?? .zero
        let data = tx.data.flatMap { Data(wcHexString: $0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0) } ?? Data()

        // Nonce: the WALLET owns nonce management, like MetaMask. A dApp's
        // suggested nonce is routinely stale (computed before our previous tx
        // landed), which causes "nonce too low". Always use the chain's current
        // pending count and ignore tx.nonce.
        let nonce = try await wallet.pendingNonce(rpcURL: rpcURL)

        // Gas: honor the dApp's limit (Uniswap sends one), else estimate.
        let gas: UInt64
        if let g = tx.gas ?? tx.gasLimit, let parsed = UInt64(Self.strip0x(g), radix: 16) {
            gas = parsed
        } else {
            gas = try await wallet.estimateGasUnits(to: to, value: value, data: data.isEmpty ? nil : data, rpcURL: rpcURL)
        }

        // Fees: honor EIP-1559 caps, else a legacy gasPrice (mapped to both
        // caps), else estimate the standard tier for this chain.
        let maxFee: EthereumWeiValue
        let maxPriority: EthereumWeiValue
        if let mf = tx.maxFeePerGas.flatMap({ try? EthereumWeiValue(hex: $0) }),
           let mp = tx.maxPriorityFeePerGas.flatMap({ try? EthereumWeiValue(hex: $0) }) {
            maxFee = mf; maxPriority = mp
        } else if let gp = tx.gasPrice.flatMap({ try? EthereumWeiValue(hex: $0) }) {
            maxFee = gp; maxPriority = gp
        } else {
            let tiers = try await EthereumGasEstimator.estimate(rpcURL: rpcURL)
            let std = tiers.first { $0.tier == .standard } ?? tiers[0]
            maxFee = std.maxFeePerGas; maxPriority = std.maxPriorityFeePerGas
        }

        let payload: EthereumTxPlan.Payload = data.isEmpty ? .native : .contractCall(data: data)
        let plan = EthereumTxPlan(
            chainId: chainId, nonce: nonce, toAddress: to, value: value,
            gasLimit: gas, maxFeePerGas: maxFee, maxPriorityFeePerGas: maxPriority,
            payload: payload
        )

        LogStore.shared.info("walletconnect", "tx: chain=\(chainId) to=\(to) wallet=\(descriptor.label) kind=\(String(describing: descriptor.kind)) gas=\(gas) broadcast=\(broadcast)")

        let rawTx: String
        switch descriptor.kind {
        case .software(let account):
            guard let sandwich = store.sandwich else { throw WalletConnectSignError.locked }
            _ = try await sandwich.recoveryMaterialFresh(localizedReason: "Authorize a \(network.displayName) transaction for the connected app")
            rawTx = try EthereumDescriptors.signTransactionFromSandwich(
                sandwich: sandwich, account: account, plan: plan,
                biometricReason: "Authorize a \(network.displayName) transaction for the connected app",
                expectedAddress: descriptor.address
            )
        case .hardware(let deviceId, let account, _):
            guard let device = store.devices.find(id: deviceId) else {
                throw WalletConnectSignError.unknownAddress
            }
            rawTx = try await EthereumHardwareTx.sign(
                plan: plan, device: device, account: account,
                hidden: descriptor.hidden, derivationPath: descriptor.derivationPath,
                hostEntered: hostPassphrase
            )
        }

        if broadcast {
            let hash = try await wallet.broadcast(rawTx: rawTx, rpcURL: rpcURL)
            LogStore.shared.info("walletconnect", "tx broadcast hash=\(hash)")
            // Show it immediately as pending in the wallet (same mechanism as the
            // in-app send), so a WalletConnect tx no longer needs a manual resync
            // to appear. The native value is shown; a token/contract swap carries
            // value 0, which is correct for the pending row.
            store.ethereumWalletStore.markPendingOutbound(
                senderWalletId: descriptor.id,
                txHash: hash,
                senderAddress: address,
                recipientAddress: to,
                weiValue: value.decimal.description
            )
            return hash
        }
        return rawTx
    }

    private static func strip0x(_ s: String) -> String {
        s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    }

    /// Resolve the network config (for the RPC URL) the dApp's chainId names,
    /// across built-in and user-defined custom networks. nil if the user has not
    /// configured that chain, so we never broadcast to an unknown endpoint.
    private static func resolveNetwork(store: HolderStore, chainId: UInt64) -> ResolvedNetwork? {
        if let builtin = EthereumNetwork.allCases.first(where: { $0.chainId == chainId }) {
            return store.ethereumWalletStore.resolve(.builtin(builtin), customs: store.ethereumCustomNetworks, settings: store.ethereumSettings)
        }
        if let custom = store.ethereumCustomNetworks.networks.first(where: { $0.chainId == chainId }) {
            return store.ethereumWalletStore.resolve(.custom(custom.id), customs: store.ethereumCustomNetworks, settings: store.ethereumSettings)
        }
        return nil
    }

    /// Resolve the wallet for a WalletConnect request. Prefer the wallet the
    /// session was bound to (by stable id) so two wallets sharing an address (a
    /// Ledger and a hidden-passphrase Trezor on the same seed) never get
    /// confused. Verify the bound wallet's address still matches the request;
    /// otherwise fall back to a plain address match for older, unbound sessions.
    private static func resolveWallet(
        wallets: [EthereumWalletDescriptor],
        address: String,
        walletId: String?
    ) -> EthereumWalletDescriptor? {
        if let walletId,
           let byId = wallets.first(where: { $0.id.uuidString == walletId }),
           (byId.cachedAddress ?? "").lowercased() == address.lowercased() {
            return byId
        }
        return wallets.first { ($0.cachedAddress ?? "").lowercased() == address.lowercased() }
    }

    /// Token under UserDefaults that survives only as long as the
    /// app's container does. iOS wipes UserDefaults on app deletion
    /// but leaves Keychain items intact, so on first launch after a
    /// fresh install this key is absent. When that happens, wipe the
    /// Keychain so we route through OnboardingView cleanly instead
    /// of silently adopting a previous install's identity. The
    /// token is a UUID rather than a bool so reinstall + restore-
    /// from-backup flows are unambiguous in diagnostic logs.
    private static let firstLaunchTokenKey = "maknoon.appInstallToken.v1"

    private func wipeStaleKeychainOnFirstLaunchIfNeeded() {
        guard UserDefaults.standard.string(forKey: Self.firstLaunchTokenKey) == nil else {
            return
        }
        do {
            try IdentitySandwich.wipe()
            LogStore.shared.info("launch", "first launch after install detected; wiped stale Keychain items")
        } catch {
            LogStore.shared.warn("launch", "first-launch Keychain wipe failed: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.firstLaunchTokenKey)
    }
}

enum WalletConnectSignError: LocalizedError {
    case unknownAddress, hardwareUnsupported, locked, badTransaction
    case unsupportedChain(String)
    var errorDescription: String? {
        switch self {
        case .unknownAddress: return "That address is not one of your wallets."
        case .hardwareUnsupported: return "WalletConnect signing supports software wallets in this build; hardware support is coming."
        case .locked: return "Your wallet is locked. Unlock it and try again."
        case .badTransaction: return "The app sent a transaction this wallet could not read."
        case .unsupportedChain(let chain): return "This wallet has no network configured for \(chain). Add it under the Ethereum network settings, then try again."
        }
    }
}

private extension Data {
    init?(wcHexString hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self = Data(bytes)
    }
}

/// Forced LTR/RTL only when the user explicitly picked Arabic;
/// everything else inherits SwiftUI's locale-driven default. Kept
/// as a modifier so we don't sprinkle conditional environments
/// throughout the App body.
private struct LanguageLayoutDirectionModifier: ViewModifier {
    let language: AppLanguage

    func body(content: Content) -> some View {
        if let direction = language.layoutDirection {
            content.environment(\.layoutDirection, direction)
        } else {
            content
        }
    }
}

/// Holds the auto-lock + privacy-curtain + scene-phase plumbing
/// around the RootView. Pulled out so MaknoonApp.body stays a clean
/// description of "what's wired", and the lock/curtain logic has
/// somewhere isolated to read.
struct ManagedRootView: View {
    @Environment(HolderStore.self) private var store
    @Environment(DisplayPreferences.self) private var prefs
    @Environment(AutoLockManager.self) private var autoLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RootView()
                // Re-root the whole UI when the app language changes so every
                // view (incl. UIKit-bridged navigation titles + tab items, which
                // don't re-resolve on a pure .environment(\.locale) change) rebuilds
                // against the new locale. This is the "soft restart" that makes a
                // language switch apply everywhere without quitting the app. Placed
                // on RootView (not ManagedRootView) so the App-level .task /
                // auto-lock config do not re-run; only the visible UI rebuilds.
                .id(prefs.language)
                // Touch-event tracking is handled by ActivityTrackingHost
                // at the UIKit layer (window.sendEvent override). See
                // ActivityTrackingHost.swift. Doing it here as a
                // SwiftUI simultaneousGesture(DragGesture(minimumDistance: 0))
                // interfered with NavigationStack's back-button tap
                // handling on iOS 26: after certain state changes
                // (e.g. removing a credential) the back arrow stopped
                // responding and the destination view never popped.
                .background(ActivityTrackingHost(onTouch: { autoLock.recordActivity() }))

            // Privacy curtain sits above the live UI but below the
            // lock screen. Hides wallet balances + credential cards
            // from the iOS task-switcher snapshot when the app goes
            // inactive.
            if autoLock.showCurtain && !autoLock.isLocked {
                PrivacyCurtain()
                    .transition(.opacity)
            }

            // Lock screen sits on top of everything when an idle
            // timeout has fired. Driven by AutoLockManager;
            // dismissed only by successful biometric.
            if autoLock.isLocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: autoLock.isLocked)
        .animation(.easeOut(duration: 0.15), value: autoLock.showCurtain)
        .onChange(of: scenePhase) { _, new in
            switch new {
            case .background, .inactive:
                autoLock.appWillResignActive()
                // Theme uses Automatic mode? Refresh now so when we
                // come back, the cached value reflects the right
                // half of the day.
                prefs.refreshResolvedColorScheme()
            case .active:
                autoLock.appDidBecomeActive()
                prefs.refreshResolvedColorScheme()
            @unknown default:
                break
            }
        }
    }
}

/// Routes between OnboardingView and the main ContentView. A
/// hardware-wrapped sandwich no longer blocks app launch; the
/// wallet, credentials browsing, and other non-identity ops stay
/// available. Identity-dependent operations (presenting a
/// credential, renewing a delegation, revealing the recovery
/// phrase) trigger the hardware-unlock sheet on demand from
/// inside ContentView.
struct RootView: View {
    @Environment(HolderStore.self) private var store

    var body: some View {
        // OnboardingView only when there's nothing on disk at all.
        // A wrapped (locked) sandwich is "provisioned": the user
        // already onboarded, they just need to unlock for identity
        // ops.
        if store.isCompletingOnboarding
            || (store.sandwich == nil && !store.isIdentityLocked) {
            // Keep onboarding on screen through the post-identity steps
            // (passport scan, first wallet) even though the sandwich has
            // already been adopted so those steps can sign / create a wallet.
            OnboardingView()
        } else {
            ContentView()
        }
    }
}
