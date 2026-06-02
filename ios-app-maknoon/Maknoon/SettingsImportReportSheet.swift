// Result sheet shown after a SettingsBackup import. Lists what
// was applied and (more usefully) what wasn't, so a user importing
// a backup from a newer build / different config knows exactly
// which items they may need to re-create by hand.

import SwiftUI

struct SettingsImportReportSheet: View {
    let report: SettingsBackupReport
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                if !report.imported.isEmpty {
                    importedSection
                }
                if !report.skipped.isEmpty {
                    skippedSection
                }
                if let note = report.versionNote {
                    versionNoteSection(note)
                }
            }
            .navigationTitle("Import results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            HStack {
                Image(systemName: report.hasGaps
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.seal.fill")
                    .foregroundStyle(report.hasGaps ? .orange : .green)
                Text(report.hasGaps
                     ? "Settings imported with some items skipped"
                     : "Settings imported successfully")
                    .font(.callout.weight(.semibold))
            }
            Text(report.hasGaps
                 ? "We applied everything this build understands. Review the lists below; any item under \"Not imported\" needs to be re-created from the in-app settings."
                 : "Every item in the backup file applied cleanly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var importedSection: some View {
        Section {
            ForEach(sortedImports, id: \.key) { entry in
                HStack {
                    Text(humanLabel(for: entry.key))
                    Spacer()
                    Text("\(entry.value)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Imported (\(report.totalImported))")
        }
    }

    private var skippedSection: some View {
        Section {
            ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Not imported (\(report.skipped.count))")
        } footer: {
            Text("These entries reference networks, device kinds, or fields this build doesn't recognize. Update Maknoon to a newer version if a future build supports them, or re-create them by hand from Settings.")
                .font(.caption)
        }
    }

    private func versionNoteSection(_ note: String) -> some View {
        Section {
            Text(note).font(.callout)
        } header: {
            Text("Schema version")
        }
    }

    /// Sort imported counts so the user sees the same order across
    /// runs and the sections that actually have items first.
    private var sortedImports: [(key: String, value: Int)] {
        report.imported
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    /// Friendly labels for the internal section keys. Anything not
    /// in this map falls back to the raw key, which is still
    /// readable.
    private func humanLabel(for key: String) -> String {
        switch key {
        case "addressBook":          return "Address book contacts"
        case "bitcoin.electrum":     return "Bitcoin Electrum endpoints"
        case "bitcoin.explorer":     return "Bitcoin explorer URLs"
        case "bitcoin.mempool":      return "Bitcoin mempool URLs"
        case "devices":              return "Registered devices"
        case "ethereum.explorer":    return "Ethereum explorer URLs"
        case "ethereum.explorerAPI": return "Ethereum explorer API URLs"
        case "ethereum.rpc":         return "Ethereum RPC endpoints"
        case "knownIssuers":         return "Known issuers"
        default:                     return key
        }
    }
}
