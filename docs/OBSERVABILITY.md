# OpenBurnBar Observability Contract

Cross-surface logging uses a shared correlation shape:

| Field | Source | Purpose |
|-------|--------|---------|
| `trace_id` | `TraceContext` / Functions `logging.ts` | End-to-end request correlation |
| `session_id` | Chat / CU session | Sub-tree correlation |
| `user_id_hash` | Auth uid SHA-256 prefix | Tenant correlation without PII |
| `event` | All surfaces | Stable operation name |

## macOS app

- `AppLogger` merges `TraceContextBridge.currentContext()` into every metadata line.
- Optional Sentry breadcrumbs on errors (opt-in via DSN).

## Daemon

- `BurnBarDaemonLogger` merges trace context and logs metadata as `.private`.
- Values truncated at 120 chars; sensitive keys should not be passed raw.

## Cloud Functions

- Use `functions/src/logging.ts` (`logInfo`, `logError`) for JSON structured logs.
- Budget evaluator publishes kill-switch RC events to `ops/computer_use_budget_status/events/`.

## Android

- Crashlytics **off by default** (`burnbar.diagnostics` prefs `crashlytics_enabled`).
- Aligns with [`docs/PRIVACY.md`](PRIVACY.md).

## Incident playbook

1. Grab `trace_id` from macOS Console or Functions log JSON.
2. Correlate daemon RPC + relay audit entries sharing the same id.
3. For Computer Use incidents, check `ops/computer_use_budget_status/state/current` and RC `computer_use_kill_switch`.
