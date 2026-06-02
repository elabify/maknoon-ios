# Security Policy

Maknoon is a self-custodial wallet. We take security reports seriously and appreciate
responsible disclosure.

## Reporting a vulnerability

Please report security vulnerabilities **privately**, not as a public issue or pull
request:

- Open the **Security** tab of this repository and click **Report a vulnerability** to
  start a private advisory (GitHub private vulnerability reporting).

Please include the affected version, a clear description, reproduction steps, and the
impact. **Never include a real recovery phrase, passphrase, or private key.**

We aim to acknowledge reports within a few business days. Please give us reasonable time
to investigate and ship a fix before any public disclosure.

## Scope

The on-device iOS app and its native cryptographic cores are in scope, including the
shared `elabify-core` crypto core and the Ledger device crates.

## Safe by design

Maknoon performs no analytics and no telemetry. Recovery phrases, passphrases, and
private keys are generated and held in the Secure Enclave / Keychain and never leave the
device.
