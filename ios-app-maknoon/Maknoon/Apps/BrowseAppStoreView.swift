// Apps catalog browser. Lists the configured catalogs (always
// Elabify + any user-added), drills into a catalog to see its apps,
// lets the user install one into the Apps tab.
//
// Reached from the Apps tab "+" toolbar button.

import SwiftUI

struct BrowseAppStoreView: View {
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Called when the user taps Open on a (now-)installed mini app, so the
    /// Apps tab can dismiss the browser and jump straight into it.
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.appStores.allCatalogs) { catalog in
                        NavigationLink {
                            CatalogDetailView(catalog: catalog, onOpen: onOpen)
                                .environment(store)
                        } label: {
                            row(catalog: catalog)
                        }
                    }
                } header: {
                    Text("Apps catalogs")
                } footer: {
                    Text("Add additional Apps catalogs in Settings > Apps.")
                        .font(.caption)
                }
            }
            .navigationTitle("Browse Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.appStores.refresh() }
            .refreshable { await store.appStores.refresh() }
        }
    }

    private func row(catalog: AppStoreCatalog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name).font(.callout.weight(.semibold))
                let n = visibleAppCount(catalog)
                Text("\(n) app\(n == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Count apps as the browser will show them: grouped by app id and filtered
    /// by the live "show beta apps" flag (beta OFF counts apps with a stable
    /// version; beta ON counts apps with any version), so POS's stable+beta
    /// entries count as one app. Mirrors CatalogDetailView.visibleApps.
    private func visibleAppCount(_ catalog: AppStoreCatalog) -> Int {
        let showBeta = store.appStores.showBetaApps
        var seen = Set<String>()
        var n = 0
        for entry in catalog.apps where !seen.contains(entry.id) {
            seen.insert(entry.id)
            let variants = catalog.apps.filter { $0.id == entry.id }
            if CatalogDetailView.representative(of: variants, showBeta: showBeta) != nil { n += 1 }
        }
        return n
    }
}

private struct CatalogDetailView: View {
    let catalog: AppStoreCatalog
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil
    @Environment(HolderStore.self) private var store
    @State private var selectedEntry: AppStoreEntry?

    /// One row per app id (ADR-0052): a v2 catalog (or a flat catalog that
    /// repeats an id per channel) is grouped so the same app never shows as two
    /// tiles. The representative is the default channel (stable, else beta when
    /// beta apps are shown), preferring a host-compatible + highest version.
    /// Beta-only apps are hidden unless the user opted in.
    private var visibleApps: [AppStoreEntry] {
        let showBeta = store.appStores.showBetaApps
        var seen = Set<String>()
        var out: [AppStoreEntry] = []
        for entry in catalog.apps where !seen.contains(entry.id) {
            seen.insert(entry.id)
            if let rep = Self.representative(of: variants(for: entry.id), showBeta: showBeta) {
                out.append(rep)
            }
        }
        return out
    }

    private func variants(for appId: String) -> [AppStoreEntry] {
        catalog.apps.filter { $0.id == appId }
    }

    /// Pick the tile's representative variant: stable by default, beta only when
    /// shown; within a channel prefer a host-compatible variant, then highest
    /// version. Returns nil when the only variants are beta and beta is hidden.
    static func representative(of variants: [AppStoreEntry], showBeta: Bool) -> AppStoreEntry? {
        let stable = variants.filter { !AppStoreRegistry.isBeta($0) }
        let beta = variants.filter { AppStoreRegistry.isBeta($0) }
        // The tile defaults to stable; a beta-only app appears only when "show
        // beta apps" is on. Choosing beta for an app that also has a stable is
        // done in the install sheet's channel picker, not here.
        let pool = !stable.isEmpty ? stable : (showBeta ? beta : [])
        guard !pool.isEmpty else { return nil }
        let compatible = pool.filter {
            !DAppCompatibility.evaluate(requires: $0.requiresMaknoonVersion,
                                        supersededAt: $0.supersededAtMaknoonVersion).blocksInstall
        }
        let candidates = compatible.isEmpty ? pool : compatible
        return candidates.max { versionLess($0.version, $1.version) }
    }

    /// Compare optional semantic-ish versions numerically (missing = lowest).
    private static func versionLess(_ a: String?, _ b: String?) -> Bool {
        func parts(_ s: String?) -> [Int] { (s ?? "").split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi < yi }
        }
        return false
    }

    var body: some View {
        Form {
            Section {
                ForEach(visibleApps) { entry in
                    Button {
                        selectedEntry = entry
                    } label: {
                        entryRow(entry)
                    }
                    .buttonStyle(.plain)
                }
                if visibleApps.isEmpty {
                    if catalog.apps.isEmpty {
                        Text("This catalog has no apps yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Beta apps are hidden. Turn on “Show beta apps” in Apps settings to see experimental apps.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(catalog.name)
            } footer: {
                if !catalog.summary.isEmpty {
                    Text(catalog.summary).font(.caption)
                }
            }
        }
        .navigationTitle(catalog.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            InstallSheet(catalog: catalog, entry: entry, onOpen: onOpen)
                .environment(store)
        }
    }

    private func entryRow(_ entry: AppStoreEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.iconName)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.callout.weight(.semibold))
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                if let v = entry.version {
                    Text("v\(v)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if store.appStores.isInstalled(storeId: catalog.id, appId: entry.id) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
            Text(entry.channelLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(entry.statusColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

private struct InstallSheet: View {
    let catalog: AppStoreCatalog
    let entry: AppStoreEntry
    var onOpen: ((AppStoreRegistry.InstalledApp) -> Void)? = nil
    @Environment(HolderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Picked channel (default stable). Drives which variant is described + installed.
    @State private var channel: String = "stable"

    private var variants: [AppStoreEntry] { catalog.apps.filter { $0.id == entry.id } }
    private var stableVariant: AppStoreEntry? { variants.first { !AppStoreRegistry.isBeta($0) } }
    private var betaVariant: AppStoreEntry? { variants.first { AppStoreRegistry.isBeta($0) } }
    /// Offer a Stable|Beta picker only when both channels exist AND beta apps are
    /// enabled (beta stays hidden until the user opts in globally).
    private var showChannelPicker: Bool {
        store.appStores.showBetaApps && stableVariant != nil && betaVariant != nil
    }
    /// The variant to describe + install, per the picked channel.
    private var chosen: AppStoreEntry {
        if channel == "beta", let b = betaVariant { return b }
        return stableVariant ?? entry
    }

    private var isInstalled: Bool {
        store.appStores.isInstalled(storeId: catalog.id, appId: entry.id)
    }
    private var installedApp: AppStoreRegistry.InstalledApp? {
        store.appStores.installedApps.first { $0.storeId == catalog.id && $0.appId == entry.id }
    }
    /// True when the CHOSEN channel's version is the one already installed.
    private var chosenInstalled: Bool { installedApp?.entry.version == chosen.version }

    /// Disclose the install/per-use capabilities the app requests, with
    /// reasons. Installing grants this set; auto capabilities aren't shown.
    @ViewBuilder
    private var capabilitiesSection: some View {
        let caps = MiniAppCapabilityRegistry.disclosable(chosen.declaredCapabilityTokens)
        if !caps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("This app can").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(caps) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.icon).foregroundStyle(.purple).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.label).font(.callout.weight(.medium))
                            // Show the registry's canonical description so every
                            // app requesting a capability reads the same, rather
                            // than the catalog's per-app reason override.
                            Text(c.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        if c.tier == .perUse {
                            Spacer(minLength: 0)
                            Text("asks each time").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: chosen.iconName)
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chosen.title).font(.title3.weight(.semibold))
                            Text("\(chosen.channelLabel)\(chosen.version.map { " · v\($0)" } ?? "")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(chosen.statusColor)
                        }
                    }
                    if showChannelPicker {
                        Picker("Channel", selection: $channel) {
                            Text("Stable").tag("stable")
                            Text("Beta").tag("beta")
                        }
                        .pickerStyle(.segmented)
                    }
                    DAppCompatibilityRow(requires: chosen.requiresMaknoonVersion,
                                         supersededAt: chosen.supersededAtMaknoonVersion)
                    Divider()
                    Text(chosen.summary).font(.callout.weight(.medium))
                    Text(chosen.details).font(.callout).foregroundStyle(.secondary)
                    capabilitiesSection
                    Spacer(minLength: 0)
                    if chosenInstalled {
                        if chosen.isMiniApp {
                            Button {
                                let app = store.appStores.installedApps.first { $0.id == "\(catalog.id)::\(entry.id)" }
                                dismiss()
                                if let app { onOpen?(app) }
                            } label: {
                                Label("Open", systemImage: "arrow.up.right.square")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button(role: .destructive) {
                            store.appStores.uninstall(installedAppId: "\(catalog.id)::\(entry.id)")
                            dismiss()
                        } label: {
                            Label("Uninstall", systemImage: "minus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        let compatibility = DAppCompatibility.evaluate(
                            requires: chosen.requiresMaknoonVersion,
                            supersededAt: chosen.supersededAtMaknoonVersion)
                        let blocked = compatibility.blocksInstall
                        Button {
                            // Upsert: installs the chosen channel, switching if a
                            // different channel of this app was already installed.
                            store.appStores.install(chosen, fromStore: catalog.id)
                            if chosen.isMiniApp {
                                let app = store.appStores.installedApps.first { $0.id == "\(catalog.id)::\(entry.id)" }
                                dismiss()
                                if let app { onOpen?(app) }
                            } else {
                                dismiss()
                            }
                        } label: {
                            Label(isInstalled ? "Switch to \(chosen.channelLabel)" : "Install to Apps tab",
                                  systemImage: isInstalled ? "arrow.triangle.2.circlepath" : "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(blocked)
                        if case .recommendsNewer(let required, _) = compatibility {
                            Text("Requires Maknoon \(required)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                        }
                        if case .superseded(let supersededAt, _) = compatibility {
                            Text("This app needs an update for Maknoon (superseded at \(supersededAt))")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
