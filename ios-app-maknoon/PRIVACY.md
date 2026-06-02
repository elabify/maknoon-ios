# Maknoon for iOS, Privacy Policy

**Effective date**: 2026-05-31
**Applies to**: the Maknoon iOS application (bundle id `com.elabify.app.maknoon`)
**Publisher**: Elabify

Maknoon is a self-custodial holder app. It is the iOS reference surface for the Musnad post-quantum identity stack and also includes a self-custodial Bitcoin and Ethereum wallet. This document describes what data the app handles, where that data lives, and what (very little) leaves your device.

If you have not yet read it, the project-wide privacy stance is in [`/PRIVACY.md`](https://musnad.elabify.com/privacy) at the repository root. This document is the app-specific overlay.

---

## 1. Plain-language summary

1. Maknoon does **not** ship analytics, crash reporting, advertising SDKs, attribution SDKs, or any third-party telemetry. There is no Firebase, no Crashlytics, no Sentry, no Mixpanel, no Amplitude.
2. Your recovery phrase (BIP39 mnemonic), wrap keys, and credential secrets never leave the phone. They live in the iOS Keychain with `NSFileProtectionComplete` and are excluded from iCloud and iTunes backups.
3. When you broadcast a Bitcoin or Ethereum transaction, that transaction is published to the relevant public blockchain by definition. That is a property of the blockchains, not a choice Maknoon makes.
4. Maknoon talks to a small set of public endpoints (mempool.space, an Ethereum RPC, optionally an issuer or verifier you choose to scan a QR for). It does not phone home to any Elabify service for telemetry.
5. Hardware wallets you pair with Maknoon (Ledger, Trezor, YubiKey) are interrogated only over their advertised transport. The app records the device serial, the BLE peripheral UUID where applicable, and your chosen label.

If you uninstall the app, all of the above is removed from the device by iOS as part of the standard uninstall flow.

---

## 2. Information processed on the device

### 2.1 Keys and secrets (never leave the phone)
- BIP39 master entropy and derived signing keys for Bitcoin and Ethereum wallets.
- ML-DSA-65 signing key for credential presentations, when present.
- Identity Sandwich wrap material: AES-256-GCM-sealed master entropy plus the per-device wrap blobs from your enrolled hardware devices.
- FIDO2 credential identifiers for any YubiKey enrolled in the Identity Sandwich.

All of the above are stored exclusively in the iOS Keychain. Access is gated by Face ID, Touch ID, or device passcode via `LocalAuthentication`. The Secure Enclave wraps the items where the platform supports it. None of these values are transmitted anywhere by Maknoon.

### 2.2 Wallet and credential metadata (local persistence)
- The list of Bitcoin and Ethereum wallets you have created or imported, their descriptors and account indices, and your chosen labels.
- Per-address and per-output labels you assign via the Bitcoin labels feature (Sparrow-shaped storage).
- The registry of hardware devices you have paired: device kind (Ledger, Trezor, YubiKey, SeedSigner), serial number as reported by the device, your chosen label, the BLE peripheral UUID for BLE devices, and any Identity Sandwich enrollment record.
- Cached credential records you have received from issuers, including the issuer DID and credential metadata. The encrypted PII envelope inside each credential remains encrypted at rest.

This metadata lives in app-private storage. iOS removes it on uninstall.

### 2.3 Diagnostic logs (local ring buffer)
The in-app `LogStore` keeps the last 500 log entries in process memory only. The buffer follows a strict policy documented in `Maknoon/Diagnostics/LogStore.swift`:

- Never logged: BIP39 entropy, mnemonic, sandwich passphrase, AES wrap keys, master keys, private keys.
- May be logged: chain addresses, transaction hashes, RPC URLs, BLE device serials, peripheral UUIDs, APDU status words, error messages, timestamps.

The "Share diagnostic logs" affordance in the About screen invokes the iOS share sheet so you can send the buffer to support yourself. Maknoon never uploads the log buffer on your behalf.

---

## 3. Network endpoints Maknoon contacts

Maknoon makes outbound network calls only in response to a user action. The endpoints are:

| Purpose | Default endpoint | What is sent |
|---|---|---|
| Bitcoin mempool and block data | mempool.space (mainnet, testnet3, signet) | Your wallet's descriptor-derived addresses for balance and transaction lookup. mempool.space sees the queried addresses by definition. |
| Bitcoin transaction broadcast | mempool.space `POST /api/tx` | The signed transaction. Public by definition once broadcast. |
| Ethereum JSON-RPC | The RPC URL configured in settings (default: a public Sepolia or mainnet endpoint depending on the wallet) | The standard JSON-RPC methods Maknoon needs (`eth_getBalance`, `eth_estimateGas`, `eth_sendRawTransaction`, etc.). The RPC provider sees your IP and the addresses you query. |
| Block explorer links | mempool.space, blockstream.info, etherscan.io (you tap a link, the iOS browser opens) | Whatever your iOS browser sends. |
| Issuer endpoint, when you accept a credential | The issuer host present in the QR or deep link you scanned, and only that host | The issuance acknowledgement payload defined in the Musnad wire formats. |
| Passport-backed credential issuance (opt-in) | The issuer host you select (default `musnad.elabify.com`), and only that host | Only when you tap "issue from this document": your passport chip data, comprising document number, full name (Latin and native-script), nationality, sex, date of birth, date of expiry, place of birth, and personal number, together with the chip's signed data objects (the SOD and data groups DG1, DG2, DG11, DG12, DG15). DG2 is your facial image. Also your holder DID, your ML-DSA-65 public key, and a signature. This is the data the issuer needs to verify and mint a credential. |
| Sanctions screening (opt-in) | The issuer host you select (default `musnad.elabify.com`), and only that host | Only when you tap "Check against OpenSanctions": your given name, family name, date of birth, and nationality. The issuer proxies a self-hosted matcher and returns the outcome. |
| Verifier endpoint, when you complete a presentation | The verifier host present in the request you scanned, and only that host | A ML-DSA-65-signed presentation with selective-disclosure encryption of any PII leaves. See the platform Privacy Policy and `the operations docs` for the full envelope. |

Maknoon does not contact Elabify-operated servers for telemetry. There is no analytics endpoint, no crash-report endpoint, no remote feature-flag service, no push token registration server.

Hosts contacted for issuance and presentation are pinned to a configured allowlist in production builds (`MusnadConfig.allowedIssuerHosts` and equivalent).

---

## 4. Hardware wallet transports

When you pair or use a hardware device, the data exchange is local-radio or local-USB:

- **Ledger Nano X over Bluetooth Low Energy**: Maknoon scans for and connects to the specific peripheral UUID captured at pair time. Sent: APDUs for the Bitcoin app (`registerWallet`, `getExtendedPubkey`, `signPsbt`, `getMasterFingerprint`) and the Ethereum app (`personal_sign` for Identity Sandwich wrap). Received: the device's responses to those APDUs.
- **Trezor Safe 5 over Bluetooth Low Energy**: same model. Trezor BLE support is in progress; currently a scaffold.
- **YubiKey 5 series over NFC or USB-C**: NFC is the primary transport. For serial read, Maknoon opens the Management application on the key and reads `DeviceInfo`. For Identity Sandwich enrollment and unlock, Maknoon opens a FIDO2 session and calls `makeCredential` or `getAssertion` with a deterministic client data hash. The hash binds your wrap salt and device serial; the resulting signature is hashed locally into the wrap key. No FIDO2 data leaves the phone.
- **SeedSigner over QR camera**: Maknoon reads QR codes the SeedSigner displays. No radio exchange; nothing is transmitted to SeedSigner besides what you scan back.

Hardware-device serials and (for BLE) peripheral UUIDs are recorded in app-local storage so subsequent connects target the same physical device. These identifiers are not transmitted to any Elabify service.

---

## 5. Information Maknoon does not collect

With one explicit, opt-in exception, Maknoon does **not** collect, store, or transmit:

- Your name, address, phone number, email address, or other directly identifying contact data.
- Your location.
- Your photos, contacts, microphone, calendar, reminders, or health data.
- Device advertising identifiers (IDFA, IDFV).
- Crash reports or stack traces. iOS may collect anonymous crash data and send it to Apple if you have enabled that in Settings. Apple's handling is governed by Apple's privacy policy, not by Maknoon.
- App-usage telemetry, screen views, button taps, or session metrics.

**The one exception: opt-in identity flows.** If you scan an ID document and then choose to
either request a verified credential ("issue from this document") or run a sanctions check
("Check against OpenSanctions"), Maknoon transmits the document fields described in §3 to the
issuer host you select. This is the only path on which your name, date of birth, nationality,
and (for passport-backed issuance) your document number and chip facial image leave the device.
It never happens automatically; it only happens when you tap one of those buttons. Nothing is
sent to any Elabify-operated telemetry endpoint in either case.

---

## 6. Permissions Maknoon requests

| iOS capability | Reason | Trigger |
|---|---|---|
| Face ID / Touch ID (`NSFaceIDUsageDescription`) | Unlock signing keys for transactions and presentations | First and every subsequent signing operation |
| Bluetooth (`NSBluetoothAlwaysUsageDescription`) | Talk to a paired Ledger or Trezor | Hardware wallet operations |
| Camera (`NSCameraUsageDescription`) | Scan QR codes from issuers, verifiers, or SeedSigner | QR scan flows |
| NFC reader (`NFCReaderUsageDescription`, `com.apple.developer.nfc.readersession.formats: TAG`) | Talk to YubiKey over NFC | YubiKey serial read or FIDO2 wrap |
| External Accessory (`com.yubico.ylp` in `UISupportedExternalAccessoryProtocols`) | Talk to YubiKey over USB-C | YubiKey USB-C serial read |

Maknoon does not request location, microphone, contacts, photos, calendar, reminders, health, or motion. iOS will not let the app access these without explicit prompts, and Maknoon has no code path that asks.

---

## 7. Backups, sync, and reset

- **iCloud and iTunes backups**: the Keychain items containing wallet keys, wrap material, and Identity Sandwich blobs have `NSFileProtectionComplete` and are excluded from device backups. Wallet metadata (descriptors, labels, device registry) lives in app-private storage that is excluded from backup via `backup-not-included` rules. Cold restore from an iCloud backup of your phone restores the app shell but not your keys; you re-import from your paper seed.
- **iCloud Keychain syncing**: Maknoon's Keychain items use the local-only access group; they do not sync to other devices.
- **Reset**: the in-app "Reset wallet" option (visible on the hardware-unlock screen and in settings) wipes every Identity Sandwich blob, every wrapped material item, every registered device, every chain wallet, and every label. After reset you can restore from your 24-word paper seed.
- **Uninstall**: iOS deletes all app-local storage and all of Maknoon's Keychain items when you uninstall the app.

---

## 8. Children

Maknoon is not directed at children under 13 and Elabify does not knowingly handle data from children. The app is intended for users who can legally hold a self-custodial wallet in their jurisdiction.

---

## 9. Regional notes

- **GDPR / UK GDPR**: Maknoon does not act as a controller of personal data, because no personal data is sent to any server Elabify operates. Issuance and presentation flows you initiate may involve a verifier or issuer that is itself a controller; you contract with those parties directly. Their privacy notices apply.
- **CCPA / CPRA**: Elabify does not sell or share personal information about you, because Elabify does not have personal information about you.
- **UAE PDPL**: same posture as GDPR: there is no cross-border transfer because there is no transfer at all.

---

## 10. Changes to this policy

Material changes will land as commits to this file in the public repository. The Effective date at the top of this document is updated when the substance changes. The git history is the canonical changelog.

---

## 11. Contact

Privacy questions: `privacy@elabify.com`
Security issues: `security@elabify.com` (please do not file public GitHub issues for unpatched vulnerabilities)

This document is open-source. Suggestions, corrections, and pull requests are welcome at the project repository.
