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
    @State private var identityCoordinator = MiniAppIdentityCoordinator()
    @State private var collectCoordinator = MiniAppCollectCoordinator()
    @State private var web3Coordinator = MiniAppWeb3Coordinator()
    @State private var paymentCoordinator = MiniAppPaymentCoordinator()
    @State private var scanCoordinator = MiniAppScanCoordinator()
    @State private var commerceCoordinator = MiniAppCommerceCoordinator()

    private enum Phase {
        case loading
        case ready(MiniAppBundle)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(app.entry.title)…").font(.callout).foregroundStyle(.secondary)
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
                    commerceCoordinator: commerceCoordinator
                )
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(app.entry.title)
        .navigationBarTitleDisplayMode(.inline)
        // Open-time compatibility recheck: the host app version can change after
        // install, so re-evaluate the installed entry's bounds against the
        // CURRENT host and warn (non-blocking) if it's now out of range.
        .safeAreaInset(edge: .top, spacing: 0) {
            let compat = DAppCompatibility.evaluate(
                requires: app.entry.requiresMaknoonVersion,
                supersededAt: app.entry.supersededAtMaknoonVersion)
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
        .task { if case .loading = phase { await load() } }
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
                onCancel: { web3Coordinator.cancel() }
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
        guard let manifestURL = app.entry.manifestURL,
              let manifestSha = app.entry.manifestSha256 else {
            phase = .failed("This app does not have a runnable bundle.")
            return
        }
        do {
            let bundle = try await MiniAppBundleStore.shared.ensureBundle(
                installedAppId: app.id,
                appId: app.entry.id,
                manifestURL: manifestURL,
                manifestSha256: manifestSha
            )
            phase = .ready(bundle)
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
                commerceCoordinator: commerceCoordinator
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
        commerceCoordinator: MiniAppCommerceCoordinator
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
        if granted.contains("evm") {
            handlers.append(Web3BridgeHandler(store: store, coordinator: web3Coordinator, appTitle: displayName))
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
