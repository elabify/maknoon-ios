# Maknoon (iOS)

Maknoon is a post-quantum, self-custodial identity and hardware-wallet iOS app
(SwiftUI, iOS 26+). It holds verifiable credentials, makes selective-disclosure
presentations to verifiers, and signs transactions on Ledger devices, with the
trust-critical cryptography in shared, audited native cores.

## Repository layout

The app lives in `ios-app-maknoon/`. Its native cores are **git submodules** checked
out at the sibling paths the Xcode project expects:

| Path | Submodule |
|------|-----------|
| `elabify-core/`   | cross-platform crypto core (RPO-256, Merkle, DID, ML-DSA-65) |
| `ledger-btc-rs/`  | Ledger Bitcoin Rust + UniFFI core |
| `ledger-eth-rs/`  | Ledger Ethereum core |
| `ledger-sol-rs/`  | Ledger Solana core |
| `ledger-tron-rs/` | Ledger Tron core |

These are the same cores a companion Android app builds against.

## Clone (with submodules)

```sh
git clone --recursive https://github.com/elabify/maknoon-ios.git
# already cloned without --recursive?
git submodule update --init --recursive
```

## Build (unsigned simulator)

```sh
# 1. Build the four Ledger xcframeworks from the crate submodules
for c in ledger-btc-rs ledger-eth-rs ledger-sol-rs ledger-tron-rs; do
  make -C "$c" ios
done

# 2. Generate the Xcode project and build
cd ios-app-maknoon
xcodegen generate
xcodebuild build -project Maknoon.xcodeproj -scheme Maknoon \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

`elabify-core` resolves as a local SwiftPM package at `../elabify-core/bindings/swift`.

## License

Apache-2.0, see [`LICENSE`](LICENSE). Third-party attributions in [`NOTICE`](NOTICE).
Each submodule carries its own license.
