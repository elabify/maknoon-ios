# Maknoon: notes for App Review

Paste the relevant parts of this file into App Store Connect → your build →
"Notes for Review" (the App Review Information field). Fill in the two
bracketed links first (see "Before you submit" at the bottom).

## What Maknoon is

Maknoon is a self-custodial wallet from Elabify LLC. It does two things:

1. **Holds crypto self-custodially.** Bitcoin, Ethereum, Solana, Tron, plus
   their tokens, and user-supplied Lightning accounts. Keys are generated and
   stored on device (iOS Keychain, Secure Enclave where available) and never
   sent to any server. This is why Elabify is enrolled as an organization
   per App Review Guideline 3.1.5(b).
2. **Holds post-quantum verified-credential identity.** The user receives a
   signed credential from an issuer and later presents selected fields to a
   verifier. This is the Musnad identity stack; the pilot issuer and verifier
   run at `musnad.elabify.com` on the Ethereum Sepolia test network.

## No account is required

The wallet and all crypto features work immediately after onboarding with no
sign-up, no login, and no Elabify-side account. There is nothing to create or
delete on our servers. "Reset Wallet" (Settings) wipes all local data.

## How to exercise the identity feature (the part that needs a server)

The wallet is fully testable on its own. The credential receive/present flow
needs a live issuer and verifier, so here is a complete path:

1. Launch the app and complete onboarding (it generates a 24-word recovery
   phrase locally; you can write down placeholder words for review).
2. Go to the **Identity** tab and tap **Receive credential**.
3. Tap **Paste a pickup URL** and paste the demo pickup URL below, then accept
   the credential. (Alternatively, point the camera at the demo QR below.)
   The credential then appears in the Identity tab.
4. To present it: open the demo verifier page below on a second screen (laptop
   or another phone). It shows a verifier request QR.
5. Back in the app, on the **Identity** tab, scan the verifier's QR, review the
   fields being requested, and approve. The verifier page shows a GRANT result.

- Demo credential pickup URL (paste into "Receive credential"):
  `[PASTE A CURRENT musnad.elabify.com PICKUP URL HERE]`
- Demo verifier request page (shows the QR to scan):
  `[PASTE THE musnad.elabify.com VERIFIER DEMO URL HERE]`

These links point at the live Sepolia pilot stack and require no credentials of
your own. If a link has expired, contact us at the email below for a fresh one.

## Permissions, and why each is requested

- **Face ID / passcode**: unlock the app and authorize signing. No biometric
  data leaves the device.
- **Camera**: scan issuer and verifier QR codes.
- **Bluetooth**: talk to a paired Ledger hardware wallet, and share a signed
  credential directly with another phone in the room. No server involved.
- **NFC**: read a YubiKey on tap, and optionally read an ID document chip when
  the user explicitly taps "Tap ID document."

## Data handling (matches our privacy nutrition labels and PRIVACY.md)

- The app sends no analytics, crash, or telemetry data anywhere.
- Identifying data (name, date of birth, nationality, and for passport-backed
  issuance the document number and chip facial image) leaves the device **only**
  when the user explicitly opts into passport-backed credential issuance or an
  opt-in sanctions check, and then only to the issuer host the user selects
  (default `musnad.elabify.com`). This is disclosed in `PRIVACY.md` §3 and §5.
- Lightning accounts are user-supplied third-party custodial accounts (LNDHub,
  the same format Zeus and BlueWallet use). Maknoon stores the user's own
  credentials locally and talks only to the server the user configured. Maknoon
  is not a money-transmission service.

## Contact

privacy@elabify.com / security@elabify.com

---

## Before you submit (action items for the Elabify team, not for Apple)

1. Replace the two bracketed links above with a current, publicly reachable
   demo pickup URL and verifier URL from the `musnad.elabify.com` console.
2. In App Store Connect → App Privacy, set the nutrition labels to match
   `PRIVACY.md`: Contact Info (Name), Sensitive Info / government-ID, and
   Identifiers as **collected, not used for tracking**, tied to the opt-in
   identity flows. Everything else: not collected.
3. Confirm the app record is under the Elabify LLC **organization** account
   (required for a crypto wallet under Guideline 3.1.5(b)).
