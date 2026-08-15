# BurnBar Fleet API

The agent-readable fleet API: the daemon's versioned RPC surface and the
well-known snapshot file. This document is the authoritative contract for
external consumers (any local agent/CLI) and for the BurnBar app itself.

> **Status:** M4 (orchestrator + directive delivery) authored the write-method
> scope and the Hermes delivery branch declaration below. The complete
> snapshot schema, socket-path placeholder convention, well-known-file
> format, and consumer examples are documented by the M5 milestone
> (`fleet-api-docs-and-consumer`); this file is the single home for both.

## Socket

- Path: `~/Library/Application Support/BurnBar/burnbar-daemon.sock` by
  default. The daemon accepts `--socket-path <path>` to override; the app
  uses the same default path (hermetic validation redirects the support dir
  so the app and daemon share a scratch socket).
- Transport: one-shot JSON-RPC over a unix socket. One request line (raw
  UTF-8, ≤ 64 KB excluding the trailing newline) → one response JSON line →
  clean close. A second request requires a second connection.
- Protocol: `BurnBarProtocolVersion.current == 1`. Additive methods do not
  bump the version; a request declaring a mismatched version receives a
  typed protocol-mismatch error.

## Read methods

- `daemon.fleet.snapshot` — latest completed `BurnBarFleetSnapshot`.
- `daemon.fleet.orchestrator.get` — daemon-owned orchestrator state
  (designation + `pendingDirectives`).

## Write methods (M4 scope)

- `daemon.fleet.orchestrator.set` — sets the orchestrator designation
  (`none | burnBarManaged | agent(<fleetAgentID>[, sessionRef])`). The
  daemon stamps `setAt`; invalid designations are rejected typed and the
  stored state stays unchanged.
- `daemon.fleet.directive.record` — records a directive (idempotent upsert
  by `directive_id`). Validation (unknown kind, empty id/payload,
  non-roster `targetAgent`) rejects typed with no record created. Terminal
  authority is monotonic: existing `dismissed` and `delivered` records are
  immutable against **all** later candidates, including stale `delivered` or
  `failed` callbacks. An existing `failed` record remains authoritative for
  ordinary candidates; the explicit `failed → delivered` retry transition is
  supported, and an explicitly identified approved retry handoff may begin a
  new external attempt after failure.
  An approved candidate with `deliveryChannel` and a unique
  `deliveryAttemptID` is a durable external-delivery handoff. Once present,
  later approved reconciliation candidates cannot replace or erase that
  handoff; a new approved attempt is allowed only after an existing failed
  outcome and must carry its own attempt id. The authoritative record is
  returned unchanged whenever a candidate is rejected by these rules.

Directive records are read via read-only `sqlite3` inspection of the
daemon-owned `fleet.sqlite` (`fleet_directives` table) — there is no
directive-list RPC by design.

## Hermes delivery branch declaration (M4)

**Branch A — writable Hermes channel is implemented.**

The Hermes gateway exposes a documented writable input channel: its
`api_server` platform (`POST /v1/chat/completions` on
`http://127.0.0.1:8642`, Bearer auth via `API_SERVER_KEY`). BurnBar delivers
human-approved directives targeting `hermes` through that endpoint.

### Delivery lifecycle

1. A directive proposal is rendered as an explicit card with Approve and
   Dismiss actions. Until a human decides, no record exists and no delivery
   occurs.
2. **Approve** records `{"kind":"approved"}` with a non-null `decidedAt`
   via `daemon.fleet.directive.record`. Approval is observable before any
   terminal delivery outcome.
3. Delivery then runs through the Hermes channel:
   - before the Hermes request, BurnBar records the approved candidate with
     `deliveryChannel: "hermes"` and a unique `deliveryAttemptID`; this durable
     handoff is the retry/idempotency fence;
   - the card shows `delivering` while the request is in flight;
   - a valid acknowledgement transitions the record
     `approved → delivered` with `deliveryChannel: "hermes"`;
   - a gateway failure (transport error, non-200 HTTP) transitions the
     record to `{"kind":"failed","reason":"<non-empty>"}` — never limbo,
     never a fabricated delivery;
   - a malformed acknowledgement (invalid JSON, missing/mismatched
     `directive_id`, unknown or contradictory status) **fails closed** to
     `{"kind":"failed","reason":"malformedAck: ..."}` — never `delivered`.
4. **Dismiss** records `{"kind":"dismissed"}`; a dismissed directive is
   never delivered and triggers no channel call.
5. **Retry semantics (documented):** a failed delivery offers a single
   user-action Retry on the card. There is no silent background retry loop.
   A retry restarts the delivery flow from the approved directive and
   preserves the original `decidedAt`.
   If the app is relaunched while the card says `delivering`, it first
   reconciles the directive record with the daemon. A known terminal outcome
   is adopted without another gateway request; an `approved` record carrying
   a durable `deliveryAttemptID` becomes an uncertain, retry-blocked typed
   state requiring explicit daemon reconciliation. If the daemon is
   unavailable, the card remains visibly blocked until reconciliation
   succeeds, so a duplicate delivery cannot be started.
6. **Unsupported agents:** an approved directive targeting an agent with no
   documented writable channel (any agent other than `hermes`) honest-
   degrades: the record stays `approved`, no side effects occur, and the
   card shows "Delivery unsupported" with copy/retry affordances.
7. Claude's `/tmp/cc-socks/*.sock` messaging socket is undocumented
   internal IPC and is **never** used for delivery.

### Acknowledgement contract (fail closed)

The gateway response must be HTTP 200 and valid JSON carrying:

```json
{"burnbar_delivery":{"directive_id":"<directive id>","status":"delivered"}}
```

Any deviation yields `failed(reason: "malformedAck: ...")`.

### Hermes fixture gateway

`tools/burnbar-fake-hermes-gateway.py` is the deterministic fixture for
delivery validation. Modes via `BURNBAR_FAKE_HERMES_MODE` (`ack`, `hold`,
`malformed-json`, `malformed-id`, `malformed-status`, `fail`); receipts are
appended to `$BURNBAR_FAKE_HERMES_SCRATCH/receipts.jsonl`. The app points at
the fixture via `BURNBAR_HERMES_GATEWAY_URL` (default
`http://127.0.0.1:8642`). URL overrides are restricted to `127.0.0.1`,
`localhost`, and `::1` unless `BURNBAR_HERMES_ALLOW_REMOTE=true` is set
explicitly. The app authenticates via `BURNBAR_HERMES_API_KEY` or
the `API_SERVER_KEY` line of `~/.hermes/.env` (structural parse of that one
key only; the key is never logged, persisted, or copied into fixtures).

The fake gateway expects `Authorization: Bearer test-key` by default
(override with `BURNBAR_FAKE_HERMES_API_KEY`) and returns HTTP 401 for a
missing or incorrect header.
### Designation control (FleetView)

FleetView exposes the daemon-authoritative designation control:
BurnBar-managed, any declared agent, or None. Each action sends the
corresponding `daemon.fleet.orchestrator.set` request; the control and the
orchestrator badge change only after daemon acknowledgement. A rejected or
unavailable set preserves the prior acknowledged state and shows a typed
error — no optimistic local state. The designation propagates to the
snapshot's `orchestrator` block, the well-known file, and the UI after the
next completed fleet tick.
