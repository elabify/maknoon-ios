# Upgrade safety rules

The Maknoon iOS app is a wallet. Users assume that a software update can never make their money disappear. If we ever show a zero balance and an empty transaction list on a wallet that has on-chain funds, the user will assume we drained it, regardless of what we say in chat. **Treat the "wallet looks empty after upgrade" failure mode as a critical bug, not a UX paper cut.**

This file documents the things that will silently strand a user's wallet if we change them, and the rules we follow to avoid that.

## Things that look like "we drained them" if mishandled

Each of the following, if changed in an upgrade without a migration, makes an already-funded wallet appear empty on next launch. None of them actually touch on-chain money; the user just can't see it.

1. **Bundle identifier** (`com.elabify.maknoon`). Changing this means a brand-new iOS container: no UserDefaults, no Documents, no Keychain. The Identity Sandwich and every wallet are gone from the device. The user can recover from their 24-word phrase, but there is no in-app affordance for "rescue from previous bundle id." Bundle ID is therefore frozen.

2. **UserDefaults keys** under `networks.bitcoin.*`. The wallet list, active wallet id, label maps, settings, and appstore registry all live here. If a key renames without a read-old-then-write-new migration, the data is orphaned.

3. **Documents subpath** `networks/bitcoin/<wallet-id>/wallet.sqlite`. This is the BDK persisted state. The `<wallet-id>` UUID is the join key between UserDefaults and Documents. Renaming the path orphans every persisted wallet.

4. **Keychain item keys** (`KeyStoreKeys.*`). The Identity Sandwich entropy, the iCloud backup metadata, and (soon) the YubiKey-wrapped entropy all live in Keychain. Renaming a key strands the secret it's protecting.

5. **iCloud container identifier** (`iCloud.com.elabify.maknoon`, when CloudKit is wired). Changing this strands every uploaded encrypted backup.

6. **BDK descriptor derivation**. The BIP84 path Maknoon builds from the sandwich seed (`m/84'/<coin>'/<account>'/...`) is what `Wallet.load()` checks against the persisted descriptor. If we change the derivation in any way (different account default, different keychain split, different network coin type), every persisted SQLite becomes unloadable.

7. **BDK version bumps**. BDK occasionally changes its on-disk schema. Loading an old SQLite against a new BDK throws `LoadWithPersistError.Persist`. This is the one we cannot fully prevent — but we can and do soft-handle it (see "Self-heal" below).

## Rules when making changes

- **No bundle ID changes.** Period. If we need a rebrand at the iOS level, we ship a separate app and provide an explicit migration flow inside the old one. Comments in code that change "what the bundle ID conceptually means" are fine; the string literal in `project.yml` is not.

- **No UserDefaults key renames without a migration.** If the key changes from `X` to `Y`, the new code reads `Y` first, then falls back to reading `X` and writing `Y` (one-shot migration). Only after a few releases do we delete the `X` read path. Same rule for any path on disk.

- **No silent on-disk wipes.** If we have to wipe `Documents/networks/bitcoin/<id>/wallet.sqlite` because BDK can't load it (this is the BDK-version-bump case), we MUST also:
  1. Clear `lastSyncAt` on the wallet descriptor so the next refresh runs a `fullScan` instead of an incremental sync. Otherwise the wallet visibly stays at zero forever.
  2. Surface a banner explaining that the local cache was rebuilt and the on-chain funds are safe.
  This is what `BitcoinWallet.openWithResult(...)` returns the `rebuilt` flag for; `BitcoinWalletView` consumes it.

- **No descriptor derivation changes** without a versioned descriptor on the wallet metadata. Today every wallet is BIP84 single-sig and the descriptor builder is deterministic from `(seed, account, network)`. If we ever change that (multi-sig, Taproot, a different gap limit), the new shape needs a different `BitcoinWalletKind` case so the store can tell them apart.

- **Discover stays prominent.** The Bitcoin wallets management screen has a "Discover existing wallets" button that scans the user's seed for on-chain activity. It's the lifeline if every other guardrail fails. It must always be one tap from the Bitcoin section header.

## How upgrades are tested

Manual checklist for any PR that touches `Bitcoin/*`, the wallet store, Identity Sandwich storage, or the bundle id:

- [ ] Install previous build on simulator. Receive on Testnet3 or Signet. Wait for at least one confirmation. Verify balance + tx count on the Bitcoin tab.
- [ ] Without uninstalling, install the new build (`xcrun simctl install booted Maknoon.app`).
- [ ] Open the Bitcoin tab. Balance should match. Transactions should still appear. No "phantom zero" state.
- [ ] If a local-cache-rebuilt banner appears, it must be honest: it must trigger a fullScan, and the wallet must populate within ~30 s.
- [ ] Switch tabs to Identity and back. State must persist.
- [ ] Cold-launch the app. State must persist.

Failures on any of these block the deploy.

## Things this file is NOT about

- Bugs that lose data on a fresh install. Those are normal correctness work.
- Bugs in send / sign / broadcast. Those are signing-path bugs.
- BDK-internal recovery flows. We rely on BDK to be correct about its own state; the only thing we own is the wipe-and-rescan recovery path documented above.
