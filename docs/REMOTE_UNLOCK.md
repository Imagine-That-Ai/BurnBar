# Mercury Remote Unlock

Remote Unlock is the human-only lane for unlocking a paired Mac from iPhone,
iPad, or Android while the Mac is locked. It is intentionally separate from
Computer Use: agents still halt at lock, `loginwindow`, `SecurityAgent`, screen
sleep, and deny regions.

## Strategy

OpenBurnBar does not assume that a normal user-session ScreenCaptureKit stream
can capture or control the macOS login window. A Mac is Remote Unlock capable
only after a local certification flow proves the exact machine can:

- keep a locked-screen visual backend available;
- accept input at the locked/auth surface;
- enter a credential without exposing the password to logs, audit records,
  Firestore, analytics, or agent surfaces;
- unlock and reconnect the Mercury mirror afterward;
- keep Apple Screen Sharing/VNC access loopback-only with a firewall guard.

The durable backend order is:

1. Apple Screen Sharing / Remote Management loopback bridge for lock/loginwindow.
2. Persistent ScreenCaptureKit only when provisioned and live-certified.
3. Normal ScreenCaptureKit after the user session is unlocked.
4. FileVault preboot via Apple-supported SSH unlock where available; this is not
   a screen-mirroring state.

## Wire Contract

Remote Unlock frames ride the existing Mercury control stream:

- `remote_unlock.session`
- `remote_unlock.state`
- `remote_unlock.input`
- `remote_unlock.credential`
- `remote_unlock.result`
- `remote_unlock.denied`

The Mac also attaches `remoteUnlockCapabilities` and `remoteUnlockState` to
mirror acks and presence heartbeats. Unsupported peers ignore these fields.

Credential payloads use a sealed credential envelope:

- no plaintext password field exists in the wire model;
- `redactedByteCount` is the only observable credential size hint;
- the required algorithm token is `HPKE-X25519-SHA256-CHACHAPOLY`;
- certified Macs advertise `credentialRecipientKeyId`,
  `credentialRecipientPublicKeyBase64`, and `credentialEnvelopeAlgorithm` in
  `remoteUnlockCapabilities`; mobile clients must refuse password entry when
  any of these fields are absent;
- every credential carries the existing Ed25519 authority envelope, monotonic
  counter, freshness window, session ID, and client intent ID.

## Readiness

The Mac readiness policy fails closed until all certification probes pass:

- direct-download build, not MAS;
- remote-access daemon installed;
- Apple Screen Sharing / Remote Management available;
- loopback firewall guard active;
- generated VNC credential stored in System Keychain;
- HPKE recipient key ID and public key available from the daemon;
- backend certification fresh for the current OS build;
- lock-screen capture, credential input, and unlock probes succeeded.

OS updates, Screen Sharing changes, firewall drift, daemon reinstall, credential
rotation, or failed probes invalidate certification.

Certification is stored as a structured local proof at:

`~/Library/Application Support/OpenBurnBar/RemoteUnlockCertification-v1.json`

The report is machine-bound by macOS build string, HPKE recipient key ID, HPKE
recipient public key, backend, expiry, and three successful hardware probes. The
Mac readiness service ignores stale `UserDefaults` booleans; a valid report is
the durable source of truth for advertising `remote_unlock.host`.

## Hardware Certification

Run the hardware smoke on the Mac that will be unlocked:

```bash
OPENBURNBAR_REMOTE_UNLOCK_VIEWER_KIND=ipad ./scripts/e2e/remote-unlock-hardware-smoke.sh
```

Use `ios`, `ipad`, or `android` for `OPENBURNBAR_REMOTE_UNLOCK_VIEWER_KIND`.
The script:

- verifies Apple Screen Sharing / Remote Management is available;
- verifies the direct-download remote-access LaunchDaemon exists;
- reads the Mac's published HPKE recipient key ID and public key;
- locks the Mac with `CGSession -suspend`;
- waits for the operator to complete unlock from the phone/tablet Remote Unlock
  overlay;
- records a certification report only after the operator types the exact
  confirmation phrase.

The script never asks for, logs, stores, or transmits the Mac password. If the
operator unlocks manually, with Touch ID, Apple Watch, or any non-OpenBurnBar
tool, the certification must not be recorded.

## Current Implementation State

This change lands the permanent contract and fail-closed runtime seams:

- shared Swift/Kotlin relay models;
- Mac readiness policy and advertised capabilities;
- MercuryRouter remote-unlock admission and lock-gate bypass only for certified
  human unlock sessions;
- mobile locked-state overlay that pauses normal Mac control while the
  privileged credential lane is unavailable;
- certification proof store plus `openburnbar-cli remote-unlock-certification`
  status/reset/record tooling;
- hardware smoke script for iOS, iPadOS, and Android certification;
- tests for policy, certification report validation, Swift relay round-trip, and
  Android relay round-trip.

The direct-download remote-access daemon still owns the privileged bridge work:
Screen Sharing loopback management, PF anchor installation, System Keychain
credential rotation, and HPKE private-key custody. Until the daemon publishes
key material and the hardware smoke records a fresh certification report, Remote
Unlock remains disabled by policy and the mobile apps must not present password
entry as an available action.
