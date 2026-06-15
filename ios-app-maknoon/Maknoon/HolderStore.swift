// Observable holder state: tab selection, picked-up credentials, the
// loaded Identity Sandwich, and the most recent verifier verdict.
//
// The holder identity (master + Secure-Enclave ephemeral + delegation
// cert) lives inside an `IdentitySandwich` instance that we load from
// Keychain on first use. When the user has not onboarded yet,
// `sandwich` is nil and the launch router shows `OnboardingView`.

import Foundation
import Observation
import SwiftUI

@Observable
final class HolderStore {
    enum Tab: Hashable {
        case identity, wallet, apps
    }

    /// User-configurable allow-list of trusted issuer hosts. The
    /// Receive credential flow consults this at fetch time; pickup
    /// URLs from unknown hosts trigger an explicit one-time-trust
    /// prompt. Defaults to Elabify's three production issuers; user
    /// edits this list under Settings → Identity → Known issuers.
    let knownIssuers = KnownIssuersStore()
    /// Elabify-hosted drop pastebin host. The holder uploads
    /// Presentations here in the offline `qrBack` share flow and shows the
    /// returned envelope as a small QR for an in-person verifier to scan.
    /// Note: this is INFRASTRUCTURE, not a default verifier — Presentations
    /// can be sent to any party via copy / paste-callback. The drop host is
    /// merely a temporary pastebin that any verifier can fetch from.
    static let elabifyDropHost = URL(string: "https://musnad-verifier.elabify.com")!

    /// Currently visible tab.
    var selectedTab: Tab = .identity

    /// Navigation path for the Identity tab's NavigationStack. Exposed
    /// so the Remove flow on a pushed credential view can pop
    /// explicitly via `path.removeLast()` rather than relying on
    /// `@Environment(\.dismiss)`. The latter has shown itself to be
    /// flaky on iOS 26 when called from a Form-button action that
    /// also mutates observed state on the same tick.
    var identityNavigationPath = NavigationPath()

    /// All credentials picked up so far.
    var credentials: [Credential] = []

    /// Per-credential nicknames keyed by `credential.id`. Lets the user
    /// rename a card (e.g. "Sarah's work passport" instead of just
    /// "Passport") without changing any signed wire data. Persisted via
    /// UserDefaults so the names survive app restarts.
    var credentialNicknames: [String: String] = [:]

    /// Status banner messages, last error, last verifier verdict (for
    /// the Present tab).
    var status: String = "Ready"
    var lastError: String?
    var lastVerdict: VerifyResponse?
    var lastVerifyAt: Date?

    /// Loaded identity, or nil if the user has not onboarded yet OR
    /// the sandwich is hardware-wrapped and waiting for an unlock.
    /// Populated by `loadIdentity()` on launch, and by the
    /// onboarding / recovery flows when a fresh sandwich is provisioned.
    private(set) var sandwich: IdentitySandwich?

    /// True while OnboardingView is running its post-identity steps (passport
    /// scan, first wallet) after the sandwich has been adopted. Keeps the
    /// launch router on OnboardingView so those steps can sign / mint / create
    /// a wallet with a live `sandwich`. Cleared when onboarding finishes.
    var isCompletingOnboarding = false

    /// Non-empty when `loadIdentity()` discovers a hardware-wrapped
    /// sandwich. Each entry is one enrolled device's wrap; the
    /// unlock UI lists them and lets the user pick whichever device
    /// is at hand. Cleared via `adopt(_:)` once any device unlocks.
    private(set) var pendingHardwareUnlock: [WrappedMaterialPersisted] = []

    /// Driven by any view that needs to trigger the hardware-unlock
    /// sheet. The sheet is hosted on ContentView. Setting this to
    /// true presents the sheet; the unlock flow itself clears it
    /// (or the user dismisses).
    var showHardwareUnlock: Bool = false

    /// True when a sandwich exists on disk but isn't loaded into
    /// memory because the user hasn't unlocked it with their
    /// hardware device this session. Used by identity-dependent
    /// UI to render "locked, tap to unlock" affordances.
    var isIdentityLocked: Bool {
        sandwich == nil && !pendingHardwareUnlock.isEmpty
    }

    /// User's Bitcoin wallets list + the per-network backend config.
    /// Live for the full app session; seed first-run default on the
    /// Wallet tab's onAppear.
    let bitcoinWalletStore = BitcoinWalletStore()
    let bitcoinSettings = BitcoinSettings()
    let bitcoinLabels = BitcoinLabelStore()
    let bitcoinPrices = BitcoinPriceCache()

    /// Global fiat-reference settings: which currency to display,
    /// and whether fiat references are shown at all.
    let fiatPreferences = FiatPreferences()
    /// Multi-asset price cache shared by every wallet view +
    /// send screen. Honors `fiatPreferences.showReferencePrices`
    /// internally; callers don't need to gate themselves.
    let assetPrices = AssetPriceCache()

    /// Ethereum (and EVM-compatible chains: Optimism, Base, Arbitrum,
    /// Polygon, BNB, Avalanche, Scroll, Linea, zkSync, Mantle,
    /// Polygon zkEVM, Hyperliquid EVM, plus testnets). Mirrors the
    /// Bitcoin store/settings shape so future chains (Tron, Solana)
    /// can pattern-match.
    let ethereumWalletStore = EthereumWalletStore()
    let ethereumSettings = EthereumSettings()
    /// User-defined EVM networks. Picked from the wallet's network
    /// dropdown alongside built-in cases (mainnet, Sepolia, …).
    let ethereumCustomNetworks = CustomNetworkStore()

    /// Solana wallets (mainnet-beta, devnet, testnet) and the per-
    /// network settings (RPC + explorer overrides). Software-wallet
    /// signing ships in Phase B; hardware (Ledger / Trezor) in
    /// Phase C.
    let solanaWalletStore = SolanaWalletStore()
    let solanaSettings = SolanaSettings()
    /// Remote-backed verified-token catalog (Jupiter strict list by
    /// default; URL overridable in Solana Settings). Drives the
    /// auto-discover trust gate in `solanaSPLTokenStore`.
    let solanaTokenCatalog = SolanaTokenCatalog()
    /// User's installed SPL tokens per cluster, plus the auto-
    /// discover unknown-mint banner state. No first-run seed.
    let solanaSPLTokenStore = SolanaSPLTokenStore()
    /// Remote-backed verified ERC-20 catalog (Uniswap multi-chain
    /// default token list by default; URL overridable in Ethereum
    /// Settings). Augments the in-tree `EthereumTokenCatalog` so
    /// auto-discover treats freshly-listed verified tokens the same
    /// way the curated list does.
    let ethereumTokenRegistry = EthereumTokenRegistry()
    /// Tron wallets (mainnet, Shasta, Nile). Ledger or software only;
    /// Trezor firmware does not support Tron.
    let tronWalletStore = TronWalletStore()
    let tronSettings = TronSettings()
    /// Remote-backed verified-token catalog (TronScan strict list by
    /// default; URL overridable in Tron Settings). Drives the auto-
    /// discover trust gate in `tronTRC20TokenStore`.
    let tronTokenCatalog = TronTokenCatalog()
    /// User's installed TRC-20 tokens per network, plus the auto-
    /// discover unknown-contract banner state. No first-run seed.
    let tronTRC20TokenStore = TronTRC20TokenStore()
    /// Lightning custodial wallets (LNDHub-backed). One account
    /// per LNDHub credential set; multiple supported.
    let lightningAccountStore = LightningAccountStore()
    /// Saved ID documents read over NFC (passports, ID cards,
    /// residence permits). Tapped via the Identity tab's "+" menu.
    /// Each document is metadata + an optional photo file. Phone-
    /// local only; cleared by Reset Wallet.
    let idDocuments = IDDocumentStore()

    /// User's address book. Per-network contact list used by the
    /// Send views (paste-replacement) and included in the YAML +
    /// iCloud settings backup.
    let addressBook = AddressBookStore()
    /// User's installed ERC-20 tokens per EVM network. Seeded with
    /// a curated catalog (USDC / USDT / DAI on the chains where they
    /// exist); user-added tokens land here too.
    let ethereumTokenStore = EthereumTokenStore()

    /// Appstore registry: configured catalogs + installed apps.
    let appStores = AppStoreRegistry()

    /// Per-mini-app durable settings (window.maknoon.storage). Backed up
    /// via the `miniapp.settings.v1` walletState key.
    let miniAppSettings = MiniAppSettingsStore()

    /// Per-install merchant verifier identity used by the POS to sign
    /// VerifierRequests / CommerceRequests (see MerchantIdentityStore). The
    /// merchant dApp keeps its own settings + receipts via window.maknoon.storage;
    /// only the verifier key is native (window.maknoon.merchant).
    let merchantIdentity = MerchantIdentityStore()

    /// Vendor-neutral registry of hardware devices the user has
    /// registered (YubiKey, Ledger, Trezor). Each device can be
    /// promoted independently into the Identity Sandwich and into
    /// per-network wallets from the Devices screen and the network
    /// settings pages.
    let devices = DeviceRegistry()

    /// Background-polling store for credentials that have been minted
    /// by the issuer but not yet anchored and imported into the
    /// wallet. Lives on the holder store so its lifecycle matches
    /// the rest of the user's state (persisted via UserDefaults,
    /// resumed on launch).
    let pendingPickups = PendingPickupsStore()

    /// Flat user-created folders for the Identity tab's credential
    /// stack, plus the cardId -> folderId membership map. Folders
    /// are persisted under their own UserDefaults keys; the wipe
    /// + encrypted-backup paths carry them alongside the credentials.
    let credentialFolderStore = CredentialFolderStore()

    /// UserDefaults keys used for JSON persistence.
    private static let nicknamesKey = "credentialNicknames"
    private static let credentialsKey = "credentials.v1"

    init() {
        // Identity load happens explicitly from the launch path so we
        // can route to OnboardingView before any other work runs.
        if let data = UserDefaults.standard.data(forKey: Self.nicknamesKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.credentialNicknames = dict
        }
        if let data = UserDefaults.standard.data(forKey: Self.credentialsKey),
           let creds = try? JSONDecoder().decode([Credential].self, from: data) {
            self.credentials = creds
        }
        // Hand the AssetPriceCache a weak ref to the fiat
        // preferences so it can short-circuit network calls when
        // the user has disabled fiat references.
        assetPrices.wire(preferences: fiatPreferences)
        // Wire the pending-pickups poller to deposit credentials into
        // our list on success. Starts its background Task immediately
        // if any entries were persisted from a previous launch.
        pendingPickups.wire { [weak self] credential in
            self?.addCredential(credential)
        }
        // Wire each chain's wallet store to mirror entries into the
        // shared address book. Setting the weak ref + an initial
        // re-mirror catches wallets created before this wiring existed
        // (e.g. after a settings restore that didn't include the
        // address book section).
        bitcoinWalletStore.addressBook = addressBook
        bitcoinWalletStore.remirrorAllToAddressBook()
        ethereumWalletStore.addressBook = addressBook
        ethereumWalletStore.remirrorAllToAddressBook()
        solanaWalletStore.addressBook = addressBook
        solanaWalletStore.remirrorAllToAddressBook()
        tronWalletStore.addressBook = addressBook
        tronWalletStore.remirrorAllToAddressBook()
    }

    // MARK: -- nicknames

    func nickname(for credentialId: String) -> String? {
        credentialNicknames[credentialId]
    }

    func setNickname(_ name: String?, for credentialId: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            credentialNicknames[credentialId] = trimmed
        } else {
            credentialNicknames.removeValue(forKey: credentialId)
        }
        if let data = try? JSONEncoder().encode(credentialNicknames) {
            UserDefaults.standard.set(data, forKey: Self.nicknamesKey)
        }
    }

    // MARK: -- identity lifecycle

    /// Try to reattach to a previously-persisted Identity Sandwich.
    /// Three outcomes:
    ///   * `.loaded`    — `sandwich` is populated, route to ContentView.
    ///   * `.locked`    — `pendingHardwareUnlock` is populated, route
    ///                    to HardwareUnlockView until the device is
    ///                    connected and the wrap-key signed.
    ///   * `.empty`     — nothing persisted, route to OnboardingView.
    /// Safe to call multiple times.
    enum LoadOutcome { case loaded, locked, empty }

    @discardableResult
    func loadIdentity() throws -> LoadOutcome {
        if sandwich != nil { return .loaded }
        if !pendingHardwareUnlock.isEmpty { return .locked }
        switch try IdentitySandwich.loadFromKeychain() {
        case .notProvisioned:
            return .empty
        case .loaded(let s):
            self.sandwich = s
            return .loaded
        case .wrappedAwaitingHardware(let enrollments):
            self.pendingHardwareUnlock = enrollments
            return .locked
        }
    }

    /// Install a freshly-generated or freshly-restored sandwich into
    /// the store. Called by OnboardingView / RecoveryView, and by
    /// the hardware-unlock flow once the sealed sandwich is opened.
    func adopt(_ sandwich: IdentitySandwich) {
        self.sandwich = sandwich
        self.pendingHardwareUnlock = []
    }

    /// Refresh every owned store from UserDefaults after an encrypted
    /// backup has been applied (`EncryptedBackup.applyWalletState` only
    /// writes UserDefaults; the live @Observable stores cached their
    /// state at launch and do not see the change on their own). Each
    /// store's `reload()` resets to defaults first, so a backup that
    /// omits a chain clears its stale wallets rather than leaving the
    /// pre-restore list in place. Call this from the restore path
    /// before `adopt(_:)` so the first ContentView render is correct.
    /// DisplayPreferences lives outside this store, so the caller
    /// reloads it separately.
    func reloadAfterRestore() {
        reloadAllStores()

        // Re-establish address-book mirroring after the wallet lists
        // changed, exactly as init() does at launch.
        bitcoinWalletStore.addressBook = addressBook
        bitcoinWalletStore.remirrorAllToAddressBook()
        ethereumWalletStore.addressBook = addressBook
        ethereumWalletStore.remirrorAllToAddressBook()
        solanaWalletStore.addressBook = addressBook
        solanaWalletStore.remirrorAllToAddressBook()
        tronWalletStore.addressBook = addressBook
        tronWalletStore.remirrorAllToAddressBook()
    }

    /// Refresh every owned @Observable store from its UserDefaults
    /// backing. Shared by the encrypted-backup restore path
    /// (`reloadAfterRestore`) and by the wallet-wide reset
    /// (`resetEverything`): after either operation, UserDefaults is in
    /// its post-write state and the in-memory caches need to catch up
    /// so the live UI shows the right thing without a force-quit.
    private func reloadAllStores() {
        bitcoinWalletStore.reload()
        bitcoinSettings.reload()
        bitcoinLabels.reload()
        ethereumWalletStore.reload()
        ethereumSettings.reload()
        ethereumCustomNetworks.reload()
        ethereumTokenStore.reload()
        ethereumTokenRegistry.reload()
        solanaWalletStore.reload()
        solanaSettings.reload()
        solanaSPLTokenStore.reload()
        solanaTokenCatalog.reload()
        tronWalletStore.reload()
        tronSettings.reload()
        tronTRC20TokenStore.reload()
        tronTokenCatalog.reload()
        lightningAccountStore.reload()
        idDocuments.reload()
        addressBook.reload()
        devices.reload()
        appStores.reload()
        miniAppSettings.reload()
        knownIssuers.reload()
        pendingPickups.reload()
        credentialFolderStore.reload()
        fiatPreferences.reload()
    }

    /// Clear the in-memory sandwich (after a wallet reset). Does NOT
    /// touch Keychain — the caller is responsible for wiping that.
    /// The launch router will swap back to OnboardingView on the next
    /// render pass.
    func clearSandwich() {
        self.sandwich = nil
        self.pendingHardwareUnlock = []
        self.credentials = []
        self.lastVerdict = nil
        self.lastVerifyAt = nil
        self.credentialNicknames = [:]
        UserDefaults.standard.removeObject(forKey: Self.credentialsKey)
        UserDefaults.standard.removeObject(forKey: Self.nicknamesKey)
        VerifierHistory.reset()
    }

    /// Factory reset. Wipes everything Maknoon has on this device:
    /// the Identity Sandwich (Keychain), every per-chain wallet
    /// store, every per-chain settings + label store, the device
    /// registry, the address book, ID documents, Lightning accounts,
    /// app-store registry, credentials, BDK SQLite files, and any
    /// other UserDefaults keys under known Maknoon namespaces.
    ///
    /// After clearing disk state, the function also refreshes every
    /// in-memory @Observable store from the now-empty UserDefaults
    /// (`reloadAllStores`) so the live UI reflects the wipe
    /// immediately. Force-quitting + relaunching is still a useful
    /// belt-and-suspenders step but no longer required for a correct
    /// clean slate.
    @MainActor
    func resetEverything() {
        clearSandwich()
        try? IdentitySandwich.wipe()

        // Iterates the in-memory IDDocument list to delete each saved
        // doc's JPEG + chip blob files. The recursive directory wipe
        // below catches any orphans on top.
        idDocuments.reset()

        // Every Maknoon-owned UserDefaults key falls under one of
        // these prefixes. The first-launch install token under
        // `maknoon.appInstallToken.*` is deliberately NOT here: we
        // want subsequent launches to still see the token and
        // therefore skip the first-launch re-wipe.
        let prefixes = [
            "networks.",
            "yubikey.",
            "devices.",
            "addressBook",
            "credentials",
            "credentialNicknames",
            "nostr.",
            // ID document metadata key is "iddocuments.v1" (all lowercase).
            // The legacy "idDocuments" spelling did not match and left
            // passport scans visible after a reset.
            "iddocuments",
            "lightning.",
            "appstore.",
            "identity.",
            // Fiat preferences keys are `app.fiatCurrencyCode` and
            // `app.fiatReferenceEnabled` — the legacy `fiat.` prefix
            // matched nothing.
            "app.fiat",
            "display.",
            "autolock.",
            "asset.",
            "backup.",
            "verifier.",
            "pendingPickups",
            // CredentialFolderStore: matches both `credentialFolders.v1`
            // and `credentialFolderMembership.v1`.
            "credentialFolder",
        ]
        let snapshot = UserDefaults.standard.dictionaryRepresentation()
        for key in snapshot.keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // File-system caches under Documents. `networks/` holds the
        // per-wallet BDK SQLite databases; `IDDocumentPhotos/` and
        // `IDDocumentChipData/` hold passport JPEG + raw SOD/DG blobs.
        if let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            for sub in ["networks", "IDDocumentPhotos", "IDDocumentChipData"] {
                let dir = docs.appendingPathComponent(sub, isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // Refresh every observable store from the now-empty
        // UserDefaults so the live UI reflects the wipe immediately.
        // Without this, the cached `@Observable` arrays survive (the
        // user lands on Onboarding with stale wallets / devices /
        // passport scans still visible behind the sheet) until the
        // next cold launch.
        reloadAllStores()

        LogStore.shared.info("reset", "Reset Maknoon: wiped Keychain + UserDefaults + Documents caches + in-memory stores")
    }

    /// Holder's long-term public key (the master ML-DSA-65 pubkey).
    /// Stable across app launches and across device migrations via the
    /// paper-seed recovery flow. nil until onboarding completes.
    var holderPublicKey: Data? { sandwich?.masterPublicKey }

    /// Sign a challenge for a presentation. SE-resident ephemeral signs
    /// every challenge (no Face ID per call). The sandwich auto-renews
    /// its delegation cert when it's within an hour of expiring; that
    /// renewal IS biometric-gated because it requires the master, so
    /// the first sign of the day may prompt Face ID. Subsequent signs
    /// for the rest of the day are silent.
    func signWithIdentity(_ message: Data) throws -> Data {
        guard let sandwich = sandwich else {
            throw SandwichError.masterUnavailable
        }
        return try sandwich.signChallenge(message)
    }

    /// Current delegation cert from the loaded sandwich. The Share flow
    /// embeds this in every Presentation so the verifier's
    /// `delegationValid` check can run.
    var currentDelegation: DelegationCert? { sandwich?.delegation }

    /// Cached SE ephemeral public key. The Presentation's
    /// `holderLongTermPk` still carries the master (it's the stable DID
    /// anchor); the ephemeral pubkey only needs to appear inside the
    /// delegation cert.
    var ephemeralPublicKey: Data? { sandwich?.ephemeralPublicKey }

    // MARK: -- credentials

    func addCredential(_ cred: Credential) {
        if credentials.contains(where: { $0.id == cred.id }) { return }
        // Supersede an older credential of the SAME type (same issuer,
        // subject, and schema) when a newer one arrives. This keeps a
        // refreshed / reissued credential from piling up next to the
        // stale copy (e.g. restore-time reissuance hands back a fresh
        // credential with a new cid but the same iss/sub/schema). The
        // user's nickname is carried over to the replacement.
        let superseded = credentials.filter {
            $0.header.iss == cred.header.iss
            && $0.header.sub == cred.header.sub
            && $0.header.schema == cred.header.schema
            && $0.id != cred.id
            && $0.header.iat <= cred.header.iat
        }
        if let inherited = superseded.compactMap({ nickname(for: $0.id) }).first,
           nickname(for: cred.id) == nil {
            setNickname(inherited, for: cred.id)
        }
        for old in superseded { removeCredential(id: old.id) }
        credentials.append(cred)
        // Default the nickname to the holder's Latin full name when
        // the credential carries givenName + familyName claims (true
        // for issuer-signed passport credentials and any future
        // identity-shaped schema with the same field names). Users
        // can rename or clear from the credential's detail view.
        if nickname(for: cred.id) == nil {
            let given = cred.claims["givenName"]?.displayText.trimmingCharacters(in: .whitespaces) ?? ""
            let family = cred.claims["familyName"]?.displayText.trimmingCharacters(in: .whitespaces) ?? ""
            let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            if !full.isEmpty { setNickname(full, for: cred.id) }
        }
        persistCredentials()
    }

    func removeCredential(id: String) {
        credentials.removeAll(where: { $0.id == id })
        setNickname(nil, for: id)
        persistCredentials()
    }

    /// Best-effort restore-time reissuance. After an encrypted-backup
    /// restore, ask every configured issuer to re-mint the latest
    /// credential it holds for our (restored, identical) holder DID,
    /// proving control with a master-key signature over an issuer nonce.
    /// Each reissued credential's pickup is handed to `pendingPickups`,
    /// whose background poller fetches it once anchored and imports it
    /// (superseding the backup copy via `addCredential`). Per-issuer
    /// failures are non-fatal: the restored backup copies remain valid.
    @MainActor
    func reissueCredentialsAfterRestore() async {
        guard let sandwich = self.sandwich else { return }
        let holderDID = sandwich.holderDID
        let pubHex = "0x" + sandwich.masterPublicKey.map { String(format: "%02x", $0) }.joined()
        let hosts = knownIssuers.hosts
        for host in hosts {
            guard let base = URL(string: "https://\(host)") else { continue }
            do {
                let nonce = try await IssuerClient.reissueChallenge(host: base, holderDID: holderDID)
                guard let message = "elabify-reissue:v1:\(holderDID):\(nonce)".data(using: .utf8) else { continue }
                let sig = try sandwich.signWithMaster(
                    message,
                    localizedReason: "Reissue your verified credentials"
                )
                let sigHex = "0x" + sig.map { String(format: "%02x", $0) }.joined()
                let result = try await IssuerClient.reissue(
                    host: base,
                    holderDID: holderDID,
                    masterPublicKeyHex: pubHex,
                    nonce: nonce,
                    signatureHex: sigHex
                )
                for r in result.reissued {
                    pendingPickups.add(PendingPickup(
                        id: r.credentialId,
                        credentialId: r.credentialId,
                        pickupURL: r.pickupUrl,
                        schemaURI: r.schema,
                        humanLabel: "Verified credential",
                        startedAt: Date()
                    ))
                }
                LogStore.shared.info(
                    "reissue",
                    "\(host): reissued=\(result.reissued.count) skipped=\(result.skipped?.count ?? 0)"
                )
            } catch {
                // Non-fatal: the restored backup credential copies remain
                // valid; the user can retry later from the issuer.
                LogStore.shared.error("reissue", "\(host): \(error.localizedDescription)")
                continue
            }
        }
    }

    private func persistCredentials() {
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: Self.credentialsKey)
        }
    }

    // MARK: -- backup snapshot / restore (full encrypted backup, v4)

    /// Snapshot of every verified credential currently held plus the
    /// holder-set nicknames. Used by the encrypted-backup pipeline to
    /// capture state at export time. Photos / chip binaries are NOT
    /// here (those live in IDDocumentStore); this struct covers the
    /// VC list only.
    struct CredentialsBackup: Codable, Sendable {
        let credentials: [Credential]
        let nicknames: [String: String]
        /// v5: user-created folders for the Identity stack. Optional
        /// for back-compat with v4 backups (decodes as nil; restore
        /// leaves the local folder list untouched).
        let folders: [CredentialFolder]?
        /// v5: cardId -> folderId membership map keyed by
        /// `WalletCardData.id`. Same back-compat semantics.
        let folderMembership: [String: UUID]?
    }

    func captureCredentialsBackup() -> CredentialsBackup {
        CredentialsBackup(
            credentials: credentials,
            nicknames: credentialNicknames,
            folders: credentialFolderStore.folders,
            folderMembership: credentialFolderStore.membership
        )
    }

    /// Clean-slate replace. Wipes the current credentials + nicknames
    /// in-place and substitutes the backup contents. Observers see one
    /// update at the end of the call.
    func applyCredentialsBackup(_ backup: CredentialsBackup) {
        credentials = backup.credentials
        credentialNicknames = backup.nicknames
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: Self.credentialsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.credentialsKey)
        }
        if let folders = backup.folders, let membership = backup.folderMembership {
            credentialFolderStore.applyBackup(folders: folders, membership: membership)
        }
        if let data = try? JSONEncoder().encode(credentialNicknames) {
            UserDefaults.standard.set(data, forKey: Self.nicknamesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.nicknamesKey)
        }
    }
}
