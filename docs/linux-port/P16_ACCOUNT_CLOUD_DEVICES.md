# P-16 Linux Account, Cloud, And Devices

This packet documents the Linux desktop boundary for account and trusted-device
parity. It is intentionally separate from the parity ledger: source tests and
UI wiring do not certify live Firebase, keyring, or physical-device behavior.

## Canonical Linux Contract

The packaged Tauri shell proxies the daemon's authenticated Linux auth methods:

| User action | Tauri command | Daemon method | Result |
| --- | --- | --- | --- |
| Check account posture | `account_status` | `daemon.auth.status` | Redacted identity, sync, enrollment, and failure state |
| Start browser sign-in | `account_begin_sign_in` | `daemon.auth.begin` | Browser opens from a validated daemon URL; operation ID stays in the daemon-backed state |
| Cancel sign-in | `account_cancel_sign_in` | `daemon.auth.cancel` | Status snapshot for the same operation ID |
| Sign out | `account_sign_out` | `daemon.auth.sign_out` | Daemon-owned teardown and redacted signed-out status |
| Replace rejected installation identity | `account_rotate_identity` | `daemon.auth.rotate_identity` | New daemon-owned identity and approval state |

The injected daemon cloud runtime adds an authenticated socket contract that is
ready for production gateway composition:

| User action | Daemon method | Capability | Result |
| --- | --- | --- | --- |
| Inspect backup posture | `daemon.cloud_sync.status` | `lifecycle` | Redacted consent, queue, retry, key-lock, and last-success state |
| Change backup/remote-read consent | `daemon.cloud_sync.policy.update` | `config` | Allowlisted domain policy persisted without requiring an unlocked vault key |
| Run a manual sync cycle | `daemon.cloud_sync.run` | `config` | Push/pull/conflict counts and redacted resulting status |

The renderer never receives refresh tokens, Firebase ID tokens, App Check
tokens, private keys, or session-generation material. Unknown or transitional
daemon phases (`refreshing`, `locked`, `configuration_required`, `error`, or a
future value) remain `unavailable`; they are never misreported as signed out.
Fixture mode cannot dispatch account mutations.

## Trusted-Device Boundary

The Firebase callables `listLinuxAppCheckDevices`,
`approveLinuxAppCheckDevice`, and `revokeLinuxAppCheckDevice` are canonical
cloud methods, but they are not Linux desktop RPCs. They require a signed-in
native App Check caller, a trusted iOS/iPadOS/Android manager, a fresh
high-risk nonce, and a nonce-bound signed action proof. The Linux shell therefore
does not call them or present a local approve/revoke control.

When the daemon reports a pending installation, Linux shows the stable device
ID and safety fingerprint, provides copy actions for both values, and directs
the user to compare them on the trusted iPad. Rejected identities can be
rotated only through `daemon.auth.rotate_identity`, after explicit confirmation.

## Daemon Cloud Replica Core

Linux now has a daemon-owned local-first replication core in
`OpenBurnBarDaemon/CloudSync`. It provides the durable behavior that the macOS
Firestore SDK previously supplied implicitly:

- per-account, per-domain backup consent, with remote access gated separately
  and disabled by default;
- Cloud Vault AES-256-GCM sealing before persistence or gateway delivery, with
  v2 AAD bound to account, domain, document, field, and purpose;
- a SQLCipher/GRDB replica table, FIFO outbox, sync cursor, and retry state;
- stable mutation IDs that gateways must deduplicate across a response-loss or
  daemon-restart replay;
- fail-closed push acknowledgement and pull cursor advancement;
- pending-local-wins conflict handling followed by a deterministic total order
  of revision, modification time, and source device ID;
- durable tombstones and capped exponential transport backoff; and
- a runtime boundary that resolves the account UID and vault key inside the
  daemon and returns only redacted counters and lifecycle state.

The renderer must not write these tables, construct replicas, provide a UID or
vault key, or call a cloud backend directly. `LinuxCloudSyncRuntime` is the only
RPC composition boundary for consent changes and manual sync cycles.

## Remaining Transport Work

The engine and runtime are production code, but live cloud delivery remains
disabled until the Firebase side publishes a canonical Linux replica transport.
The current Firestore rules expose domain-specific macOS schemas; they do not
define a generic Linux replica collection or an atomic idempotency receipt.
Inventing a renderer-owned collection would bypass the existing validation and
App Check boundary. The remaining work is therefore explicit:

1. Publish a backend contract for atomic idempotent push and cursor-based pull,
   including App Check enforcement and per-domain validation.
2. Implement the authenticated gateway with daemon-owned Firebase/App Check
   credentials and stable mutation-ID receipts.
3. Compose the implemented runtime/socket contract with the production gateway
   and SecretStore providers in `OpenBurnBarDaemonMain`, then expose its existing
   consent/status/manual-cycle RPCs in the Account surface.
4. Route trusted Iroh remote-read requests through `readForRemoteAccess`, with
   the existing peer/grant authorization applied before decryption.
5. Prove live two-device upload, offline replay, conflict convergence, deletion,
   keyring lock/unlock, sign-out teardown, and remote-read revocation.

Credential transfer remains unavailable. It requires the existing trusted-device
escrow protocol rather than this replica engine; no credential material is placed
in the replica store.

## Verification

Focused Linux desktop coverage:

```bash
npx vitest run src/surfaces/account/AccountSurface.test.tsx src/state/accountStore.test.ts src/bridgeRpcBehavior.test.ts --reporter=dot
npx tsc --noEmit
npm run build
npm run bundle:check
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --manifest-path src-tauri/Cargo.toml --lib
```

Focused daemon core coverage:

```bash
cd OpenBurnBarDaemon
swift test --filter LinuxCloudReplicaEngineTests
```

The deterministic suite verifies ciphertext-only gateway payloads, independent
remote-access consent, outbox retention and stable retry IDs, restart durability,
invalid-envelope cursor safety, equal-revision two-device convergence, capped
backoff recovery, and redacted runtime responses.

Manual installed QA must still prove browser auth, keyring lock/unlock,
approval pending/rejection, identity rotation, sign-out teardown, restart,
clock skew, and the physical iPad approval flow. Those are evidence-gated and
remain blocked in `docs/linux-port/parity-ledger.json` until the required
current-head receipts exist.
