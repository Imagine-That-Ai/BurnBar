# Linux daemon event subscription authority

Status: implemented foundation; installed recovery certification remains open.

This document records the Linux event freshness contract introduced for
`LNX-EVT-001`. It is an additive BurnBarRPC contract shared by the Swift daemon,
the Tauri command boundary, and the renderer. It does not claim a native push
transport or close the installed desktop/compositor matrix.

## Contract

The daemon exposes three authenticated, capability-scoped methods:

| Method | Purpose |
|---|---|
| `subscription.start` | Allocate a bounded topic subscription and return its first snapshot cursor. |
| `subscription.resume` | Advance an existing cursor or recover the same cursor after daemon restart. |
| `subscription.stop` | Cancel a subscription and tombstone its identifier against late resumes. |

Supported topics are `data`, `health`, and run-scoped `run`. Subscription, run,
and client identifiers are trimmed, length-bounded, and restricted to a safe
identifier alphabet. A requested identifier cannot replace an active record.
Topic, run, and client scope must match on every resume; stop requires the
original client owner.

Every response carries a monotonic integer `seq`, a string cursor, one
nonterminal event, the daemon session identifier, recovery flags, and explicit
backpressure metadata. The daemon keeps at most 128 records for 15 minutes,
evicts the least-recently-used record at capacity, and expires stop tombstones
on the same bound.

## Honest transport state

The current transport is bounded pull over the existing authenticated AF_UNIX
BurnBarRPC request/response envelope. Responses therefore set:

- `degraded_fallback = true`
- `degradation_reason = bounded_pull_over_burnbarrpc_envelope`
- `backpressure = coalesce_latest_per_topic`
- `terminal_state_delivered = false`

The event is an invalidation signal. The mounted route reloads its authoritative
daemon data after the cursor advances. This removes the previous one-shot fake
terminal snapshot, but it is not represented as a push stream.

## Desktop lifecycle

The packaged Linux shell owns one `data` subscription supervisor:

- 15-second foreground and 60-second background cadence;
- one request in flight, with focus/visibility/connectivity wakes coalesced;
- no daemon request while the browser reports offline;
- exponential failure retry from 1 to 30 seconds;
- cursor preservation through connection failure and daemon restart;
- remote stop on normal renderer shutdown, including start/stop races;
- one Zustand data revision per accepted cursor.

Mounted route loaders consume that revision. If a load is already running,
additional revisions collapse into one follow-up load. Other routes stay
unmounted, avoiding a fan-out of duplicate polling work. The existing health
supervisor remains a lower-frequency independent liveness signal.

## Recovery behavior

| Failure | Expected behavior |
|---|---|
| Daemon restarts | `resume` recreates the unknown record at `after_seq + 1`, sets disconnect/recovery flags, and returns a first snapshot. |
| Socket call fails or stalls until timeout | The desktop keeps its cursor and retries with bounded exponential backoff; no overlap is allowed. |
| Offline | Calls pause; `online` wakes immediately and resumes the prior cursor. |
| Suspend/background | Background cadence applies; focus or visibility wake triggers one immediate resume. |
| Renderer closes | The timer stops and `subscription.stop` is sent best-effort; daemon TTL remains the crash fallback. |
| Cursor diverges | The daemon advances beyond both cursors, marks disconnect detected, and emits `cursor_reconciled`. |
| Scope changes | The daemon fails closed with `subscriptionMismatch`. |

## Verification

Repository coverage includes:

- Swift actor tests for monotonic advance, restart recovery, cancellation,
  duplicate-ID rejection, and scope/identifier validation;
- a real daemon AF_UNIX start/resume/stop round trip;
- Linux XCTest coverage for restart and cancellation behavior;
- strict TypeScript decoding of every required wire field;
- Vitest fake-timer coverage for cadence, no-overlap, wake coalescing, offline,
  backoff, restart recovery, shutdown, and lane-load coalescing;
- Rust wire-name tests and the generated 115-method IPC canon.

Run the focused desktop checks with:

```bash
npm test --prefix apps/linux-desktop -- --run \
  src/state/daemonSubscriptionSupervisor.test.ts \
  src/state/useLaneLoad.test.tsx \
  src/tauriBridge.test.ts
npx --prefix apps/linux-desktop tsc --noEmit -p apps/linux-desktop/tsconfig.json
cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
node tools/ipc/generate-burnbarrpc-canon.mjs --check
```

The Linux-native manifest must run inside the repository toolchain container:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace \
  openburnbar-linux-toolchain:mission-001 \
  bash scripts/linux-port/run-linux-native-tests.sh
```

## Remaining certification

`LNX-EVT-001` and `GAP-020` remain partial until an exact installed candidate
passes daemon kill/restart, socket stall, offline/online, suspend/resume, clock
change, locked DB/keyring, 10k/100k data, and long-idle/use soak checks across
the minimum GNOME/KDE, X11/Wayland, and architecture matrix. A future native
push transport may remove the explicit degraded-pull status, but it must retain
the cursor, backpressure, cancellation, and recovery contract above.
