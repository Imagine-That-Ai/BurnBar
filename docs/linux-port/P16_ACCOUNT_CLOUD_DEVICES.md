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

Cloud backup, conflict resolution, credential transfer, and remote access remain
unavailable until a canonical daemon contract exists for each operation. The
UI names those limits instead of fabricating local state or mutating Firestore
from the renderer.

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

Manual installed QA must still prove browser auth, keyring lock/unlock,
approval pending/rejection, identity rotation, sign-out teardown, restart,
clock skew, and the physical iPad approval flow. Those are evidence-gated and
remain blocked in `docs/linux-port/parity-ledger.json` until the required
current-head receipts exist.
