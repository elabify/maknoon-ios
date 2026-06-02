// Settings → Display: theme, auto-lock, language. Each control
// is a single Picker that mutates the shared DisplayPreferences;
// the visual side-effects (color scheme, locale, lock cadence)
// are wired at the app root so a change here propagates app-wide.

import SwiftUI

struct DisplaySettingsView: View {
    @Environment(DisplayPreferences.self) private var prefs

    var body: some View {
        @Bindable var bindable = prefs
        Form {
            Section {
                Picker(selection: $bindable.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                } label: {
                    Label("Theme", systemImage: "paintbrush")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Theme")
            } footer: {
                if prefs.theme == .automatic {
                    Text("Switches to Light between 6:00 AM and 6:00 PM local time, otherwise Dark.")
                        .font(.caption)
                }
            }

            Section {
                Picker(selection: $bindable.autoLock) {
                    ForEach(AutoLockTimeout.allCases) { timeout in
                        Text(timeout.label).tag(timeout)
                    }
                } label: {
                    Label("Auto-Lock", systemImage: "lock.circle")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Auto-Lock")
            } footer: {
                Text("Locks Maknoon after a period of inactivity. Unlock with Face ID, Touch ID, or your iPhone passcode.")
                    .font(.caption)
            }

            Section {
                Picker(selection: $bindable.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Language")
            } footer: {
                Text("More languages will be added in future updates.")
                    .font(.caption)
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }
}
