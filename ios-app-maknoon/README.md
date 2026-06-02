# Maknoon (iOS)

Maknoon is a post-quantum, self-custodial **identity wallet and hardware wallet** for
iOS (iOS 26+, SwiftUI). It holds verifiable credentials, makes selective-disclosure
presentations to verifiers, and signs transactions on Ledger devices, with the
trust-critical cryptography in audited, native cores.

## What it does

- **Identity credentials**: scan an ICAO 9303 passport over NFC, hold issuer-signed
  or self-signed credentials, and present **selectively disclosed** claims (e.g.
  `over18` without revealing date of birth) to a verifier.
- **Post-quantum**: ML-DSA-65 signatures and an Identity-Sandwich delegation model;
  the device's Secure Enclave signs challenges, chained to a long-term key.
- **Hardware wallets**: Bitcoin, Ethereum, Solana, and Tron signing over BLE via the
  Ledger device apps.
- **Verification transports**: present over a one-shot network drop link or a QR.

## Architecture

A SwiftUI shell over native cores:

- **`elabify-core/`** (sibling): RPO-256 / Merkle / canonical-JSON / DID crypto.
- **`ledger-{btc,eth,sol,tron}-rs/`** (siblings): Rust + UniFFI cores that speak the
  Ledger device protocols, built into `*.xcframework`s the app links.

The relative dependency paths in `project.yml` resolve because these live as
repo-root siblings.

## Building

```sh
# 1. Build the four Ledger xcframeworks
for c in ledger-btc-rs ledger-eth-rs ledger-sol-rs ledger-tron-rs; do
  make -C "$c" ios
done

# 2. Generate the project and build (unsigned)
xcodegen generate
xcodebuild build -project Maknoon.xcodeproj -scheme Maknoon \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Tests: `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'`.

## License

Dual-licensed Apache-2.0 OR MIT, see [`LICENSE.md`](LICENSE.md). Privacy details:
<https://musnad.elabify.com/privacy>.
