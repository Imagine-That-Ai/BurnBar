# Linux Cloud Security Runbook

This runbook defines the Linux lower-trust cloud posture and the source-level
App Check boundary. It does not certify production Linux attestation. Production
minting is disabled by default, and protected Linux cloud operations remain
blocked until the verifier, privileged broker, release policy, deployment, and
installed matrix described below are complete.

## Principal And Trust Class

- Linux desktop uses a dedicated, real Firebase Web app ID configured through
  `LINUX_APP_CHECK_APP_ID`. The checked-in placeholder is for tests and disabled
  environments; production minting rejects it.
- The backend classifies the Linux app ID as `linux_lower_trust`; it is not an
  Apple App Attest, Android Play Integrity, or web reCAPTCHA principal.
- Standard browser trust is reserved for exact IDs in
  `APP_CHECK_STANDARD_WEB_APP_IDS`. Never add a current or retired desktop ID to
  that registry; a generic Firebase Web ID is unknown by default.
- Low-risk read/sync callables must use an explicit trust-class allow-list.
- High-risk actions must not pass from Linux App Check presence alone. They must
  consume a fresh `issueHighRiskActionNonce` nonce and route through a
  trusted-device step-up proof such as `enforceHighRiskOwnerAction`.

## App Check Protocol

The source foundation uses four authenticated bootstrap callables:

1. `issueLinuxAppCheckChallenge` binds Firebase UID, app ID, device ID, app
   version, architecture, release SHA-256 digest, policy ID, and attestation
   kind to a random five-minute challenge.
2. `issueLinuxAttestationUploadTicket` runs after the broker has produced the
   challenge-qualified quote and evidence bundle. It proves possession of the
   raw challenge, binds the exact bundle SHA-256 and byte count, atomically
   charges count/byte quotas, and returns one random ingress ticket ID. Only the
   client-generated ticket secret's domain-separated hash is stored.
3. `issueLinuxAttestationEnrollmentTicket` binds a registrar bootstrap to the
   UID, AK-derived device ID, and decoded AK/EK/EK-certificate digests. It has a
   separate quota and never reuses a quote challenge.
4. `mintLinuxAppCheckToken` atomically consumes that challenge, obtains a signed
   verdict from the configured verifier, validates the full binding, and mints
   one server-selected 30-minute Firebase App Check token.

The raw challenge is returned once. Firestore stores only its SHA-256 hash under
`users/{uid}/linux_app_check_challenges/{challengeId}` and retains the consumed
replay marker for 24 hours through TTL cleanup. The server stores only the
minted token's SHA-256 hash and verifier receipt under a challenge-derived
`users/{uid}/linux_app_check_sessions/{sessionHash}` document. Firestore Rules deny client
access to both collections. Ticket documents live under
`users/{uid}/linux_attestation_ingress_tickets/{ticketId}`. Functions stores
only the domain-separated SHA-256 of the client-generated 32-byte ticket secret
and returns only the server-generated 16-byte ticket ID plus expiry. The daemon
constructs `obbat1_<ticketId>.<secret>` only for the public ingress header; it
must never put that value in a URL, log, renderer message, crash report, or
support bundle.

The daemon client bridge uses this exact sequence:

1. Receive the broker quote and sealed evidence descriptor, reject an empty or
   larger-than-16-MiB bundle, generate the ticket secret in memory, and send only
   the secret hash plus the exact digest and size to
   `issueLinuxAttestationUploadTicket`.
2. `POST` the exact upload declaration to
   `<ingress>/v1/evidence-uploads` with the Firebase ID token and
   `X-OpenBurnBar-Attestation-Ticket: obbat1_<ticketId>.<secret>`. The ticket
   capability is scoped to this claim request and is not sent on the body
   upload.
3. `PUT` one fresh stream of the evidence descriptor to
   `<ingress>/v1/evidence-uploads/<uploadId>` with the Firebase ID token,
   `Content-Type: application/octet-stream`, and the exact bound
   `Content-Length`. The client accepts only the expected final URL, status, and
   exact receipt shape, and checks the upload ID, generation, digest, and size.
4. Send `mintLinuxAppCheckToken` receipt-native evidence containing the quote,
   descriptor metadata, and generation-pinned upload receipt. The mint request
   does not inline the evidence bundle.

`OPENBURNBAR_LINUX_ATTESTATION_INGRESS_ENDPOINT` is required for this bridge and
has no default. Missing, whitespace-padded, non-HTTPS, credential-bearing,
query-bearing, or fragment-bearing ingress configuration fails closed before a
request. The callable clients also reject invalid explicit endpoint overrides.
All sessions are ephemeral and refuse redirects; cancellation propagates to the
underlying URL task. The daemon must not persist or expose the raw ticket
secret, Firebase ID token, App Check token, quote, evidence bytes, descriptor,
or receipt through disk state, logs, renderer/RPC payloads, crash reports, or
support bundles.

Upload ticket issuance and quota reservation are one Firestore transaction and
one challenge can authorize only one ticket. Limits are 6 per ten minutes and
72 per day per UID/device, 216 per day per UID, and 2 GiB of declared evidence
per day per UID. Enrollment limits are 2 per hour and 5 per day per UID plus 3
per day per UID/device. Identical live retries return the same ticket without a
second charge. Reservations are never refunded, all quota failures are closed,
and ticket/slot/quota documents are server-only with TTL cleanup.

The callable and ingress both cap evidence at 16 MiB, the Cloud Run HTTP/1
request-body limit. Supporting larger bundles requires a future direct-to-GCS
upload path with the object digest and size bound into the ticket. Ingress
charges one of three upload attempts in a Firestore transaction before reading
each body, requires the exact declared length, and counts malformed bodies plus
successful receipt retries. The root `linux_attestation_uploads` collection is
client-denied and has a five-minute `expireAt` TTL policy.

Enrollment completion claims a fenced activation lease, checks Keylime for an
already-active exact agent/AK/EK/certificate identity, activates only when the
agent is absent, renews the fence immediately before PUT, and checks the same
identity again before local commit. Ambiguous mutation failures retain the
fence until expiry. A retry can therefore reconcile Keylime or Firestore
response loss without an overlapping remote mutation; stale lease holders
cannot activate, release, or terminalize a reclaimed enrollment.

The remote verifier call is exact HTTPS with redirects refused, a sixty-second
end-to-end authentication/request timeout, bounded evidence and response bodies,
and a pinned Ed25519 public key. The verifier lease must exceed that budget so a
lost response can be recovered from the identical cached result.
The signed verdict must match the configured key ID, issuer, audience, policy,
challenge hash, UID, app, device, version, architecture, release digest,
attestation kind, timestamps, and `linux_lower_trust` class.

The Linux daemon owns the network and cache boundary. It bounds encoded requests
and streamed responses, coalesces concurrent acquisition, validates the server
app ID, trust class, and fixed lifetime from server issue time, refreshes before
expiry, binds cached state to the Firebase UID plus session generation, and
keeps the raw App Check token in memory only. The renderer receives at most a
redacted unavailable/acquiring/ready status and expiry.

The source now includes a root-owned `openburnbar-attestd` transport for native
deb/rpm packages. Each complete `SOCK_SEQPACKET` request carries
kernel-supplied `SCM_CREDENTIALS`; the broker pins that sender's
`/proc/<pid>/exe` inode and verifies its digest against a release-signed complete
installed-file manifest before accepting the bounded request. Package install,
upgrade, normal removal, explicit state purge, and active user-daemon upgrade
recovery own the lifecycle. Fresh installs keep the root socket disabled and
stopped; activation requires private root-owned enrollment state plus an exact
root-owned rollout marker. The broker now parses that private state, verifies
the AK-bound `ak-sha256:*` device ID, and returns the installed release/device
binding only when the state file is root-owned, root-group, non-symlinked, and
mode `0400` or `0600`. AppImage and sandboxed/source channels do not install the
broker. The installed-files root uses unsigned UTF-8 byte ordering for its
NUL-delimited records, covered by one shared JS/Rust golden vector. Release
preparation measures every native signer input; the isolated signer remeasures
before and after packaging and emits a signed receipt over the exact deb/rpm
hashes; finalization verifies that receipt and current inputs. RPM construction
also extracts the final artifact and checks every signed payload record, which
prevents rpmbuild post-processing from invalidating daemon authorization. The
current backend still returns `attestation_unsupported` for quote collection, so
this does not produce trustworthy platform evidence. The source-level client
bridge does not change that posture: broker TPM/IMA production evidence
collection remains unsupported, the composed production path fails closed at the
broker before upload or mint, and no installed or production parity is claimed.

Production still requires TPM 2.0 key enrollment and nonce-qualified quotes,
UEFI measured-boot policy, IMA PCR 10 and full measurement-log verification,
revocation, and the deployed remote verifier. Complete IMA logs must use the
digest-bound ingress receipt and stay within the current 16 MiB upload contract;
they must never be truncated. A larger limit requires a separately designed
direct-to-object-storage protocol. See
[`ADR 015`](../architecture/015-linux-app-check-attestation.md).

## Configuration

Functions production configuration:

| Variable | Required production value |
|---|---|
| `LINUX_APP_CHECK_MINT_ENABLED` | `true` only after the production readiness gate passes; defaults to false |
| `LINUX_APP_CHECK_APP_ID` | Dedicated real Firebase Web app ID (`1:<project>:web:<id>`) |
| `APP_CHECK_ALLOWED_APP_IDS` | Includes that exact Linux app ID and no placeholder |
| `APP_CHECK_STANDARD_WEB_APP_IDS` | Exact production website/console Firebase Web app IDs only; disjoint from every current or retired desktop ID |
| `LINUX_APP_CHECK_POLICY_ID` | Versioned attestation policy; default source value is `openburnbar-linux-tpm2-ima-v1` |
| `LINUX_APP_CHECK_VERIFIER_URL` | Exact HTTPS remote verifier endpoint |
| `LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE` | Exact verifier HTTPS origin (for example `https://verifier-abc-uc.a.run.app`); distinct from the signed-verdict audience |
| `LINUX_APP_CHECK_VERIFIER_PUBLIC_KEY_BASE64` | DER/SPKI Ed25519 public key, base64 encoded |
| `LINUX_APP_CHECK_VERIFIER_KEY_ID` | Exact active verifier signing-key ID |
| `LINUX_APP_CHECK_VERIFIER_ISSUER` | Exact signed-verdict issuer |
| `LINUX_APP_CHECK_VERIFIER_AUDIENCE` | Exact signed-verdict audience |
| `ENFORCE_APP_CHECK` | `true` in production |
| `REQUIRE_HIGH_RISK_NONCE` | `true` in production |
| `ALLOW_MOCK_APP_CHECK_ATTESTATION` | Must remain false; production config forces it off |

The Functions runtime service account must have `roles/run.invoker` on the
private verifier service. Functions obtains a Google-signed ID token for
`LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE`; configuration fails closed unless that
audience is the exact origin of `LINUX_APP_CHECK_VERIFIER_URL`. Do not reuse
`LINUX_APP_CHECK_VERIFIER_AUDIENCE`: that value is embedded in and checked on
the verifier's signed application verdict, not the Cloud Run transport token.

Daemon endpoint overrides are deployment/test controls only:

- `OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT`
- `OPENBURNBAR_LINUX_ATTESTATION_ENROLLMENT_TICKET_ENDPOINT`
- `OPENBURNBAR_LINUX_ATTESTATION_UPLOAD_TICKET_ENDPOINT`
- `OPENBURNBAR_LINUX_ATTESTATION_INGRESS_ENDPOINT`
- `OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT`

All overrides must be exact HTTPS URLs without user information, query, or
fragment components. Invalid explicit overrides fail closed. The ingress
override is additionally required whenever the upload bridge is active; unlike
the callable endpoints, it has no production default. The network client
refuses redirects, non-HTTPS endpoints, oversized responses, an unexpected
final URL, malformed callable envelopes, and token-bearing requests without a
valid account context.

Do not place verifier private keys, raw tokens, attestation evidence, TPM
credentials, or keyring secrets in environment variables, renderer state, logs,
support bundles, or documentation artifacts.

## Supported And Unsupported Environments

No environment is production-supported until exact-candidate installed evidence
is accepted.

| Environment | Production App Check policy | Current state |
|---|---|---|
| Physical TPM 2.0, Secure Boot/measured boot enabled, supported repository-installed deb/rpm | Intended first supported tier after broker, verifier, enrollment, package, revocation, and installed tests pass | Blocked |
| Physical TPM 2.0, AppImage | No privileged broker lifecycle under the current policy | Unsupported |
| Generic VM or vTPM | Local workflows only unless a separate VM trust policy is approved | Unsupported |
| No TPM or Secure Boot off | Local workflows only; protected cloud mutations unavailable | Unsupported |
| Source build, container, WSL, Flatpak, or Snap | No production App Check minting under the current policy | Unsupported |
| Explicit emulator/test mock | Automated tests only; never production evidence | Test only |

An unsupported host must surface App Check as unavailable before action. It must
not silently use mock evidence or downgrade a protected mutation to auth-only.

## Rollout And Kill Switches

- `ENFORCE_APP_CHECK=true` keeps callable App Check enforcement on.
- `REQUIRE_HIGH_RISK_NONCE=true` forces high-risk nonce consumption in production.
- `ALLOW_MOCK_APP_CHECK_ATTESTATION` is forced off in production by `config.ts`.
- `LINUX_APP_CHECK_MINT_ENABLED=false` is the primary Linux mint kill switch and
  the default. It makes production challenge acquisition fail closed.
- Removing the Linux ID from `APP_CHECK_ALLOWED_APP_IDS` is the second containment
  boundary. It denies Functions callables immediately. Keep Apple/Android and
  `APP_CHECK_STANDARD_WEB_APP_IDS` unchanged.
- An incomplete verifier configuration, placeholder app ID, unknown evidence
  kind, verifier outage, invalid verdict, replay, or binding mismatch fails
  closed. There is no production mock fallback.

Roll out in this order: provision the dedicated Firebase Web app; deploy the
verifier and pin its identity; deploy Functions with minting disabled; enroll a
small TPM-backed broker ring; run all negative vectors and installed matrix
checks; enable minting for the ring; then advance only with release-head-bound
evidence. Keep high-risk step-up enforcement enabled throughout.

To roll back, set `LINUX_APP_CHECK_MINT_ENABLED=false` and remove the Linux app ID
from the allow-list. Classified Functions callables deny the ID immediately,
but an already minted token can remain valid for direct owner-scoped
Firestore/Storage rules access until its fixed 30-minute TTL expires because
Firebase Rules do not inspect the app ID. Treat containment as a maximum
30-minute drain unless the affected direct-product surface is separately
revoked. Local SQLite data and local account workflows remain intact. Rotate
the verifier key or policy ID to revoke future minting. Never lengthen the TTL
or enable mock attestation to work around an outage. See
[`FIREBASE_APP_CHECK_ENFORCEMENT.md`](../FIREBASE_APP_CHECK_ENFORCEMENT.md).

## SecretStore Setup

Approved high-value custody levels are Secret Service/libsecret, KWallet,
systemd credentials, and explicit headless passphrases. Plaintext local files are
refused for DB keys, Signal identity keys, CloudVault keys, refresh tokens,
capability roots, local-auth pins, and audit/export signing keys.

The packaged daemon discovers native tools only at fixed, root-owned system
paths. Ambient `PATH` entries and user-writable executables are not trusted.
The primary desktop backend is `secret-tool` plus a working
`org.freedesktop.secrets` session service. KWallet through `kwallet-query` is the
KDE fallback. Packages install or depend on the command-line client as follows:

| Package family | Required | Optional desktop backend |
|---|---|---|
| Debian/Ubuntu | `libsecret-tools` | `gnome-keyring`, `libkf5wallet-bin`, or `libkf6wallet-bin` |
| Fedora/RHEL RPM | `libsecret` | the distribution KWallet package |
| Arch/AUR | `libsecret` | `kwallet` |

Secrets are passed to native tools on standard input, never in arguments or the
environment. Values are capped at 16 KiB and must be a single line because both
native command protocols are line-oriented. Leading and trailing spaces are
preserved. A locked or failed primary keyring fails closed; OpenBurnBar does not
silently fall back to an environment variable or plaintext file.

Headless deployments should mount secrets through systemd
`CREDENTIALS_DIRECTORY`. Process-environment secrets require the explicit test or
development opt-in and are disabled by production factory wiring. Diagnostics
log only trust metadata, backend names, and redacted labels.

Flatpak metadata grants the exact `org.freedesktop.secrets` bus name, but that
channel remains unpromoted until `secret-tool` availability and locked/unlocked
keyring behavior pass inside a real sandbox. Do not describe Flatpak credential
custody as supported before that evidence exists.

### Credential custody QA

1. Install on a clean GNOME session and verify provider and connector CRUD,
   restart persistence, sign-out deletion, and absence of secrets in process
   arguments, environment, logs, support bundles, and renderer memory.
2. Lock the keyring and verify reads and writes fail with a repairable error and
   do not fall back. Unlock it and retry without restarting the daemon.
3. Repeat on KDE with KWallet as the only available native backend.
4. Remove both native tools and verify the capability reports unavailable rather
   than accepting a plaintext file.
5. Run a headless systemd service with a credential file, rotate the credential,
   restart, and verify the old value is no longer accepted.

## Auth And Membership

Linux primary sign-in uses the system browser with PKCE loopback. Refresh/session
tokens must be stored through the approved SecretStore custody path. Linux
membership restore uses Stripe checkout or portal state and never links StoreKit.

## Telemetry And Support Bundles

Linux telemetry is dark unless consent and plan policy allow it. Support bundles,
logs, crash/error records, and provider traces must pass the shared redaction
policy before leaving the machine.

## Cloud Sync Privacy

Cloud sync treats local SQLite as source of truth. Linux sync may upload only
approved collection paths under `users/{uid}`. Private bodies, prompts, cookies,
tokens, and raw file paths must be sealed or omitted; watermarks advance only
after durable local commit.

## Blocked Production Evidence

Do not claim high-risk production Linux cloud availability until all are present:

- a dedicated real Firebase Web app ID and production allow-list entry;
- deployed root-owned broker, TPM 2.0 enrollment/revocation, nonce-qualified
  quotes, release/package measurement, UEFI measured-boot policy, and IMA
  measurement verification where required;
- deployed signed-verdict verifier with pinned identity and operational key
  rotation, outage, denial, and audit behavior;
- signed release/provenance binding and revocation for replaced candidates;
- negative vectors for forgery, replay, expiry, wrong user/app/device/version/
  architecture/release/policy, bad signature, revoked device, clock skew, and
  verifier outage;
- live Firebase staging/production traces and installed GNOME, KDE, headless,
  x86_64, aarch64, deb, rpm, and any claimed AppImage environment evidence;
- confirmation that no token, evidence, challenge, private key, or credential
  appears in renderer state, logs, crash reports, process metadata, or support
  bundles.

Until then, emulator/fixture evidence may validate the source boundary only.
`LNX-APPCHECK-001`, dependent protected cloud rows, and stable Linux promotion
remain blocked.

### App Check QA acceptance

Run the source contract and service suites from the repository root:

```bash
node --test scripts/linux-port/linux-attestation-contract.test.mjs
npm run build --prefix functions
npm run test:unit --prefix functions -- src/__tests__/linuxAttestationClientBridge.test.ts
npm test --prefix services/linux-attestation-facade
docker run --rm -v "$PWD:/workspace" -w /workspace \
  openburnbar-linux-toolchain:mission-001 \
  bash -lc 'apt-get update >/tmp/apt-update.log &&
    apt-get install -y libpam0g-dev >/tmp/apt-install.log &&
    bash scripts/linux-port/run-linux-native-tests.sh'
```

These commands prove source behavior only. They do not replace the physical-TPM,
installed-package, verifier deployment, revocation, and desktop-matrix evidence
required for production acceptance.

1. Issue one challenge and verify its raw nonce is absent from Firestore while
   the SHA-256 hash, complete binding, five-minute expiry, and 24-hour TTL marker
   are present.
2. After broker evidence production, issue an upload ticket with the raw
   challenge and exact bundle digest/size. Verify Firestore stores only the
   secret hash, returns an identical ticket ID for an identical retry, rejects
   a different retry, and never returns or logs the secret or server upload ID.
3. Race callers at every upload/enrollment count and byte quota boundary.
   Exactly the configured number may succeed, failed or unused reservations
   are not refunded, and the next fixed window uses a distinct quota document.
4. Send three malformed or abandoned upload bodies, then verify a fourth PUT is
   rejected before body consumption. Repeat with one successful upload and two
   identical receipt retries; the fourth attempt must also be rate-limited.
   Verify exact-length chunked bodies and Firestore TTL/rules for root upload
   and enrollment records.
5. Race enrollment completion, force Keylime response loss, reclaim an expired
   activation lease, and force local commit response loss. One exact remote
   identity may become active; stale workers and mismatched TPM material must
   never transition or delete current state.
6. Race two mint requests from independent instances. Exactly one may consume
   the challenge; the other must fail as replayed.
7. Mutate every binding field and signed-verdict field individually. Each must
   fail before token minting or session recording.
8. Verify malformed, expired, denied, oversized, redirected, timed-out, unsigned,
   wrong-key, wrong-issuer, and wrong-audience verifier responses fail closed.
9. Verify a valid signed verdict mints one token with a fixed 30-minute expiry,
   records only the token hash and receipt, and leaves every challenge, session,
   ticket, slot, quota, upload, and enrollment collection unreadable and
   unwritable to clients.
10. Exercise daemon coalescing, refresh lead time, expiry, cancellation, account
   switch, session-generation switch, sign-out, locked keyring, offline/retry,
   process restart, and clock skew. Verify missing or invalid ingress
   configuration fails before transport; redirects are refused; cancellation
   stops the active request; the ticket header is present only on the claim
   `POST`; the `PUT` streams the exact declared bytes; and receipt mismatches
   never reach minting. Raw token, secret, quote, evidence, descriptor, and
   receipt state must disappear on daemon restart and must never cross the
   renderer or RPC status contract.
11. With `LINUX_APP_CHECK_MINT_ENABLED=false`, verify challenge, ticket, and mint paths fail
   closed while local SQLite, local provider, and local sign-out workflows work.
12. Repeat the production vectors against the exact signed candidate on every
   environment claimed as supported, retaining verifier decision logs and
   package/release measurements bound to the same commit.
