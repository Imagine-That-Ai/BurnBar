# Linux Onboarding Authority

Linux first-run state is owned by `OpenBurnBarDaemon`. The WebView may cache the
last valid snapshot to avoid an empty first frame, but cached or fixture state
cannot authorize completion.

## Contract

The shared Swift contract defines a fixed schema-versioned sequence:

| Step | Requirement | Current daemon proof |
|---|---|---|
| `daemon` | Required | The authenticated local daemon accepted the onboarding RPC. |
| `secret_store` | Required | An approved mutable Secret Service or KWallet backend completed an ephemeral write, read, and delete. |
| `provider_paths` | Required | The daemon's XDG support directory is writable and survives atomic readback. This does not yet prove provider connection or log discovery. |
| `cloud_identity` | Optional | Explicit acknowledgement or deferral only. Native auth readback is future work. |
| `portal_input` | Optional | Explicit acknowledgement or deferral only. Portal permission readback is future work. |
| `tray` | Optional | Explicit acknowledgement or deferral only. Tray-host probing is future work. |
| `updates` | Optional | Explicit acknowledgement or deferral only. The native shell now reads and verifies the signed channel; package-manager lifecycle promotion remains separately gated. |
| `privacy` | Required | Both telemetry and cloud-sync choices are written to daemon state and returned in the committed snapshot. |

Required steps accept only `verified` as terminal. Optional steps accept
`verified`, `acknowledged`, or `skipped`. The daemon recomputes `completed` after
every mutation; clients cannot submit a completion flag.

## Storage And RPC

State is written atomically to the daemon support directory as
`linux-onboarding-state.json`. The directory is restricted to `0700` and the
file to `0600`. The persisted record contains only step state, bounded status
detail, timestamps, attempt counts, and privacy booleans. It contains no secret
values or provider payloads.

The socket contract is deliberately narrow:

| Method | Capability | Behavior |
|---|---|---|
| `daemon.onboarding.snapshot` | Lifecycle/read | Return validated daemon state. |
| `daemon.onboarding.action` | Config/write | Verify, acknowledge, skip, navigate, or save privacy choices. |
| `daemon.onboarding.reset` | Config/write | Replace state with a fresh pending snapshot and increment the revision. |

The desktop controller's Tauri commands proxy these methods over the
authenticated AF_UNIX connection. Read-only peers may fetch a snapshot but
cannot mutate it. The method-scoped CLI profile receives none of the onboarding
methods.

## Fail-Closed Rules

- Required steps cannot be skipped or acknowledged.
- Mutations must target the current step.
- Navigation cannot move beyond the first unresolved prerequisite.
- Persisted step order and requirement classification must match the fixed
  schema.
- A required step in an optional-only state is rejected.
- A current step ahead of an unresolved prerequisite is rejected.
- `completed` must equal the daemon's recomputed invariant.
- Privacy verification without committed choices is rejected.
- Probe failures persist as `blocked`, retain bounded diagnostic detail, and do
  not advance the wizard.
- Missing or malformed daemon authority routes the desktop to onboarding; the
  browser cache cannot unlock the dashboard.

## Recovery And Migration

Retry re-runs the active idempotent probe. Restart loads and validates the atomic
snapshot. Reset preserves no completion assertions and starts at `daemon` with
a higher revision. The legacy `openburnbar.linux.onboarding.v1` browser key is
ignored. The v2 browser key is a non-authoritative cache of strict daemon
responses only.

An incompatible future schema must add an explicit daemon migration before its
version is accepted. Corrupt or tampered state fails closed with
`invalidPersistedState`; it is not silently converted into a completed setup.

## Verification

The implementation is covered at five boundaries:

1. Swift service tests cover completion, required-step enforcement, ordering,
   blocked retry across a fresh service, reset, file permissions, and tampering.
2. Capability and handler-coverage tests pin read/write attenuation and every
   new RPC dispatch domain.
3. A real AF_UNIX server test round-trips snapshot, action, and reset.
4. Rust tests pin Tauri-to-Swift method names.
5. TypeScript and React tests cover strict decoding, legacy-key rejection,
   daemon-driven progress, unavailable authority, and the absence of Skip on a
   required step.

The complete native Linux regression manifest passes 98 Swift XCTest selectors
and 18 Rust tests. The full Linux desktop suite passes 400 TypeScript/React
tests and the production bundle verifier.

Installed-product certification must additionally exercise GNOME and KDE with
unlocked, locked, and missing keyrings; clean and resumed users; keyboard and
screen reader traversal; denial/retry; reset; and package upgrade migration.

## Remaining Parity Work

This authority layer is the foundation for `LNX-ONB-001`, not its final closure.
Full parity still requires typed probes and repair actions for provider account
connection, real log scanning, cloud auth, portal grants, tray availability,
signed feed publication and package lifecycle, chat-engine selection, and first usable data. Those
steps should become required only when the daemon can verify their outcomes and
the Linux-native substitute policy is settled.
