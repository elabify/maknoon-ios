// Settings → About. App identity, links to Elabify + GitHub,
// thanks to every third-party service the app talks to by default,
// list of open-source components with versions and licenses, and
// the diagnostic-logs share affordance.
//
// Logs share has an explicit warning sheet before invoking the iOS
// share sheet so users know what's in (public addresses, tx hashes,
// RPC URLs) and what's not (recovery phrase, private keys).

import SwiftUI
import UIKit

struct AboutView: View {
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showLogsWarning = false
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            appSection
            elabifySection
            standardsSection
            servicesSection
            componentsSection
            diagnosticsSection
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Share diagnostic logs?",
            isPresented: $showLogsWarning,
            titleVisibility: .visible
        ) {
            Button("I understand, share logs") {
                shareItems = [exportLogToTempFile()]
                showShareSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                 Logs DO NOT contain your recovery phrase, password, private keys, or wrap keys: those never leave Keychain.

                 Logs DO contain public-but-identifying information: wallet addresses, transaction hashes, the chains and services you've used, BLE device identifiers, and timestamps. Anyone who reads the logs can correlate your activity on-chain. Only share with people you trust.
                 """)
        }
        .confirmationDialog(
            "Clear diagnostic logs?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all entries", role: .destructive) {
                LogStore.shared.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    // MARK: -- sections

    private var appSection: some View {
        Section {
            row("Name", "Maknoon")
            row("Version", marketingVersion)
            row("Build", bundleVersion)
            row("Commit", buildCommit)
        } header: {
            Text("App")
        }
    }

    private var elabifySection: some View {
        Section {
            Link(destination: URL(string: "https://elabify.com")!) {
                Label("elabify.com", systemImage: "globe")
            }
            Link(destination: URL(string: "https://github.com/elabify/maknoon-ios")!) {
                Label("Source code & issue tracker", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/elabify/maknoon-ios/blob/main/ios-app-maknoon/LICENSE.md")!) {
                Label("License (Apache 2.0 / MIT)", systemImage: "scroll")
            }
            Link(destination: URL(string: "https://elabify.com/support/compliance/privacy-policy/")!) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
        } header: {
            Text("Elabify")
        }
    }

    private var standardsSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/trustoverip/high-assurance-verifiable-identifiers")!) {
                Label("ToIP HAVID", systemImage: "checkmark.seal.fill")
            }
        } header: {
            Text("Standards")
        } footer: {
            Text("Maknoon verifiers can cross-check an issuer's DID against its X.509 organisational certificate (HAVID), and a passport's CSCA against an on-chain registry, so trust does not rest on the issuer's word alone.")
        }
    }

    private var servicesSection: some View {
        Section {
            credit("mempool.space", "Bitcoin fee estimates, block explorer, and the Electrum endpoint Maknoon uses by default", "https://mempool.space")
            credit("Blockstream", "Public Electrum servers and esplora APIs that Bitcoin wallets fall back on", "https://blockstream.info")
            credit("CoinGecko", "Fiat price feeds for Bitcoin display", "https://www.coingecko.com")
            credit("PublicNode", "Default JSON-RPC for Ethereum mainnet + Sepolia, Polygon, and BNB Chain", "https://www.publicnode.com")
            credit("Arbitrum Foundation", "Arbitrum One + Sepolia RPC", "https://arbitrum.foundation")
            credit("Optimism", "OP Mainnet + Sepolia RPC", "https://www.optimism.io")
            credit("Base", "Base Mainnet + Sepolia RPC", "https://base.org")
            credit("Polygon Labs", "Polygon PoS + zkEVM RPC", "https://polygon.technology")
            credit("BNB Chain", "BSC RPC", "https://www.bnbchain.org")
            credit("Ava Labs", "Avalanche C-Chain RPC", "https://www.avax.network")
            credit("Scroll", "Scroll mainnet RPC", "https://scroll.io")
            credit("Linea", "Linea mainnet RPC", "https://linea.build")
            credit("Matter Labs", "zkSync Era RPC", "https://zksync.io")
            credit("Mantle", "Mantle mainnet RPC", "https://mantle.xyz")
            credit("Hyperliquid", "Hyperliquid EVM RPC", "https://hyperliquid.xyz")
            credit("Blockscout", "Open-source block-explorer API used by default on every EVM chain that has a Blockscout deployment", "https://www.blockscout.com")
            credit("Snowtrace", "Avalanche block explorer API", "https://snowtrace.io")
            credit("Circle", "USDC contract addresses across chains and the Sepolia faucet for test USDC", "https://www.circle.com")
            credit("Chainlink", "LINK contract addresses and the Sepolia LINK faucet", "https://chain.link")
            credit("Trust Wallet token lists", "Reputable-token verification cross-reference for auto-discover", "https://github.com/trustwallet/assets")
        } header: {
            Text("Default services")
        } footer: {
            Text("Maknoon talks to these services out of the box. You can override any of them with your own endpoint in Settings → Networks.")
                .font(.caption)
        }
    }

    private var componentsSection: some View {
        Section {
            component("Trust Wallet Core", version: "4.6.9", license: "Apache 2.0",
                      url: "https://github.com/trustwallet/wallet-core")
            component("BitcoinDevKit", version: "2.3.1", license: "MIT / Apache 2.0",
                      url: "https://github.com/bitcoindevkit/bdk-swift")
            component("SwiftProtobuf", version: "Bundled with TWC", license: "Apache 2.0",
                      url: "https://github.com/apple/swift-protobuf")
            component("ElabifyCore", version: "In-tree", license: "Apache 2.0 / MIT",
                      url: "https://github.com/elabify/elabify-core")
            component("Ledger device SDKs (BTC/ETH/SOL/TRON)", version: "In-tree", license: "Apache 2.0",
                      url: "https://github.com/elabify/maknoon-ios")
            component("WalletConnect (Reown)", version: "2.3.0", license: "Apache 2.0",
                      url: "https://github.com/reown-com/reown-swift")
            component("YubiKit", version: "4.7.0", license: "Apache 2.0",
                      url: "https://github.com/Yubico/yubikit-ios")
            component("NFCPassportReader", version: "2.3.0", license: "MIT",
                      url: "https://github.com/AndyQ/NFCPassportReader")
            component("URKit", version: "14.0.2", license: "BSD-2-Clause-Patent",
                      url: "https://github.com/BlockchainCommons/URKit")
            component("BC DCBOR", version: "1.0.7", license: "BSD-2-Clause-Patent",
                      url: "https://github.com/BlockchainCommons/BCSwiftDCBOR")
            component("BC Tags", version: "0.2.3", license: "BSD-2-Clause-Patent",
                      url: "https://github.com/BlockchainCommons/BCSwiftTags")
            component("BC Float16", version: "1.0.0", license: "BSD-2-Clause-Patent",
                      url: "https://github.com/BlockchainCommons/BCSwiftFloat16")
            component("NumberKit", version: "2.4.3", license: "Apache 2.0",
                      url: "https://github.com/wolfmcnally/swift-numberkit")
            component("Swift Collections", version: "1.1.4", license: "Apache 2.0",
                      url: "https://github.com/wolfmcnally/swift-collections")
            component("OpenSSL", version: "3.3.3001", license: "Apache 2.0",
                      url: "https://github.com/krzyzanowskim/OpenSSL-Package")
        } header: {
            Text("Open-source components")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            HStack {
                Text("Log entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(LogStore.shared.count)")
                    .font(.caption.monospaced())
            }
            Button {
                showLogsWarning = true
            } label: {
                Label("Share diagnostic logs", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear logs", systemImage: "trash")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Logs capture recent errors, BLE events, RPC failures, and identity-wrap activity to make support easier. They live only in this app's memory until you share or clear them.")
                .font(.caption)
        }
    }

    // MARK: -- helpers

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func credit(_ name: String, _ description: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.semibold))
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func component(_ name: String, version: String, license: String, url: String) -> some View {
        if let u = URL(string: url) {
            Link(destination: u) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.callout.weight(.semibold))
                        Text(license).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(version).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    private var bundleVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }
    private var buildCommit: String {
        (Bundle.main.object(forInfoDictionaryKey: "ELABIFY_BUILD_COMMIT") as? String) ?? "dev"
    }

    /// Write the formatted log buffer to a uniquely-named temp file
    /// and return the URL. The share sheet then offers a real file
    /// with `lastPathComponent` instead of `Untitled.txt`. Filename
    /// shape:
    ///   `maknoon-diagnosticLog-<commit>-<build>-<yyyyMMdd-HHmmss>.txt`
    /// On write failure we fall back to sharing the raw text so
    /// users on a wedged filesystem still get the logs out.
    private func exportLogToTempFile() -> Any {
        let body = LogStore.shared.formatted()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let name = "maknoon-diagnosticLog-\(buildCommit)-\(bundleVersion)-\(stamp).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try Data(body.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return body
        }
    }
}

/// Thin SwiftUI wrapper for UIActivityViewController. Used by the
/// About → Share diagnostic logs flow. Sharing text gets the
/// standard AirDrop / Mail / Messages / Save-to-Files options.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
