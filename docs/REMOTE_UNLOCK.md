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

Locked mirror admission is intentionally two-phase:

1. The phone/tablet requests a normal `media.mirror.request`.
2. If the Mac is locked and Remote Unlock is runtime-ready, the Mac returns an
   unsupported mirror ack with `detail=remote_unlock_session_required`,
   `remoteUnlockState`, and `remoteUnlockCapabilities`.
3. The mobile client ensures the device is trusted once, permanently, in the
   user's device trust registry. If the phone/tablet is already trusted, no
   Mac-side physical permission prompt is shown again. If it is not trusted, the
   client performs local device authentication once, marks the device trusted,
   publishes the phone-control authority key, signs a `remoteUnlockSession`, and
   retries the mirror request.
4. The Mac validates the signed session and auto-accepts the locked mirror
   without showing a prompt on the locked Mac. This acceptance is not allowed
   to wait for normal ScreenCaptureKit startup: while locked, the secure Remote
   Unlock surface opens first, and normal screen capture starts only after the
   Mac reports the user session is unlocked.
5. The password field sends `remote_unlock.credential`, HPKE-sealed to the Mac's
   advertised recipient key and signed by the same trusted phone-control key.
6. The Mac validates signature freshness, counter monotonicity, active session
   binding, recipient key id, credential TTL, and lock-state readiness before it
   sends the credential through the local Apple Screen Sharing / ARD loopback
   keyboard lane. If that system lane is unavailable, the direct-download
   remote-access agent remains a local fallback.

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
- Remote Unlock permission is durable: approving/trusting an iPhone, iPad, or
  Android for locked mirroring is a one-time grant and survives app restarts.
  Revocation is explicit from the device trust surface. This trust grant is
  separate from password handling. By default, the user types the Mac password
  for each unlock attempt; the typed password is held only in volatile UI state,
  cleared when submitted/unlocked, HPKE-sealed to the Mac recipient key, signed,
  and sent over `remote_unlock.credential`.
- One-tap Remote Unlock is optional and device-local. When the Mac advertises
  `remoteUnlockCapabilities.allowsSavedCredentialUnlock`, iOS, iPadOS, and
  Android can store the Mac password in the local secure credential store
  (Keychain on Apple platforms, AndroidKeyStore-wrapped storage on Android).
  Saving and each one-tap send require local device authentication. The Mac
  still never stores the user's login password, and the relay still only sees a
  sealed `remote_unlock.credential` envelope with `credentialKind=saved_password`.
  The saved credential is keyed to the Mac's stable `credentialRecipientKeyId`
  when advertised, so it survives Mercury connection ID rotation while still
  following recipient-key rotation. It can be deleted from the mirror overlay on
  each device.

## Readiness

The Mac readiness policy fails closed until all certification probes pass:

- direct-download build, not MAS;
- remote-access daemon installed;
- Apple Screen Sharing / Remote Management available and listening on
  `127.0.0.1:5900`;
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
- locked Remote Unlock mirrors are accepted before normal ScreenCaptureKit
  starts, avoiding "Opening mirror" deadlocks when macOS blocks capture at
  `loginwindow`; after the credential succeeds, the router starts normal
  capture and broadcasts a resumed mirror ack;
- mobile mirror requests are not gated behind a heartbeat preflight at
  `loginwindow`; control-stream writes are bounded by send timeouts, stale
  streams are closed, and the mirror request is retried once after a fresh
  control-stream dial;
- mobile clients treat a live Mercury control stream as the authoritative
  mirror-ready signal. Firestore/presence heartbeat freshness is status only:
  it cannot disable the Mirror button, jump ahead of a user mirror request, or
  interrupt Remote Unlock password entry;
- Remote Unlock credential submission uses the dedicated signed
  `remote_unlock.credential` lane directly. It does not run normal phone-control
  probe/classify traffic first, so a stale presence heartbeat cannot stall or
  reset the password flow;
- locked credential entry now uses Apple Screen Sharing / ARD security type 30
  over `127.0.0.1:5900` before falling back to the local helper. This is the
  same system-level lane that can see and control `loginwindow`, unlike normal
  user-session ScreenCaptureKit/CGEvent input;
- iPhone, iPad, and Android support both typed-per-unlock submission and
  optional one-tap saved credential submission, guarded by local device
  authentication and encoded on the wire as `credentialKind=saved_password`;
- certification proof store plus `openburnbar-cli remote-unlock-certification`
  status/reset/record tooling;
- hardware smoke script for iOS, iPadOS, and Android certification;
- tests for policy, certification report validation, Swift relay round-trip, and
  Android relay round-trip.

Apple Screen Sharing owns the primary privileged locked-screen credential-entry
bridge. The direct-download remote-access daemon remains installed as a local
health/wake/fallback lane. Runtime readiness and certification are deliberately
separate:

- Runtime ready: direct-download Mac app, healthy local remote-access agent,
  a live Apple Screen Sharing / Remote Management listener on `127.0.0.1:5900`,
  and HPKE recipient key material. Mobile apps may present password entry in
  this state.
- Certified: a real locked-screen round trip has succeeded on this hardware and
  the Mac recorded a fresh `RemoteUnlockCertification-v1.json` proof. Future
  sessions advertise `certified`; stale or missing proof does not deadlock the
  first hardware proof attempt.

Wire compatibility note: current mobile clients show the password field when
`remoteUnlockCapabilities.allowsCredentialPaste` is true. A `certified` status
still means a durable hardware proof exists; runtime-ready-but-not-yet-certified
Macs may accept the first real locked unlock and record certification afterward.

## Locked-Screen Input Backends

OpenBurnBar prefers Apple Screen Sharing / Remote Management on loopback for
locked-screen input. The Mac app authenticates locally to the system RFB service
with ARD security type 30, wakes/reveals the selected login password lane with
non-printing input, types the validated credential, and submits it. This avoids
the brittle failure mode where a user-session CGEvent helper wakes the lock
screen but loginwindow ignores the password keystrokes.

The product direction for account picker support is the same backend: relay the
system RFB framebuffer and pointer/keyboard events while locked, then switch
back to normal ScreenCaptureKit after unlock. That is the path that lets a
viewer choose a different account at loginwindow; normal ScreenCaptureKit cannot
capture outside the logged-in user session.

## Local Direct-Download Agent

Install or repair the local privileged credential-entry agent with:

```bash
./scripts/install-remote-access-agent.sh
```

Keep the direct-download Mac app running as the Mercury relay host. The
Settings → Appearance → Launch at Login toggle registers the app with macOS
login items; the fallback privileged helper can type credentials only after the
Mac app has received and validated a Remote Unlock request from the
phone/tablet.

The installer builds `OpenBurnBarRemoteAccessAgent`, installs it as
`/Library/Application Support/OpenBurnBar/RemoteAccess/openburnbar-remote-access-agent`,
and bootstraps `/Library/LaunchDaemons/com.openburnbar.remote-access-agent.plist`.
The agent exposes only a local Unix socket at
`/var/run/openburnbar-remote-access-agent.sock`; the socket is owned by the
active console user with mode `0600`, and the daemon verifies the Unix peer UID
before handling a request. It accepts health checks and the single
`typeCredential` operation used after the Mac app has already decrypted and
validated a human Remote Unlock credential. Before typing, the agent explicitly
declares remote user activity, holds a short no-display-sleep assertion, and
waits for loginwindow to redraw when the display was asleep so the first
credential key press is not consumed merely waking the display. The worker does
not press Return before typing: on the real lock screen Return submits the
currently focused password field, so a pre-submit focus probe can send an empty
password first and make the login window flicker before the real credential
arrives. Touch ID-first lock screens may also hide the password input behind a
"Touch ID or type password" prompt, so the worker first clicks the selected
login/password area and sends a safe backspace/space/backspace reveal sequence;
that sequence opens the password lane without submitting an empty credential.
The credential worker uses the session-scoped CoreGraphics event source and
session event tap inside the loginwindow bootstrap; macOS 26.5 can deadlock
before posting a key when the worker uses the HID-system event source from that
bootstrap, and the locked login window ignores root-owned keystroke workers even
when the local helper request itself succeeds. The root LaunchDaemon writes the
credential into a short-lived `0600` file under `/var/run`, passes only that
random path to the worker, and deletes the file from both the daemon and worker
sides so credential delivery does not depend on `launchctl` stdin inheritance.
It enters the loginwindow bootstrap with `launchctl bsexec`, then the worker
explicitly drops to the logged-in console uid/gid before posting password
events. The launch is performed with `posix_spawn` and a hard `waitpid` timeout;
Foundation `Process` can leave the daemon-side request waiting even though
direct probes complete. The agent also ignores `SIGPIPE`, bounds
per-client socket I/O, and handles clients on separate threads so stale or
abandoned requests cannot make the helper appear unreachable. The agent does
not log the credential.

Verify the installed agent with:

```bash
./scripts/verify-remote-access-agent.sh
```

After install, run the hardware certification smoke above or perform one real
locked Remote Unlock from a trusted phone/tablet. The LaunchDaemon alone is not
certification: it makes the privileged locked-screen input lane available; the
first successful locked unlock records the human hardware proof.

## Troubleshooting

- `signature_failure` on the phone means the Mac rejected the Ed25519 authority
  envelope before it would type the credential. Both the Mac app and the phone
  app must be built from the same canonical signing contract. Remote Unlock
  session and credential signatures must hash relay dates exactly as the relay
  encodes them: ISO-8601 strings with fractional seconds. Do not hash raw
  `Date` values in Remote Unlock canonical payloads.
- `session_mismatch` means the password credential did not match an active
  Remote Unlock mirror session accepted by the Mac. Restart the mirror after
  updating the Mac app; the Mac records the Remote Unlock session only when it
  accepts the locked-screen mirror request, binds it to the phone peer, and
  revokes it on expiry or viewer disconnect.
- `Mac isn't sending frames` means the Mercury control stream is alive but the
  video backend has not produced frames. Fix the mirror backend separately; it
  does not by itself mean credential validation failed.
