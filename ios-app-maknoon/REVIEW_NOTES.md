# Maknoon: notes for App Review

Paste the relevant parts of this file into App Store Connect, your build,
"Notes for Review" (the App Review Information field). Fill in the three
bracketed links first (see "Before you submit" at the bottom).

## Responses to the previous review (Submission 85a9d169, Guideline 2.1)

**1. NFC demo video.** A demo video filmed on a physical iPhone, showing the NFC
functionality with the hardware in frame, is here:

  Demo video: `[PASTE THE NFC DEMO VIDEO LINK HERE]`

It shows, on a real device (not a simulator): the passport chip being read over
NFC ("Tap ID document"), a YubiKey being tapped and used to authorize signing
over NFC, and the full credential receive then present workflow.

Where NFC is used, and that it is optional:
- NFC is used for two things only: (a) reading an ID document chip when the user
  explicitly taps "Tap ID document," and (b) an optional YubiKey tap to authorize
  signing. Neither is required to use the app.
- On a device without NFC hardware (such as the iPad Air used for this review),
  these features are gated off. The "Tap ID document" control is not shown, and
  any NFC path returns a friendly message: "This phone doesn't support NFC
  reading. The Tap ID document feature needs an iPhone." (Source:
  `Maknoon/IDDocument/IDDocumentReader.swift`, runtime check
  `NFCTagReaderSession.readingAvailable`.)
- The core flows (receive a credential, present a credential, hold crypto) work
  fully without NFC on all devices, including iPad. See section 2.

**2. Full access without a hardware dependency.** The previous pickup link was
invalid because standard pickup links are single-use and expire. For review we
have provisioned a stable, reusable demo credential whose pickup link does not
expire and can be fetched repeatedly:

  Demo credential pickup URL: `[PASTE THE MULTI-USE musnad-issuer.elabify.com PICKUP URL HERE]`
  Demo verifier request page: `[PASTE THE musnad.elabify.com VERIFIER DEMO URL HERE]`

No account, username, or password is required (see "No account is required").
The step-by-step path to exercise the full feature set on the iPad is in
section "How to exercise the identity feature."

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
delete on our servers. "Reset Wallet" (Settings) wipes all local data. The
identity demo uses the reusable pickup link above, which also needs no account.

## How to exercise the identity feature (works on iPad, no NFC needed)

The wallet is fully testable on its own. The credential receive and present flow
needs a live issuer and verifier; this complete path works on the iPad Air used
for review, using the camera and a pasted URL (no NFC):

1. Launch the app and complete onboarding (it generates a 24-word recovery
   phrase locally; you can write down placeholder words for review).
2. Go to the **Identity** tab and tap **Receive credential**.
3. Tap **Paste a pickup URL**, paste the demo pickup URL above, and tap **Fetch
   credential**. (Alternatively, point the camera at the demo QR.) The credential
   appears in the Identity tab.
4. To present it: open the demo verifier page above on a second screen (laptop or
   another phone). It shows a verifier request QR.
5. Back in the app, on the **Identity** tab, scan the verifier's QR, review the
   requested fields, and approve. The verifier page shows a GRANT result.

The pickup link is reusable, so steps 2 and 3 can be repeated as many times as
needed during review.

## Permissions, and why each is requested

- **Face ID / passcode**: unlock the app and authorize signing. No biometric
  data leaves the device.
- **Camera**: scan issuer and verifier QR codes.
- **Bluetooth**: talk to a paired Ledger hardware wallet, and share a signed
  credential directly with another phone in the room. No server involved.
- **NFC (optional)**: read a YubiKey on tap, and optionally read an ID document
  chip when the user explicitly taps "Tap ID document." Not required to use the
  app; gated off on devices without NFC hardware (see review response 1).

## Data handling (matches our privacy nutrition labels and PRIVACY.md)

- The app sends no analytics, crash, or telemetry data anywhere.
- Identifying data (name, date of birth, nationality, and for passport-backed
  issuance the document number and chip facial image) leaves the device **only**
  when the user explicitly opts into passport-backed credential issuance or an
  opt-in sanctions check, and then only to the issuer host the user selects
  (default `musnad.elabify.com`). This is disclosed in `PRIVACY.md` sections 3 and 5.
- Lightning accounts are user-supplied third-party custodial accounts (LNDHub,
  the same format Zeus and BlueWallet use). Maknoon stores the user's own
  credentials locally and talks only to the server the user configured. Maknoon
  is not a money-transmission service.

## Contact

privacy@elabify.com / security@elabify.com

---

## Before you submit (action items for the Elabify team, not for Apple)

1. **Record + host the NFC demo video** on a physical iPhone: passport chip scan
   via "Tap ID document," a YubiKey tap authorizing a signature, and the full
   receive/present workflow, with the device and hardware visible in frame. Host
   it (unlisted is fine) and paste the link in review response 1. See
   `internal docs` for the shot list.
2. **Arm a reusable demo credential** so the pickup link survives repeated,
   async reviewer fetches:
   - Start the pilot issuer with `ELABIFY_REVIEW_PICKUP_ENABLED=true`.
   - Issue (or pick) one demo credential, note its `cid`, then arm a multi-use
     pickup:
     ```
     curl -X POST https://musnad-issuer.elabify.com/v1/admin/credentials/<cid>/regenerate-pickup \
       -H 'content-type: application/json' \
       -d '{"multiUse": true}'
     ```
     (with the operator's admin auth as configured). The response returns a
     `pickupUrl` with `multiUse: true`. Paste that URL into review response 2.
     This link is not consumed or expired on fetch, so it will be valid whenever
     the reviewer tests.
   - Paste the verifier demo URL from the `musnad.elabify.com` console.
3. In App Store Connect, App Privacy, set the nutrition labels to match
   `PRIVACY.md`: Contact Info (Name), Sensitive Info / government-ID, and
   Identifiers as **collected, not used for tracking**, tied to the opt-in
   identity flows. Everything else: not collected.
4. Confirm the app record is under the Elabify LLC **organization** account
   (required for a crypto wallet under Guideline 3.1.5(b)).
