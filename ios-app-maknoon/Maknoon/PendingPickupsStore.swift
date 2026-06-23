// Background-polling store for credentials that have been minted on
// the issuer side but not yet anchored / picked up.
//
// Lifecycle:
//   - The passport-issuance flow (or any future issuance path that
//     returns a pickup URL) appends a `PendingPickup` here and
//     returns the user to the Identity tab immediately.
//   - This store drives a single Task that polls every entry's
//     pickup URL on a 10-second cadence via the existing
//     `IssuerClient.pickup(url:)` API.
//   - When the issuer reports `.ready`, the store calls back to its
//     owner (HolderStore.addCredential) and removes the entry.
//   - Entries can be cancelled by the user; that just removes the
//     row locally, the server-side credential is untouched and can
//     still be re-fetched later through a fresh issuance request.
//   - Persisted to UserDefaults so a pending pickup survives an app
//     restart; the polling Task resumes on next launch.

import Foundation
import Observation

/// One credential the issuer has minted that we haven't anchored +
/// imported into the wallet yet.
struct PendingPickup: Codable, Identifiable, Hashable, Sendable {
    /// Stable id: the credentialId returned by the issuer when the
    /// packet was approved. Unique per credential.
    let id: String
    /// Same as `id`. Carried separately so the type is self-explanatory
    /// at call sites that just want the credential identifier.
    let credentialId: String
    /// Fully-qualified pickup URL the issuer handed back. Already
    /// LAN-rewritten by the submitter if necessary.
    let pickupURL: String
    /// Credential schema URI, used to render the palette icon /
    /// gradient on the pending row. Optional for forward compat with
    /// future issuance flows that don't know the schema up front.
    let schemaURI: String?
    /// Human label shown on the pending row when `schemaURI` doesn't
    /// resolve to a known palette. For passports we set this to
    /// "Verified Identity" so the row is meaningful even before the
    /// schema-palette lookup runs.
    let humanLabel: String
    /// When the pickup was first queued. Drives the relative-time
    /// caption on the row and helps surface "stuck" entries.
    let startedAt: Date
}

// Not `@MainActor`-isolated, instantiated from HolderStore.init
// which is nonisolated. All public mutating entry points run on the
// main actor (UI thread) by convention, mirroring the rest of
// HolderStore's sub-stores; the background polling Task explicitly
// hops to @MainActor when touching observable state.
@Observable
final class PendingPickupsStore {
    private(set) var pending: [PendingPickup] = []
    /// Per-id reason for the most recent poll error, if any. Sticky
    /// until the entry succeeds or is cancelled, keeps a misbehaving
    /// row visible in the UI without dropping it from the list.
    private(set) var lastError: [String: String] = [:]

    private static let storeKey = "pendingPickups.v1"
    private static let pollIntervalSeconds: UInt64 = 10
    private var pollingTask: Task<Void, Never>?
    private var importCredential: (@MainActor (Credential) -> Void)?

    init() {
        load()
    }

    /// Wire the credential-import callback. Called once at
    /// HolderStore.init so this store knows where to hand off a
    /// credential when the issuer reports `.ready`.
    func wire(importCredential: @escaping @MainActor (Credential) -> Void) {
        self.importCredential = importCredential
        ensurePollingRunning()
    }

    func add(_ pickup: PendingPickup) {
        if pending.contains(where: { $0.id == pickup.id }) { return }
        pending.append(pickup)
        persist()
        ensurePollingRunning()
    }

    func cancel(id: String) {
        pending.removeAll { $0.id == id }
        lastError.removeValue(forKey: id)
        persist()
        if pending.isEmpty { pollingTask?.cancel(); pollingTask = nil }
    }

    // MARK: -- internals

    /// Start the polling loop if there's pending work and no Task is
    /// already running. Idempotent.
    private func ensurePollingRunning() {
        guard !pending.isEmpty, pollingTask == nil else { return }
        pollingTask = Task { @MainActor in
            await runPollLoop()
        }
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            // Snapshot so mutations during iteration don't surprise us.
            let snapshot = pending
            if snapshot.isEmpty { break }
            for entry in snapshot {
                if Task.isCancelled { return }
                guard let url = URL(string: entry.pickupURL) else {
                    lastError[entry.id] = "Bad pickup URL"
                    continue
                }
                do {
                    let outcome = try await IssuerClient.pickup(url: url)
                    switch outcome {
                    case .ready(let credential):
                        await importCredential?(credential)
                        pending.removeAll { $0.id == entry.id }
                        lastError.removeValue(forKey: entry.id)
                        persist()
                    case .pending:
                        lastError.removeValue(forKey: entry.id)
                    }
                } catch {
                    // Soft-fail: keep the entry in the list so the
                    // user sees the error and can cancel; the polling
                    // loop retries on the next tick. Hard transport
                    // errors (network down, server 5xx) are typically
                    // transient and recover on their own.
                    lastError[entry.id] = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            if pending.isEmpty { break }
            // Sleep between sweeps. CancellationError on the sleep
            // means we were stopped, propagate it through the while
            // check on the next iteration.
            try? await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
        }
        pollingTask = nil
    }

    // MARK: -- persistence

    /// Drop the in-memory cache, cancel any in-flight polling, and
    /// re-read from UserDefaults. Used by the wallet-wide reset path
    /// so the wipe surfaces immediately without waiting for a
    /// force-quit.
    func reload() {
        pollingTask?.cancel()
        pollingTask = nil
        pending = []
        lastError = [:]
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let arr = try? JSONDecoder().decode([PendingPickup].self, from: data)
        else { return }
        pending = arr
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
