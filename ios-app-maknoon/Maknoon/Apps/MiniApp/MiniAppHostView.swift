// Hosts a mini app in a sandboxed WKWebView.
//
// Lifecycle: on appear we ensure the bundle is downloaded + verified
// (MiniAppBundleStore), then build a WKWebView whose configuration:
//   * uses a NON-persistent (ephemeral) data store, so an app's
//     localStorage / cookies never persist or leak across apps;
//   * registers MiniAppSchemeHandler for the maknoon-app:// scheme, so
//     the page can only load files we integrity-checked;
//   * injects MiniAppProvider.js at document start (window.ethereum +
//     window.maknoon);
//   * registers the MiniAppBridge reply handler ("maknoonBridge").
// We then load maknoon-app://<appId>/<entry>.
//
// The host app's privacy curtain (ManagedRootView) already covers the
// whole window on backgrounding, so the WebView is hidden with everything
// else; no extra handling needed here.

import SwiftUI
import WebKit

struct MiniAppHostView: View {
    let app: AppStoreRegistry.InstalledApp
    @Environment(HolderStore.self) private var store
    @Environment(DisplayPreferences.self) private var displayPrefs
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var compatWarningDismissed = false
    @State private var updateNoticeDismissed = false
    /// Set when the user taps "Update": the newer entry to load in place of the
    /// install-time snapshot for the rest of this session. The persisted pin is
    /// swapped by AppStoreRegistry.applyUpdate; this just drives the reload.
    @State private var effectiveEntry: AppStoreEntry?
    @State private var identityCoordinator = MiniAppIdentityCoordinator()
    @State private var collectCoordinator = MiniAppCollectCoordinator()
    @State private var web3Coordinator = MiniAppWeb3Coordinator()
    @State private var paymentCoordinator = MiniAppPaymentCoordinator()
    @State private var scanCoordinator = MiniAppScanCoordinator()
    @State private var commerceCoordinator = MiniAppCommerceCoordinator()
    @State private var openWalletCoordinator = MiniAppOpenWalletCoordinator()

    private enum Phase {
        case loading
        case ready(MiniAppBundle)
        case failed(String)
    }

    /// The entry currently in effect: the newer one adopted this session (after
    /// an in-app Update), else the install-time snapshot.
    private var currentEntry: AppStoreEntry { effectiveEntry ?? app.entry }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(currentEntry.title)…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                ContentUnavailableView {
                    Label("Could not open app", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            case .ready(let bundle):
                MiniAppWebView(
                    app: app, bundle: bundle, store: store,
                    appLocaleIdentifier: displayPrefs.language.locale?.identifier ?? Locale.current.identifier,
                    identityCoordinator: identityCoordinator,
                    collectCoordinator: collectCoordinator,
                    web3Coordinator: web3Coordinator,
                    paymentCoordinator: paymentCoordinator,
                    scanCoordinator: scanCoordinator,
                    commerceCoordinator: commerceCoordinator,
                    openWalletCoordinator: openWalletCoordinator
                )
                .ignoresSafeArea(.container, edges: .bottom)
                // Re-key on the bundle dir so adopting an update (a new bundle)
                // tears down and rebuilds the WebView with the new files instead
                // of reusing the old scheme handler.
                .id(bundle.rootDir.lastPathComponent)
            }
        }
        .navigationTitle(currentEntry.title)
        .navigationBarTitleDisplayMode(.inline)
        // Open-time compatibility recheck: the host app version can change after
        // install, so re-evaluate the installed entry's bounds against the
        // CURRENT host and warn (non-blocking) if it's now out of range.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Non-blocking "update available" notice. The installed version
                // keeps working; tapping Update adopts + re-downloads the newer
                // bundle for the rest of this session.
                if store.appStores.availableUpdate(forInstalledAppId: app.id) != nil,
                   !updateNoticeDismissed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("A newer version is available. Update recommended.").font(.caption)
                        Spacer(minLength: 8)
                        Button("Update") { applyUpdate() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                        Button {
                            updateNoticeDismissed = true
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.12))
                }
                // Open-time compatibility recheck: the host app version can change
                // after install, so re-evaluate the entry's bounds against the
                // CURRENT host and warn (non-blocking) if it's now out of range.
                let compat = DAppCompatibility.evaluate(
                    requires: currentEntry.requiresMaknoonVersion,
                    supersededAt: currentEntry.supersededAtMaknoonVersion)
                if compat.warnsAtOpen && !compatWarningDismissed {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: compat.systemImage)
                        Text(compat.label).font(.caption)
                        Spacer(minLength: 8)
                        Button {
                            compatWarningDismissed = true
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.12))
                }
            }
        }
        .task { if case .loading = phase { await load() } }
        // Refresh catalogs in the background so the "update available" banner can
        // appear during/after loading even when the app was opened without
        // visiting the Apps tab. Only fetches the small catalog.json; the bundle
        // itself stays cache-first and is never re-fetched here.
        .task { await store.appStores.refresh() }
        // window.maknoon.walletView.open: leave the mini app and open the exact
        // Ethereum wallet + chain the tx used (mirrors CommercePaySheet "View in
        // wallet"). The wallet auto-resyncs on arrival and shows the pending tx.
        .onChange(of: openWalletCoordinator.request) { _, req in
            guard let req else { return }
            openWalletCoordinator.request = nil
            let ews = store.ethereumWalletStore
            if let addr = req.address, let id = ews.walletId(forAddress: addr) {
                ews.setActive(id)
            }
            if let cid = req.chainId,
               let net = EthereumNetwork.allCases.first(where: { $0.chainId == cid }),
               let wid = ews.activeWallet?.id {
                ews.setCurrentNetwork(net, for: wid)
            }
            store.selectedTab = .wallet
            store.walletNavigationPath.append(WalletChain.ethereum)
            dismiss()
        }
        .sheet(item: Binding(
            get: { identityCoordinator.active },
            set: { if $0 == nil { identityCoordinator.cancel() } }
        )) { req in
            MiniAppIdentitySheet(
                request: req,
                onApprove: { identityCoordinator.approve($0) },
                onCancel: { identityCoordinator.cancel() }
            )
        }
        .sheet(item: Binding(
            get: { web3Coordinator.active },
            set: { if $0 == nil { web3Coordinator.cancel() } }
        )) { req in
            MiniAppWeb3Sheet(
                request: req,
                onApprove: { web3Coordinator.approve() },
                onCancel: { web3Coordinator.cancel() },
                onSelectWallet: { store.ethereumWalletStore.setActive($0) }
            )
        }
        .sheet(item: Binding(
            get: { paymentCoordinator.active },
            set: { if $0 == nil { paymentCoordinator.cancel() } }
        )) { req in
            MiniAppPaymentSheet(
                request: req,
                store: store,
                onResolve: { hash, bolt11, at in paymentCoordinator.resolve(txHash: hash, request: req, confirmedAt: at, bolt11: bolt11) },
                onCancel: { paymentCoordinator.cancel() }
            )
        }
        .sheet(item: Binding(
            get: { collectCoordinator.active },
            set: { if $0 == nil { collectCoordinator.cancel() } }
        )) { req in
            MiniAppCollectSheet(
                request: req,
                onResolve: { collectCoordinator.resolve($0) },
                onCancel: { collectCoordinator.cancel() }
            )
        }
        .sheet(item: Binding(
            get: { commerceCoordinator.active },
            set: { if $0 == nil { commerceCoordinator.cancel() } }
        )) { req in
            MiniAppCommerceSheet(
                request: req,
                store: store,
                onResolve: { commerceCoordinator.resolve($0) },
                onCancel: { commerceCoordinator.cancel() }
            )
        }
        .sheet(item: Binding(
            get: { scanCoordinator.active },
            set: { if $0 == nil { scanCoordinator.cancel() } }
        )) { req in
            MiniAppScanSheet(
                request: req,
                onCode: { scanCoordinator.resolve($0) },
                onCancel: { scanCoordinator.cancel() }
            )
        }
    }

    private func load() async {
        phase = .loading
        let entry = currentEntry
        guard let manifestURL = entry.manifestURL,
              let manifestSha = entry.manifestSha256 else {
            phase = .failed("This app does not have a runnable bundle.")
            return
        }
        do {
            let bundle = try await MiniAppBundleStore.shared.ensureBundle(
                installedAppId: app.id,
                appId: entry.id,
                manifestURL: manifestURL,
                manifestSha256: manifestSha
            )
            phase = .ready(bundle)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Adopt the available update: swap the persisted pin, then reload this
    /// session with the newer bundle (downloaded on demand). The old bundle
    /// stays cached, so this is safe even offline mid-flight (reload just fails
    /// to a Retry, leaving the pin swapped for the next open).
    private func applyUpdate() {
        guard let newer = store.appStores.applyUpdate(installedAppId: app.id) else { return }
        effectiveEntry = newer
        updateNoticeDismissed = true
        Task { await load() }
    }
}

/// UIViewRepresentable wrapping the configured WKWebView.
private struct MiniAppWebView: UIViewRepresentable {
    let app: AppStoreRegistry.InstalledApp
    let bundle: MiniAppBundle
    let store: HolderStore
    /// The user's selected app-language identifier (e.g. "ar", "zh-Hans", "en"),
    /// resolved from DisplayPreferences. Feeds both device.info's locale and the
    /// document-start lang/dir injection so the app and host agree.
    let appLocaleIdentifier: String
    let identityCoordinator: MiniAppIdentityCoordinator
    let collectCoordinator: MiniAppCollectCoordinator
    let web3Coordinator: MiniAppWeb3Coordinator
    let paymentCoordinator: MiniAppPaymentCoordinator
    let scanCoordinator: MiniAppScanCoordinator
    let commerceCoordinator: MiniAppCommerceCoordinator
    let openWalletCoordinator: MiniAppOpenWalletCoordinator

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: MiniAppBridge(
            entry: app.entry,
            granted: app.grantedSet,
            handlers: Self.makeHandlers(
                installedAppId: app.id,
                entry: app.entry, store: store,
                appLocaleIdentifier: appLocaleIdentifier,
                identityCoordinator: identityCoordinator,
                collectCoordinator: collectCoordinator,
                web3Coordinator: web3Coordinator,
                paymentCoordinator: paymentCoordinator,
                scanCoordinator: scanCoordinator,
                commerceCoordinator: commerceCoordinator,
                openWalletCoordinator: openWalletCoordinator
            )
        ))
    }

    /// Build the namespace handlers the app is allowed to use. Handlers
    /// self-enforce their permission again via the bridge, but we also
    /// only construct the ones the app declared to keep the surface tight.
    @MainActor
    private static func makeHandlers(
        installedAppId: String,
        entry: AppStoreEntry,
        store: HolderStore,
        appLocaleIdentifier: String,
        identityCoordinator: MiniAppIdentityCoordinator,
        collectCoordinator: MiniAppCollectCoordinator,
        web3Coordinator: MiniAppWeb3Coordinator,
        paymentCoordinator: MiniAppPaymentCoordinator,
        scanCoordinator: MiniAppScanCoordinator,
        commerceCoordinator: MiniAppCommerceCoordinator,
        openWalletCoordinator: MiniAppOpenWalletCoordinator
    ) -> [MiniAppNamespaceHandler] {
        var handlers: [MiniAppNamespaceHandler] = []
        let granted = entry.grantedPermissions
        // Per-install merchant display name: the app sets it via
        // window.maknoon.storage("merchantName"); shown to customers when this
        // app requests identity or a payment. Falls back to the catalog title.
        let merchantName = store.miniAppSettings
            .value(appId: installedAppId, key: "merchantName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (merchantName?.isEmpty == false) ? merchantName! : entry.title
        // Per-app durable storage is always available (sandboxed to this
        // install id); no permission grant required.
        handlers.append(StorageBridgeHandler(installedAppId: installedAppId, store: store.miniAppSettings))
        // Per-install merchant identity + receipts (window.maknoon.merchant).
        handlers.append(MerchantBridgeHandler(store: store, installedAppId: installedAppId))
        // Public market data: no permission required.
        handlers.append(FiatBridgeHandler(store: store))
        // Address-book read (own wallets + contacts) is gated by "payment".
        handlers.append(AddressBookBridgeHandler(store: store))
        // Low-friction native capabilities. The bridge enforces each one's
        // capability against the granted set, so registering is harmless.
        handlers.append(DeviceBridgeHandler(store: store, localeIdentifier: appLocaleIdentifier)) // auto
        handlers.append(HapticBridgeHandler())                   // auto
        handlers.append(ClipboardBridgeHandler())                // "clipboard"
        handlers.append(ShareBridgeHandler())                    // "share"
        handlers.append(WalletBridgeHandler(store: store))       // "wallet"
        handlers.append(ScanBridgeHandler(appTitle: displayName, coordinator: scanCoordinator)) // "scan"
        // ADR-0057: EVM access is granted under the hierarchical wallet.ethereum.* tokens
        // (read/write/sign); accept the legacy "evm" token too for older bundles.
        let hasEvm = granted.contains("evm") || granted.contains { $0.hasPrefix("wallet.ethereum.") }
        if hasEvm {
            handlers.append(Web3BridgeHandler(store: store, coordinator: web3Coordinator, appTitle: displayName))
            // window.maknoon.pools.list: read the issuer's public pool registry
            // (the sandbox has connect-src 'none', so this network read must be
            // native). No user data; gated by EVM access via this registration.
            handlers.append(PoolRegistryBridgeHandler())
            // window.maknoon.walletView.open: leave the mini app and open the
            // Ethereum wallet + chain a tx used (e.g. after a swap). Navigation
            // only; gated by EVM access via this registration.
            handlers.append(OpenWalletBridgeHandler(coordinator: openWalletCoordinator))
        }
        if granted.contains("payment") {
            handlers.append(PaymentBridgeHandler(store: store, appTitle: displayName, coordinator: paymentCoordinator))
            // Unified verify-and-pay (ADR-0031); reuses the "payment" grant.
            handlers.append(CommerceBridgeHandler(store: store, appTitle: displayName, installedAppId: installedAppId, coordinator: commerceCoordinator))
        }
        if granted.contains("identity") {
            handlers.append(IdentityBridgeHandler(
                store: store, appTitle: displayName, installedAppId: installedAppId,
                coordinator: identityCoordinator,
                collectCoordinator: collectCoordinator))
        }
        // Native credential-gated pool access (window.maknoon.poolAccess). Discloses
        // a passport credential (identity) and proves control of the EVM wallet (evm),
        // so it needs both grants; reuses the identity consent coordinator.
        if granted.contains("identity") && hasEvm {
            handlers.append(PoolAccessBridgeHandler(
                store: store, appTitle: displayName, coordinator: identityCoordinator))
        }
        return handlers
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MiniAppSchemeHandler(bundle: bundle), forURLScheme: MiniAppSchemeHandler.scheme)

        let ucc = WKUserContentController()
        // Set <html lang/dir> before anything renders, so RTL (Arabic) is correct
        // with no left-to-right flash and every app inherits the right direction
        // even if it ignores device.info().locale. Runs first (document-start).
        ucc.addUserScript(WKUserScript(source: Self.localeScript(localeId: appLocaleIdentifier), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let providerJS = Self.providerScript() {
            ucc.addUserScript(WKUserScript(source: providerJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // Lock the viewport so the page can't pinch/double-tap zoom regardless
        // of the app's own <meta viewport>. Belt-and-suspenders with the
        // scrollView gesture disable + didFinish re-clamp below.
        ucc.addUserScript(WKUserScript(source: Self.viewportLockJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addScriptMessageHandler(context.coordinator.bridge, contentWorld: .page, name: MiniAppBridge.handlerName)
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = true   // Safari Web Inspector for debugging
        // Block pinch-zoom by default: it's a confusing affordance in a
        // fixed mini-app layout. Disable the scroll view's zoom gestures.
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.minimumZoomScale = 1
        context.coordinator.webView = webView

        let entry = MiniAppSchemeHandler.entryURL(appId: app.entry.id, entryPath: bundle.entryPath)
        webView.load(URLRequest(url: entry))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        uiView.stopLoading()
    }

    /// Forces a non-zoomable viewport and swallows pinch gesture starts,
    /// independent of whatever <meta viewport> the mini app ships.
    private static let viewportLockJS = """
    (function () {
      function lock() {
        var m = document.querySelector('meta[name=viewport]') || document.createElement('meta');
        m.setAttribute('name', 'viewport');
        m.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');
        if (!m.parentNode) { (document.head || document.documentElement).appendChild(m); }
      }
      lock();
      document.addEventListener('DOMContentLoaded', lock);
      document.addEventListener('gesturestart', function (e) { e.preventDefault(); }, { passive: false });
    })();
    """

    /// A document-start script that sets <html lang> + dir from the host's
    /// selected app language. Mirrors the app's own normalization (any zh-* maps
    /// to Simplified, ar -> rtl) so the host injection and the bundle agree.
    private static func localeScript(localeId: String) -> String {
        let id = localeId.lowercased()
        let lang: String
        let dir: String
        if id.hasPrefix("ar") { lang = "ar"; dir = "rtl" }
        else if id.hasPrefix("zh") { lang = "zh-Hans"; dir = "ltr" }
        else { lang = "en"; dir = "ltr" }
        return """
        (function () {
          var e = document.documentElement;
          e.lang = '\(lang)';
          e.setAttribute('dir', '\(dir)');
        })();
        """
    }

    /// Load the injected provider shim from the app bundle.
    private static func providerScript() -> String? {
        guard let url = Bundle.main.url(forResource: "MiniAppProvider", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            LogStore.shared.error("MiniApp", "MiniAppProvider.js missing from app bundle")
            return nil
        }
        return js
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let bridge: MiniAppBridge
        weak var webView: WKWebView?

        init(bridge: MiniAppBridge) { self.bridge = bridge }

        // Keep navigation inside the app's own scheme. A user-TAPPED http(s)
        // link (e.g. a receipt's block-explorer link) opens in the system
        // browser instead, never inside the sandbox; everything else is refused.
        // Mini apps still reach app data only through the bridge.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            if scheme == MiniAppSchemeHandler.scheme {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let url, scheme == "https" || scheme == "http" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        // Re-clamp zoom after the page loads (WKWebView resets scrollView zoom
        // limits from the page's viewport on load).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = 1
            webView.scrollView.zoomScale = 1
        }
    }
}
