# Maknoon: App Store territory availability

This document records which App Store territories Maknoon should be available in,
and which to exclude. The machine-readable companion is `availability.json` in
this same folder.

Last reviewed: 2026-06-01.

## A note on terminology

This is **not** an Apple "Routing App Coverage File." That artifact is a GeoJSON
of map polygons and applies only to apps in the **Navigation / Maps routing**
category; it has no effect on which countries can download an app. What actually
gates download availability is the **territory availability list** under
App Store Connect to App to Distribution to **Pricing and Availability to
Availability**, which is set per ISO territory. This document and
`availability.json` describe that list.

## Why we restrict at all

Maknoon is a **self-custodial** wallet with **no custodial holdings, no fiat
handling, and no money transmission** (see `REVIEW_NOTES.md` and `PRIVACY.md`).
Keys are generated and held on device; Elabify holds nothing. That profile means
two narrow categories of jurisdiction warrant exclusion:

1. **Absolute / comprehensive crypto bans** that criminalize an *individual*
   possessing or using cryptocurrency, which is exactly what a self-custody
   wallet enables. Banking-only bans (which restrict banks and exchanges, not
   individuals) are treated separately, because they do not clearly reach a
   non-custodial, no-fiat app.
2. **Sanctioned territories** where the Apple Developer Program already
   prohibits distribution. These have no App Store storefront, so they are
   excluded by default and cannot be toggled on.

## Excluded territories

| Territory | ISO | ASC id | Basis | Why |
|---|---|---|---|---|
| Algeria | DZ | DZA | Absolute ban | Purchase, sale, use, and holding of virtual currency prohibited for individuals. |
| Nepal | NP | NPL | Absolute ban | Use, holding, and mining of any cryptocurrency illegal. |
| China (mainland) | CN | CHN | Comprehensive ban | 2021 ban extended in 2025 to suspend transactions with asset-seizure and enforcement. |
| Bangladesh | BD | BGD | Comprehensive ban | All crypto activity declared illegal; prosecutable under AML and forex law. |
| Afghanistan | AF | AFG | Comprehensive ban | Crypto prohibited since 2022, users and traders penalized. |
| Egypt | EG | EGY | Comprehensive ban | Banking law plus religious edict; licensing requirement effectively bans crypto. |
| Morocco | MA | MAR | Comprehensive ban | Total ban since 2017 (legalization draft pending, revisit if passed). |
| Cuba | CU | CUB | Sanctions, no distribution | OFAC-sanctioned; Apple Developer Program prohibits distribution. |
| Iran | IR | IRN | Sanctions, no distribution | OFAC-sanctioned; no App Store storefront. |
| North Korea | KP | PRK | Sanctions, no distribution | OFAC-sanctioned; no App Store storefront. |
| Syria | SY | SYR | Sanctions, no distribution | OFAC-sanctioned; no App Store storefront. |

The Crimea, Donetsk, and Luhansk regions of Ukraine are OFAC-sanctioned, but
there is no separate App Store territory for them (they fall under Ukraine, UKR)
and no per-region toggle. Distribution there is prohibited by the developer
agreement regardless.

## Available, but tracked (do not exclude without re-deciding)

| Territory | ISO | Basis | Why it stays available |
|---|---|---|---|
| European Union (all members) | EU | Regulated, not banned | AMLR / MiCA regulate custodial intermediaries and anonymous custodial accounts. Self-hosted wallets and P2P transfers are explicitly excluded, so self-custody is legal. |
| Qatar | QA | Banking ban | Ban targets institutions and crypto services, not individual self-custody. Conservative teams may still choose to exclude. |
| Iraq | IQ | Banking ban | Central-bank directive targets financial institutions; reach to individual self-custody unsettled. |
| Tunisia | TN | Banking ban | Rules ban crypto for payments, not possession. |
| Bolivia | BO | Ban lifted | The historic ban was **lifted in June 2024**. Older listicles still name Bolivia; do not re-add it on that basis. |

## How to apply this in App Store Connect

1. App Store Connect to your app to **Distribution** to **Pricing and
   Availability** to **Availability**.
2. Start from "All countries and regions," then **deselect** each territory in
   the Excluded table above. (Sanctioned territories will already be
   unavailable.)
3. Save. The change applies to new downloads; existing installs are unaffected.

Alternatively, automate via the App Store Connect API using the
`appAvailabilities` and `territoryAvailabilities` resources, driving the list
from `availability.json` (territory ids there are the alpha-3 ASC Territory ids).

## Maintenance

Crypto law moves quickly and these bans get reversed (see Bolivia) and tightened
(see China 2025). Re-review this file before each major submission. When a
country's status changes, update both this table and `availability.json`, and
move the entry between the Excluded and tracked sections rather than deleting it,
so the rationale history is preserved.

## Sources

- [Legality of cryptocurrency by country or territory, Wikipedia](https://en.wikipedia.org/wiki/Legality_of_cryptocurrency_by_country_or_territory)
- [Where Is Crypto Illegal in 2026, Cloudwards](https://www.cloudwards.net/where-is-crypto-illegal/)
- [10 Countries Where Crypto Remains Banned in 2025, CCN](https://www.ccn.com/education/crypto/10-countries-where-crypto-remains-banned/)
- [No, the EU is not banning self-custodial crypto wallets, The Block](https://www.theblock.co/post/284442/no-the-eu-is-not-banning-self-custodial-crypto-transactions-or-wallets)
- [Apple Developer Program License Agreement / terms](https://developer.apple.com/support/terms/)
