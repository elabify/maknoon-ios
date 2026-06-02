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
                Text("When on, Maknoon shows fiat-equivalent captions next to native amounts. Crypto is priced in USD from CoinGecko (https://api.coingecko.com) and then converted to your display currency using daily USD foreign-exchange rates from open.er-api.com. When off, no reference prices are displayed anywhere and Maknoon contacts neither service. There is no self-hosted spot-price source today.")
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
                    Text("Used across Bitcoin, Lightning, Ethereum, and ERC-20 token displays. Native amounts always remain primary; the fiat caption is informational.")
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
            Text(caption ?? "—")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
