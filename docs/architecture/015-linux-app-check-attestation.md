# ADR 015: Linux App Check attestation boundary

## Status

Accepted as a source foundation. Production Linux App Check remains disabled and
`LNX-APPCHECK-001` remains blocked until the production prerequisites and
installed-environment evidence in this record are complete.

## Context

Firebase App Check has platform-native providers for Apple, Android, and web,
but no built-in Linux desktop provider. Treating an authenticated Linux process,
a package signature, or a caller-supplied device claim as attestation would let
a copied credential mint a token from an untrusted host. Conversely, making
Linux equal to a hardware-backed Apple or Android principal would overstate the
assurance available across Linux package formats, firmware configurations,
containers, and virtual machines.

OpenBurnBar needs a fail-closed custom-provider boundary that can eventually
bind a short-lived Firebase App Check token to a fresh server challenge, the
signed application release, a device identity, and verified boot measurements.
The token must never cross into the Tauri renderer or persist on disk.

## Decision

Linux is a distinct, permanently lower-assurance principal:

- A dedicated, real Firebase **Web app ID** identifies Linux App Check traffic.
  The placeholder app ID is rejected whenever production minting is enabled.
- Successful Linux evidence receives only the `linux_lower_trust` trust class.
  App Check presence does not authorize high-risk operations by itself. Those
  operations still require a trusted-device step-up and a fresh, single-use
  high-risk nonce.
- Every callable is classified in the generated endpoint authorization catalog
  and enforced centrally before its handler runs. Linux is admitted to 29
  audited low-risk operations, two attestation/nonce prerequisites, and 14
  mutations that already require nonce consumption, trusted-device action
  proof, and mandatory audit persistence. The other 73 App Check-required
  callables reject Linux by default; unknown app IDs and missing catalog rows
  also fail closed.
- Standard browser trust is an exact-ID registry, not a `:web:` syntax
  inference. `APP_CHECK_STANDARD_WEB_APP_IDS` must contain the production
  website/console Firebase app ID and must remain disjoint from current and
  retired Linux/Windows IDs. Rotation or allow-list removal therefore cannot
  promote a desktop token into the standard Web trust class.
- Acquisition uses separate freshness and storage capabilities.
  `issueLinuxAppCheckChallenge` creates a cryptographically random, five-minute
  challenge. After the privileged broker returns the challenge-qualified quote
  and complete evidence-bundle digest, `issueLinuxAttestationUploadTicket`
  proves possession of the raw challenge and atomically creates one
  digest/size-bound ingress ticket. `mintLinuxAppCheckToken` consumes the
  challenge only after the generation-pinned upload receipt is appraised and
  accepts only a verifier decision with the exact challenge and identity
  binding. A separate `issueLinuxAttestationEnrollmentTicket` authorizes the
  pre-App-Check registrar bootstrap without reusing the quote challenge.
- Challenges live under
  `users/{uid}/linux_app_check_challenges/{challengeId}`. Firestore stores only
  the challenge SHA-256 hash, performs atomic single-use consumption, and keeps
  the consumed marker for 24 hours through TTL cleanup. Client access to these
  documents is denied by Firestore Rules.
- Ingress tickets live under
  `users/{uid}/linux_attestation_ingress_tickets/{ticketId}` and are also
  Admin-SDK-only. The client generates a canonical 32-byte secret and sends
  Functions only its domain-separated SHA-256 hash; Functions generates a
  separate canonical 16-byte ticket ID and returns only that ID plus expiry.
  The public ingress requires the combined `obbat1_<ticketId>.<secret>` header.
  Upload tickets bind UID, app, device, challenge hash, release, evidence digest
  and size, and a server-selected upload ID. Enrollment tickets bind UID,
  AK-derived device ID, and exact decoded AK/EK/certificate digests. Raw ticket
  secrets are never stored, logged, or placed in URLs.
- The daemon client bridge requires an explicitly configured, exact HTTPS
  ingress base URL; there is no production fallback endpoint. After the broker
  returns a sealed evidence descriptor, the daemon keeps the raw ticket secret
  in memory, sends only its domain-separated hash to the ticket callable, and
  uses the resulting `obbat1_<ticketId>.<secret>` capability only on the upload
  claim `POST`. The subsequent `PUT` carries the Firebase bearer token but not
  the ticket capability, streams one fresh view of the descriptor as
  `application/octet-stream`, and declares the exact bound `Content-Length`.
  The client refuses redirects, a changed final URL, malformed or non-exact
  responses, invalid endpoint configuration, and receipt fields that do not
  match the reservation, digest, and byte count. Task cancellation cancels the
  underlying request and closes the evidence descriptor.
- Evidence uploads are capped at 16 MiB because the ingress is a Cloud Run
  HTTP/1 service. Larger bundles require a future direct-to-GCS flow whose
  object size and digest are bound into the ticket before upload. The ingress
  transactionally charges one of three permitted PUT attempts before reading
  any body and then enforces the exact declared byte count. Successful receipt
  retries also consume an attempt, preventing an uploaded reservation from
  becoming an unbounded request-body sink.
- Enrollment activation is fenced by a separate Firestore lease. The ingress
  reconciles the exact Keylime agent ID, AK, EK, and certificate before and
  after activation, renews the fence before PUT, and retains it through an
  ambiguous mutation outcome. Concurrent callers, remote response loss, and
  local commit ambiguity therefore cannot activate or delete a different
  enrollment or issue a second proof while the first mutation may still run.
- Ticket creation and quota reservation share one Firestore transaction.
  Upload reservations enforce 6 per ten minutes and 72 per day per UID/device,
  216 per day per UID, and 2 GiB of declared evidence per day per UID.
  Enrollment reservations enforce 2 per hour and 5 per day per UID plus 3 per
  day per UID/device. An identical live retry returns the same ticket without a
  second charge; reservations are never refunded. Ticket, slot, and quota
  documents have TTL policies and direct client access is denied.
- The binding covers Firebase UID, Linux app ID, device ID, app version,
  architecture, release SHA-256 digest, policy ID, and attestation kind. A
  mismatch, expiry, replay, unknown kind, or unavailable verifier fails closed.
- Production evidence is delegated to an exact HTTPS verifier endpoint. The
  Functions boundary refuses redirects, limits request and response size,
  applies a sixty-second end-to-end authentication/request timeout, pins an Ed25519 public key and key ID, and checks
  the signed verdict's issuer, audience, decision, timestamps, challenge hash,
  receipt hash, trust class, and complete identity binding.
- Minted tokens have a server-selected, fixed 30-minute TTL and return
  `issuedAtMillis` plus `expireTimeMillis`, allowing the daemon to validate the
  lifetime against server issue time after a potentially slow TPM quote. The server records
  only a SHA-256 token hash and verifier receipt in a challenge-derived
  `users/{uid}/linux_app_check_sessions/{sessionHash}` document; it never stores the raw
  App Check token. Client access to session documents is denied.
- The Linux daemon source implements the challenge, broker-evidence,
  hash-only upload-ticket, claim, streamed upload, and receipt-native mint
  bridge. Mint evidence contains the broker quote, the descriptor metadata, and
  only the generation-pinned upload receipt; it does not inline or persist the
  evidence bundle. The daemon bounds requests and responses, coalesces
  concurrent acquisition, binds cached state to the account UID and session
  generation, refreshes before expiry, and keeps the ticket secret, Firebase ID
  token, App Check token, quote, descriptor, and upload receipt out of durable
  state. Account changes invalidate acquisition and cached state. The renderer
  may receive redacted availability and expiry status, never token material.
  The broker now loads private root-owned enrollment state, validates the
  private `ak.ctx` quote context, invokes `/usr/bin/tpm2_quote` with the
  broker-derived qualifying data, and returns a sealed descriptor containing
  IMA measurements, measured-boot log, installed manifest, and manifest
  signature. The production factory composes this bridge, but production
  remains blocked until real TPM enrollment, verifier deployment, revocation,
  and installed-candidate matrix evidence exist.
- `LINUX_APP_CHECK_MINT_ENABLED` defaults to false. Mock attestation remains
  limited to existing test/emulator policy and is forced off in production.

The production evidence producer is a separate privileged component. A first
broker foundation now ships in source for native deb/rpm packages:

- `openburnbar-attestd.socket` owns `/run/openburnbar/attestd.sock` when the
  attestation rollout is eligible. Fresh installs keep the socket disabled and
  stopped; package hooks activate it only when private root-owned TPM enrollment
  state, the private root-owned `ak.ctx` quote context, and the explicit
  root-owned rollout marker all pass. The root service is network denied and
  systemd sandboxed without hiding the peer PID information needed for
  authorization.
- Each complete bounded `SOCK_SEQPACKET` request carries kernel-supplied
  `SCM_CREDENTIALS`; the broker never trusts connection-time identity. It pins
  `/proc/<sender-pid>/exe`, requires the exact root-owned daemon inode, and
  verifies its SHA-256 digest against a release-signed installed manifest whose
  canonical file root is recomputed. The protocol is versioned, length prefixed,
  bounded to 64 KiB, deadline limited, rate limited, one request per connection,
  and served through a bounded worker queue.
- Native package assembly generates a canonical complete installed-file
  inventory, signs it with the pinned Linux release Ed25519 key, and installs
  the manifest, detached signature, public key, broker, activation gate,
  active-user daemon upgrade recovery helper, and lifecycle units. Upgrades
  reload and `try-restart` only daemon services that were already active.
  The inventory root sorts each NUL-delimited record by unsigned UTF-8 bytes
  before joining records with LF and hashing the result with SHA-256; packager
  and broker share a cross-language golden vector for this exact encoding. A
  canonical preparation root covers every generated binary, runtime tree,
  package asset, and lifecycle script. The isolated signer remeasures that root
  before and after native package construction, verifies the final extracted
  RPM payload, and signs a receipt binding the preparation digest to the exact
  deb/rpm hashes. Finalization remeasures and verifies the receipt before it can
  emit a zero-blocker architecture shard.
  AppImage, Flatpak, AUR, source builds, containers, and WSL do not receive the
  privileged broker.
- The broker backend reads `/var/lib/openburnbar-attestd/tpm-enrollment.json`
  only when it is a non-symlink, root-owned, root-group, single-link regular
  file with mode `0400` or `0600`. The exact JSON state is
  `schemaVersion`, `deviceId`, `agentId`, `akTpmBase64`, `ekTpmBase64`,
  `ekCertificateBase64`, and `enrolledAtMillis`; the broker recomputes
  `ak-sha256:<sha256(decoded akTpmBase64)>` before returning a binding. The
  attest operation requires `/var/lib/openburnbar-attestd/ak.ctx`, runs
  `tpm2_quote -Q -c ak.ctx -l sha256:0,2,4,7,10 -q <qualifying-data> -m ... -s ... -f tss -F serialized -g sha256 -o ...`,
  collects quote artifacts through anonymous memfds, and returns one sealed
  evidence descriptor. It has no mock or software fallback; unsupported or
  incomplete hosts fail closed before upload or mint.

Executable hashing is not yet sufficient production client authentication.
`SCM_CREDENTIALS` fixes the sender PID for a packet, but a process can queue a
packet and then `exec` the signed daemon before `/proc/<pid>/exe` is inspected;
same-user loader or process injection also cannot be excluded by an inode hash.
This remains contained by the default-disabled socket and explicit rollout
marker, but it is a High production-activation blocker. A production rollout
must first add root-controlled daemon launch provenance in a
non-user-overridable cgroup, sanitized loader state and disabled dumpability,
pidfd/cgroup/executable revalidation, and a broker-issued per-connection nonce
before accepting the second request packet. The verifier policy must also cover
executable and mmap measurements. Activation tests must reject queue-then-exec,
PID reuse,
`LD_PRELOAD`, ptrace/injection, cgroup escape, and inherited-descriptor attempts.
Connection admission must also move ahead of the bounded worker queue or apply
an equivalent credential-aware cap so unauthenticated idle local connections
cannot exhaust all broker workers before per-UID request limiting runs.

The next implementation stage adds broker-managed TPM 2.0 attestation-key
creation/rotation, Keylime enrollment-state installation and activation,
package/release verification, hardened launch provenance, hardware quote
vectors, and verifier-side UEFI measured-boot plus IMA PCR 10 policy
evaluation. A remote verifier must evaluate that evidence and return the signed
decision consumed by Functions. Complete logs must use the digest-bound ingress
receipt and stay within the current 16 MiB upload contract; logs must never be
truncated. A larger limit requires a separately designed direct-to-object-storage
protocol.

## Supported Environments

No environment is production-supported yet. Promotion requires the exact signed
candidate and the following minimum evidence:

| Environment | Intended production posture | Current status |
|---|---|---|
| Physical TPM 2.0, Secure Boot and measured boot enabled, supported deb/rpm repository install | Eligible after broker enrollment, package/release verification, quote and IMA policy pass | Blocked |
| Physical TPM 2.0 with AppImage install | Local product only; AppImage cannot own the privileged broker lifecycle under the current policy | Unsupported |
| Generic VM or vTPM | Local product remains usable; protected cloud mutations unavailable unless a separately approved VM trust policy is introduced | Unsupported |
| No TPM, disabled Secure Boot, source build, container, WSL, Flatpak, or Snap | Local product remains usable; no production App Check minting | Unsupported |
| Emulator/test fixture with the explicit mock policy | Automated verification only; never production evidence | Test only |

Unsupported hosts must report App Check unavailable before a protected cloud
action. They must not silently fall back to mock evidence, a device-auth token,
or an unverified software assertion.

## Consequences

This design provides cross-instance replay resistance, exact release and policy
binding, verifier key pinning, bounded failure behavior, and a daemon-only token
boundary. The Functions and daemon source can be reviewed and tested before the
privileged Linux broker is introduced.

It does not establish production host integrity. The broker transport,
release-signed installed manifest, native package lifecycle, and local
enrollment-state binding, TPM quote collector, and sealed evidence descriptor
are implemented, but a real Firebase Web app ID, broker-managed hardware
enrollment, verifier deployment, revocation behavior, physical TPM/IMA vectors,
and installed matrix proof are still required.
Until those exist, protected cloud operations remain unavailable and Linux stays
`linux_lower_trust`.

## Rollout And Rollback

1. Provision a dedicated Firebase Web app ID and add only that ID to the App
   Check allow-list.
2. Deploy the verifier with its signing key held outside the Functions runtime;
   configure the pinned public key, identity fields, endpoint, and policy ID.
3. Deploy Functions with `LINUX_APP_CHECK_MINT_ENABLED=false` and verify that
   production challenge and mint calls fail closed while local workflows work.
4. Enroll a limited broker test ring and capture verifier, replay, revocation,
   clock-skew, package, and desktop-environment evidence.
5. Enable minting for the ring, then advance only after the installed matrix and
   endpoint decision logs meet the acceptance criteria below.

Rollback sets `LINUX_APP_CHECK_MINT_ENABLED=false` and removes the Linux app ID
from the allow-list. Classified Functions callables deny the ID immediately.
Direct owner-scoped Firestore/Storage rules cannot classify the app ID and may
continue accepting an already minted token until its fixed 30-minute TTL
expires. Production readiness must inventory and explicitly accept that bounded
surface or route the affected Linux cloud operations through classified
callables. Local SQLite, local account sign-out, and other local product data
remain available. Rotate the verifier key or policy ID to revoke future minting;
do not extend token TTL or enable mock verification as an outage workaround.

## Verification

Source acceptance requires:

- unauthenticated, malformed, expired, replayed, wrong-user, wrong-app,
  wrong-version, wrong-release, wrong-policy, wrong-kind, bad-signature, denied,
  and unavailable-verifier cases to fail with the expected typed result;
- atomic replay rejection across independent Functions instances;
- a valid signed verdict to mint exactly one 30-minute token;
- Firestore Rules to deny challenge/session/ticket/slot/quota document access
  and TTL policy to cover every ephemeral collection;
- concurrent quota-boundary tests with one winner, exact ticket retry without a
  second charge, wrong-secret/purpose/UID/binding/expiry rejection, and proof
  that neither raw challenge nor raw ticket secret is persisted or logged;
- three-attempt upload-body enforcement before body consumption, exact-length
  streaming, stale-ticket recovery for only the same TPM identity, activation
  lease fencing, and Keylime/Firestore response-loss reconciliation;
- daemon tests for concurrent acquisition, refresh, expiry, network failure,
  account switch, session-generation switch, redirect refusal, endpoint
  validation, response bounds, and memory-only token handling;
- renderer/RPC/log/support-bundle scans to contain no App Check token, raw
  challenge evidence, verifier response, or credential-shaped material.

Production acceptance additionally requires the hardened two-packet broker
authentication and launch-containment tests above, broker and verifier
deployment, hardware-root enrollment and revocation, TPM quote and IMA-log test
vectors, signed-candidate release binding, offline and clock-skew behavior, and
installed GNOME/KDE/headless runs for each supported architecture and package
path. The audit remains NO-GO until that evidence is bound to one release head.
