// Settings → Currency. Picks the fiat used in reference captions
// across every wallet view + send screen, and exposes the master
// switch to turn the feature off entirely for users who don't
// want Maknoon talking to CoinGecko at all.

import SwiftUI

struct CurrencySettingsView: View {
    @Environment(HolderStore.self) private var store

    var body: some View {
        @Bindable var prefs = store.fiatPreferences
        Form {
            Section {
                Toggle("Show reference prices", isOn: $prefs.showReferencePrices)
                    .onChange(of: prefs.showReferencePrices) { _, newValue in
                        if newValue {
                            // User flipped it back on; warm the
                            // cache so the picker preview is
                            // populated.
                            store.assetPrices.refreshAll(fiat: prefs.code)
                        }
                    }
            } footer: {
                Text("Shows an approximate value in your chosen currency next to each amount. Turn off to stop Maknoon contacting any price service.")
                    .font(.caption)
            }

            if prefs.showReferencePrices {
                Section {
                    Picker("Display currency", selection: $prefs.code) {
                        ForEach(FiatCurrencyCatalog.sortedCodes, id: \.self) { code in
                            Text(FiatCurrencyCatalog.pickerLabel(code))
                                .tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .onChange(of: prefs.code) { _, newCode in
                        // Warm the cache for the new currency.
                        store.assetPrices.refreshAll(fiat: newCode)
                    }
                } header: {
                    Text("Currency")
                } footer: {
                    Text("The currency used for those approximate values.")
                        .font(.caption)
                }

                Section {
                    TextField("CoinGecko base URL", text: $prefs.coinGeckoBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: prefs.coinGeckoBaseURL) { _, _ in
                            store.assetPrices.refreshAll(fiat: prefs.code)
                        }
                    TextField("USD FX rates URL", text: $prefs.fxBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: prefs.fxBaseURL) { _, _ in
                            store.assetPrices.refreshAll(fiat: prefs.code)
                        }
                    Button("Reset to defaults") {
                        prefs.coinGeckoBaseURL = FiatPreferences.defaultCoinGecko
                        prefs.fxBaseURL = FiatPreferences.defaultFX
                        store.assetPrices.refreshAll(fiat: prefs.code)
                    }
                } header: {
                    Text("Price data sources")
                } footer: {
                    Text("Advanced: use your own price and exchange-rate sources instead of the defaults.")
                        .font(.caption)
                }

                Section {
                    samplePreview
                } header: {
                    Text("Preview")
                }
            }
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var samplePreview: some View {
        let prefs = store.fiatPreferences
        return VStack(alignment: .leading, spacing: 6) {
            row("1 BTC", asset: "bitcoin", amount: 1)
            row("0.001 BTC", asset: "bitcoin", amount: Decimal(string: "0.001") ?? 0)
            row("1 ETH", asset: "ethereum", amount: 1)
        }
        .font(.callout)
        .onAppear {
            store.assetPrices.refreshAll(fiat: prefs.code)
        }
    }

    private func row(_ label: String, asset: String, amount: Decimal) -> some View {
        let prefs = store.fiatPreferences
        let caption = store.assetPrices.fiatCaption(amount: amount, asset: asset, fiat: prefs.code)
        return HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(caption ?? "-")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
