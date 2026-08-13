# BurnBar Fleet Signals — Canonical Per-Agent Signal Inventory

**Status:** authoritative for the Live Agent Fleet mission (M0–M6).
**Grounding:** empirical probe results verified on Alberto's machine on 2026-08-11 (pids confirmed via `ps`), recorded in the mission library (`library/fleet-signals.md`) and architecture.md §5. This document is the canonical per-agent signal inventory that M1 probes implement against. Do not re-derive agent behavior from memory — re-probe before assuming freshness; agents come and go.

**Roster:** the fixed snapshot/probe roster is exactly these ten wire IDs:

`claude-code`, `factory-droid`, `codex`, `hermes`, `grok-bot`, `grok-cli`, `pi`, `cursor`, `kimi`, `gemini-cli`

Seven are target agents with live probes (`claude-code`, `factory-droid`, `codex`, `hermes`, `grok-bot`, `grok-cli`, `pi`). `cursor` is a partial-confidence probe. `kimi` and `gemini-cli` are typed unsupported rows — they are present in every snapshot, never omitted, never presented as live.

Every agent row in a snapshot carries exactly one status (`running | idle | stale | unknown`) and one confidence (see [Confidence model](#confidence-model)). Every probe-health entry names its declared root path and a typed state (`ok | degraded(reason) | failed(reason)`).

---

## Freshness constants (pinned)

These are the pinned numeric defaults the snapshot builder and probes implement. They are constants, not approximations; M1 probes read them from the builder's constant set. The builder may tune them, but any tuned value must be reported in the snapshot's `cadenceSeconds`-adjacent configuration surface and documented.

| Agent (wire id) | Signal | Constant | Value |
|---|---|---|---|
| `claude-code` | session `updatedAt` window | `claudeCodeFreshnessSeconds` | **120** (2 minutes) |
| `hermes` | gateway heartbeat window | `hermesHeartbeatFreshnessSeconds` | **120** (2 minutes) |
| `grok-bot` | supervisor `at` / recent log window (alternate signal) | `grokBotSupervisorFreshnessSeconds` | **120** (2 minutes) |
| `factory-droid` | invocation `updatedAt` / session-dir mtime window | `factoryDroidFreshnessSeconds` | **300** (5 minutes) |
| `codex` | lock-file mtime window | `codexLockFreshnessSeconds` | **300** (5 minutes) |
| `pi` | newest transcript mtime window | `piTranscriptFreshnessSeconds` | **300** (5 minutes) |
| `cursor` | `ai-tracking/` mtime window | `cursorTrackingFreshnessSeconds` | **300** (5 minutes) |

Snapshot cadence: **15 seconds** by default (`BURNBAR_FLEET_CADENCE_SECONDS` override). Event retention: **24 hours** by default (`BURNBAR_FLEET_EVENT_RETENTION_SECONDS` override).

---

## Daemon seams (M1, implemented)

The daemon's fleet snapshot core exposes the following environment seams. Validators and hermetic tests depend on them; do not rename or remove them without updating this document and the validation contract.

| Seam | Env var | Default | Behavior |
|---|---|---|---|
| Snapshot cadence | `BURNBAR_FLEET_CADENCE_SECONDS` | `15` | Tick interval AND the snapshot's reported `cadenceSeconds` (single source of truth: the fleet service derives both from the builder). Values below 1 are rejected (default used). |
| Probe-root override (base) | `BURNBAR_FLEET_ROOTS_DIR` | real roots (`~/.claude`, …) | Overrides the base directory for ALL agents: each agent's root becomes `<override>/<agent-root-name>` (`claude`, `factory`, `codex`, `hermes`, `grokbot`, `grok`, `pi`, `cursor`, `kimi`, `gemini`). |
| Probe-root override (per-probe) | `BURNBAR_FLEET_ROOT_CLAUDE_CODE`, `BURNBAR_FLEET_ROOT_FACTORY_DROID`, `BURNBAR_FLEET_ROOT_CODEX`, `BURNBAR_FLEET_ROOT_HERMES`, `BURNBAR_FLEET_ROOT_GROK_BOT`, `BURNBAR_FLEET_ROOT_GROK_CLI`, `BURNBAR_FLEET_ROOT_PI`, `BURNBAR_FLEET_ROOT_CURSOR`, `BURNBAR_FLEET_ROOT_KIMI`, `BURNBAR_FLEET_ROOT_GEMINI_CLI` | none | Per-probe override wins over the base override. |
| Per-probe timeout | (constant `BurnBarFleetProbeConstants.perProbeTimeoutSeconds`, injectable per probe) | `2.0` seconds | Every signal-file content read is bounded: the file is opened non-blocking and polled for readability up to the timeout. A blocking path (FIFO) or a read that exceeds the bound degrades the affected probe typed (`degraded(reason: "... timed out ...")`) and the tick continues on cadence — a hung signal path never stalls the snapshot (VAL-FLEET-019). |
| Event retention | `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` | `86400` (24 h) | Accelerates fleet_events pruning for validation (implemented with the persistence layer). |

### Daemon-owned persistence (M1, implemented)

The daemon persists every completed tick into `fleet.sqlite` (GRDB, already a
BurnBarDaemon dependency — no new deps) and atomically writes the well-known
`fleet-snapshot.json` file. Both live in the daemon's support dir
(`BURNBAR_DAEMON_SUPPORT_DIR`, default `~/Library/Application Support/BurnBar/`).

**Schema (`fleet.sqlite`):**

| Table | Columns | Purpose |
|---|---|---|
| `fleet_snapshots` | `id` PK, `generated_at` REAL, `payload` TEXT | Latest completed snapshot JSON, persisted VERBATIM (the payload is the exact JSON of the served snapshot — its `cadenceSeconds` is already the configured cadence, never re-stamped). Pruned to the latest 240 rows (≈1h at the default 15s cadence). |
| `fleet_events` | `id` PK, `at` REAL, `agent` TEXT, `kind` TEXT, `from_status` TEXT, `to_status` TEXT, `detail` TEXT | Fixed-roster transition events. `status_changed` is ALWAYS recorded for a status change; `confidence_changed` is recorded when confidence changes — both with exact agent/from/to values. Pruned to exactly 24h by default; `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` overrides the window. |
| `orchestrator_state` | `id` PK CHECK (id = 1), `payload` TEXT | Schema only in M1; behavior lands in M4. |
| `fleet_directives` | `id` PK, `directive_id` TEXT UNIQUE, `payload` TEXT, `created_at` REAL | Schema only in M1; behavior lands in M4. |

**Model declaration: fixed-roster rows.** The ten declared agents are never
removed from snapshots; status/confidence transitions carry exact
agent/from/to values. `appeared`/`disappeared` events are NOT produced — they
are reserved for a documented dynamic session-row model, which this
implementation does not use.

**Atomic well-known file.** `fleet-snapshot.json` is written to
`fleet-snapshot.json.tmp` then atomically renamed (POSIX `rename(2)`). A
reader can only ever observe a complete file (the preceding complete
generation during the short replace window — never a partial write), and no
`.tmp` file remains after a completed write. The file payload is identical to
the last completed RPC response payload (VAL-API-004).

**`persistenceHealth` (single documented surface).** The snapshot's top-level
`persistenceHealth` covers BOTH the SQLite store and the well-known-file
writer. A store or writer failure degrades it typed (`degraded(reason)` with
a non-empty, non-secret reason) while RPC keeps serving the last completed
snapshot and the last-good file stays byte-identical (VAL-FLEET-021). It is
never misreported through per-agent `probeHealth`. A fully successful persist
clears degradation.

**Payload parity rule (single documented rule).** **The store persists
exactly the same snapshot payload that RPC and the well-known file serve for
that generation, including `persistenceHealth`.** The persister writes the
well-known file first with the final health, then writes the store row with
that same payload. Consequences, per surface:

- **RPC == file (VAL-API-004):** the served snapshot and `fleet-snapshot.json`
  are field-for-field identical for every completed generation.
- **RPC == sqlite:** the latest `fleet_snapshots` row is the exact served
  payload for its generation — including `persistenceHealth` when a writer
  failure degrades it. A sqlite consumer never observes a health that
  contradicts the served generation.
- **Store-write failure:** no row exists for the failed generation (the
  latest row remains the previous generation); the failure is surfaced
  through the served snapshot's `persistenceHealth`, and the file is
  re-written with the final degraded health so RPC and file stay identical.
- **Writer failure (VAL-FLEET-021):** the file intentionally lags at the
  last-good generation (byte-identical) while RPC and the store row agree on
  the current generation with the degraded health.

**Transition-baseline semantics.** The transition baseline
(`lastPersistedSnapshot`) advances ONLY after the store write AND the
transition-event insertion succeed — they run in one transaction (snapshot
insert, event inserts, retention pruning). A failed persist never advances
the baseline, so a later running-to-idle transition is never lost across a
failure: the next successful persist recomputes the transitions against the
last persisted state. Event pruning runs in the same transaction as the
insert, so an event whose timestamp is already beyond the retention cutoff
at insert time is pruned immediately (it never survives even one persist).

**Rebuild semantics (invariant 6).** The live fleet projection always
rebuilds from probes. Store corruption is detected on open: the store is
deleted + recreated and the recovery is surfaced through
`persistenceHealth: degraded(reason: "... rebuilt ...")`. The rebuild window
spans the FIRST published recovery snapshot: the degraded health is visible
on that snapshot via RPC, in `fleet-snapshot.json`, and in the
`fleet_snapshots` row, and clears only on the NEXT successful persist after
that publication (VAL-HARD-012/013). **Store deletion discards daemon-owned
orchestration history and re-initializes designation to `none`** — this loss
is by design and disclosed here; the live projection itself is rebuildable
without data loss.

### Snapshot builder behavior (M1 core)

- **Fixed ten-row roster.** Every snapshot's `agents[]` and `probeHealth[]` contain exactly one entry per declared roster id, in canonical order, even when a root is missing or an agent is unsupported. A missing probe degrades to a typed `unknown`/`unsupported` row with a `failed(reason)` health entry — never an omitted row.
- **Empty-root degradation.** With all roots empty/missing, every row is `unknown` with `unsupported` confidence (never `running`), and every probe-health entry is `failed(reason: "Declared root missing: <path>")` naming the resolved root path.
- **Derived aggregates.** `runningCount` equals the number of `running` rows; `countsByAgent[id]` is `1` iff that row is `running` (else `0`); `repos` groups rows by derived `projectName` (nil/empty project names are omitted from the grouping).
- **Machine status.** `cpuPercent`, `memoryUsedBytes`, `memoryTotalBytes`, `loadAverage` (3 elements), and `diskFreeBytes` are populated from Mach/`getloadavg`/`statfs`; `thermal` and `power` are typed `unavailable(reason)` on this machine (`pmset -g thermlog` is empty) — values are never invented.
- **Pre-first-tick RPC behavior (typed).** `daemon.fleet.snapshot` before the first tick completes returns the documented typed error `BurnBar fleet snapshot is not ready yet: the first probe tick has not completed. Retry shortly.` (code `-32603`, internalError) — never a fabricated empty snapshot presented as probed truth. The first tick runs immediately at daemon start, so the not-ready window is one build duration.
- **Cadence reflection.** Every ready snapshot and the well-known file report the same `cadenceSeconds` as the tick interval (both derive from the builder). Changing `BURNBAR_FLEET_CADENCE_SECONDS` changes both the tick interval and the reported value.
- **Default probes.** All ten roster agents are served by real per-agent
  probes (implemented M1): `claude-code` (sessions registry), `grok-cli`
  (active-sessions registry), `factory-droid` (task ledger + background
  registry + session/mission dir mtimes), `grok-bot` (daemon/supervisor
  JSON; inflightCount 0 = idle, not running), `hermes` (gateway.pid +
  heartbeat + gateway_state + processes; fresh heartbeat AND active work =
  running), `codex` (thread-writer-locks mtimes, logHeartbeat only), `pi`
  (session transcript mtimes, logHeartbeat only), `cursor` (worker ids +
  ai-tracking mtime, partial activeSessionFile), and `kimi`/`gemini-cli`
  (typed unsupported rows).
- **Probe behavior (file/pid-based probes).** The three signal probes follow
  the per-agent rules in this document exactly: live-pid + fresh signal →
  `running` with the documented confidence; dead pid → non-running with a
  confidence step-down (never `running`); stale signal → `stale`; malformed
  (valid-JSON, missing/mistyped required key) → typed `unknown`/`stale` with
  a `degraded(reason)` health entry — never fabricated liveness, and only
  the affected row degrades. Multi-session agents: one live session drives
  the row; dead/stale sessions never mask a live one, and `signals[]`
  reflects every evidence source read. Signal evidence paths are always
  inside the agent's declared roots; `~/.factory/artifacts/` is never read,
  listed, or traversed. Pid-reuse guarding: a pid whose process start time
  postdates the signal file's recorded `startedAt` is treated as dead
  (VAL-HARD-007).
- **Strict signal decoding (shared helpers).** The shared JSON helpers
  validate primitives strictly BEFORE any liveness logic: integer fields
  (`pid`, `inflightCount`, `active_agents`, background `pid`) reject
  NSNumber booleans, fractional values, and out-of-range numbers — no
  `intValue` coercion. Epoch-millisecond timestamp fields reject booleans
  and fractional values. A malformed value produces a typed non-running /
  degraded row with a probeHealth reason — never a live-looking integer,
  never silently healthy.
- **Pid range (pinned).** A JSON pid is valid only when it is an integral
  number in the positive macOS pid_t range (`1...Int32.max`). Zero,
  negative, and values beyond `Int32.max` are REJECTED before any
  pid_t/liveness conversion — on macOS pid_t is Int32 and the checked
  `pid_t(pid)` conversion traps on out-of-range values. The strict
  `pidValue` helper is the single home for the range guard: every probe
  converts JSON numbers to pid_t only through it, and the liveness helpers
  re-check the range as a second line of defense. A rejected pid degrades
  its entry typed with a probeHealth reason naming the malformed value.
- **Absent vs invalid process-start timestamps (pinned).** A signal file's
  process-start record (`startedAt`/`startTime`/`start_time`/`at`) is
  tri-state: ABSENT (field missing or null) keeps the documented fallback —
  the pid-reuse guard is skipped and `kill -0` decides; PRESENT-but-invalid
  (boolean, fractional, non-numeric) is malformed and degrades the entry
  typed with a probeHealth reason naming the malformed timestamp — it is
  never silently converted to nil and treated like an absent record (which
  would skip the identity guard and let a live pid pass liveness).

---

## RPC transport & error envelope matrix (M1, implemented)

The daemon RPC is newline-terminated JSON over a unix socket
(`~/Library/Application Support/BurnBar/burnbar-daemon.sock` by default;
`--socket-path` / `BURNBAR_DAEMON_SOCKET_PATH` override). The transport is
**one-shot**: one request on one connection produces exactly one response
line and the server then closes cleanly; a second request requires a second
connection. A client that connects and sends nothing never delays another
client's request (each connection is handled independently).

**Frame cap.** The request frame is capped at **65536 raw UTF-8 payload
bytes, excluding the trailing newline delimiter** (VAL-RPC-004). A payload
of exactly 65536 bytes plus its newline is at-cap and accepted; a payload of
65537 bytes is rejected with the typed oversize error. The cap counts raw
UTF-8 bytes, never characters.

**Error envelope shape (VAL-RPC-016).** Every error response is one
`BurnBarRPCResponseEnvelope` line: `protocolVersion: 1`, the request `id`
when it is syntactically recoverable, **no** `result`, and an `error` object
with one enumerated `code`, a non-empty `message`, and a **`details` field
that is ALWAYS present and encoded as a string** (non-optional in
`BurnBarRPCError`). `details` carries machine-actionable, never-secret-bearing
context for the failure class — byte counts for oversized frames, the
expected envelope shape for invalid requests, declared vs supported versions
for protocol mismatches. When the id is absent or wrong-typed (non-string),
the documented sentinel id `"no-id"` is used — the daemon never fabricates a
client-supplied id.

| Failure class | Example input | Code | id in envelope | `details` contents |
|---|---|---|---|---|
| Unknown method | `{"id":"2","method":"daemon.fleet.nonexistent"}` | `-32601` (methodNotFound) | echoed | `method=<requested method name>` |
| Malformed JSON | `{not json` | `-32700` (parseError) | `"no-id"` (not recoverable) | `expected=json_object; received=non_json_bytes` |
| Valid JSON fragment (not an envelope) | `null`, `123`, `"hello"`, `true` | `-32600` (invalidRequest) | `"no-id"` (not recoverable) | `expected_envelope={"id":string,"method":string,"protocolVersion"?:int}` |
| Oversized frame | valid JSON payload of 65537 bytes | `-32002` (frameTooLarge) | recovered from the partial frame when present | `max_bytes=65536; received_bytes=<raw UTF-8 payload bytes excluding the trailing newline>` |
| Missing id | `{"method":"daemon.health"}` | `-32600` (invalidRequest) | `"no-id"` | `expected_envelope={"id":string,"method":string,"protocolVersion"?:int}` |
| Wrong-typed id | `{"id":123,"method":"daemon.health"}` | `-32600` (invalidRequest) | `"no-id"` | `expected_envelope={"id":string,"method":string,"protocolVersion"?:int}` |
| Wrong params type | `{"id":"p-1","method":"daemon.fleet.orchestrator.set","params":"x"}` | `-32602` (invalidParams) | echoed | `expected_params=object; received=<top-level JSON type of params, e.g. string>` |
| protocolVersion mismatch | `{"id":"v-1","method":"daemon.health","protocolVersion":2}` | `-32001` (protocolVersionMismatch) | echoed | `declared_version=2; supported_versions=[1]` |

`details` never contains secrets, payload content, or request bodies — only
type names, byte counts, method names, and version numbers. Internal-error
envelopes (`-32603`) carry `details` naming the failing surface (e.g.
`state=not_ready; retry_after=first_tick` for pre-first-tick fleet reads,
`method=<name>; implemented_in=M4` for the M4 placeholder methods, or
`error=<error description>` for daemon-side failures).

**Parse-vs-classify boundary.** The parse-error class is reserved for bytes
that are not syntactically valid JSON at all. Top-level JSON fragments
(`null`, a bare number, a string, a boolean) are syntactically valid JSON and
are therefore classified as invalid requests (`-32600`) — they are valid JSON
that is not a valid RPC envelope. The envelope-shape check (object with
string `id` and `method`) runs separately from the syntax check.

**Versioning policy (VAL-RPC-012).** A request envelope that declares a
`protocolVersion` outside the supported set (`[1]`) is rejected with the
typed `-32001` mismatch error — never silently processed under v1 semantics.
An absent `protocolVersion` field means v1 (existing clients predate the
field). `BurnBarProtocolVersion.current` remains `1`; fleet methods are
additive and need no bump.

**Daemon stays usable.** Every failure class returns its typed error and the
daemon keeps serving: a follow-up `daemon.health` (or any valid request) on a
fresh connection succeeds. Oversized frames get the typed error response
instead of a silent close.

**Pre-first-tick reads** return the typed `-32603` not-ready error (see
"Snapshot builder behavior") — never a fabricated snapshot.

---

## Confidence model

Wire strings (golden, from `BurnBarFleetConfidence` in BurnBarCore):

`exactProcess > activeSessionFile > logHeartbeat > estimated > unsupported`

| Confidence | Wire string | Meaning |
|---|---|---|
| exactProcess | `exactProcess` | A live pid was verified (`kill -0` / `proc_pidinfo`) and the signal file corroborates it |
| activeSessionFile | `activeSessionFile` | A fresh session/state file exists but no pid registry is available (or the pid is dead) |
| logHeartbeat | `logHeartbeat` | Only file mtimes / log activity indicate liveness; no pid registry exists |
| estimated | `estimated` | Derived or inferred liveness with no direct evidence |
| unsupported | `unsupported` | No live signal is claimed for this agent; typed unsupported row |

Schema-level consistency rule (enforced by the contract layer): a `running` row may NEVER carry `unsupported` or `estimated` confidence; an `unknown`-status row never carries `exactProcess`.

Status semantics: `running` = active work signal right now; `idle` = agent infrastructure alive but no active work; `stale` = last signal beyond the freshness window; `unknown` = probe could not determine.

---

## Per-agent signal inventory

### 1. `claude-code` — Claude Code

- **Confidence:** `exactProcess`
- **Declared roots (read-only):**
  - `~/.claude/sessions/*.json` — one file per live session, keyed `<pid>.json`, removed on exit
  - Secondary (per-repo activity): `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` transcript mtimes
- **Signal file shape** (`~/.claude/sessions/<pid>.json`):

```json
{
  "pid": 19457,
  "sessionId": "…",
  "cwd": "/Users/albertonunez",
  "startedAt": 1750000000000,
  "version": "2.1.228",
  "kind": "interactive",
  "entrypoint": "cli",
  "messagingSocketPath": "/tmp/cc-socks/19457.sock",
  "name": "…",
  "status": "shell",
  "updatedAt": 1750000000000
}
```

  `pid`, `startedAt`, and `updatedAt` are epoch-milliseconds. `model` is not present (null).
- **Running rule:** any session file with a live pid AND `updatedAt` fresh (< **120 s**).
- **Idle rule:** session files exist but are stale or their pids are dead/absent.
- **Stale rule:** last fresh signal beyond the 120 s window.
- **Repo attribution:** `cwd` from the session file.
- **Notes:**
  - `messagingSocketPath` is Claude's INTERNAL IPC (`/tmp/cc-socks/<pid>.sock`) — excluded from directive-delivery scope (undocumented).
  - Multiple session files: one live session drives the row; dead/stale sessions never mask a live one.
  - **Malformed-sibling isolation:** a malformed session file (valid JSON,
    missing/mistyped required key) surfaces as a typed `degraded(reason)`
    probeHealth state on EVERY row the probe produces — including a
    stale/logHeartbeat row driven by a live-pid-but-stale sibling. A
    malformed sibling never flips a row to `running`, and a row with a
    malformed sibling is never reported with healthy probeHealth.

### 2. `factory-droid` — Factory Droid

- **Confidence:** `activeSessionFile`
- **Declared roots (read-only):**
  - `~/.factory/task-invocations.json` — task ledger (fresh, ~140 KB at verification)
  - `~/.factory/sessions/<project-slug>/` — session dirs (mtime freshness = interactive activity)
  - `~/.factory/background-processes.json` — background process registry (OFTEN EMPTY; candidate signal, not sole truth)
  - `~/.factory/missions/<id>/` — mission dirs (mtime = live mission)
  - `~/.factory/sessions-index.json` — index (300 KB+, fresh)
  - **NEVER enter `~/.factory/artifacts/`** (system-reserved; see [Out of scope](#out-of-scope))
- **Signal file shape** (`~/.factory/task-invocations.json`):

```json
{
  "invocations": [
    {
      "taskInvocationId": "…",
      "parentSessionId": "…",
      "childSessionId": "…",
      "runInBackground": false,
      "status": "completed",
      "subagentType": "…",
      "description": "…",
      "cwd": "/Users/albertonunez/Developer/AgentLens",
      "createdAt": "…",
      "updatedAt": "…",
      "toolUseCount": 0
    }
  ]
}
```

  `~/.factory/background-processes.json` shape: `{"processes": []}`.
- **Timestamp encoding (pinned):** `createdAt`/`updatedAt` in
  `task-invocations.json` and `startTime` in `background-processes.json` are
  **integral epoch-milliseconds** (verified on the real ledger, e.g.
  `1784343288288`). Fractional, boolean, or non-numeric values are malformed
  and degrade typed — they never become a live-looking timestamp.
- **Status vocabulary (pinned):** invocation `status` is one of the
  non-terminal strings `running | queued | pending | in_progress | active |
  working` or one of the terminal strings `completed | failed | cancelled`.
  Any other string (e.g. `"bogus"`) is **malformed**: it never counts as
  non-terminal and never yields `running`; the invocation degrades typed
  (`degraded(reason)` health) like a missing/mistyped key.
- **Running rule:** a non-terminal invocation with `updatedAt` fresh (< **300 s**), OR a live background-process entry, OR a session-dir mtime fresh (< **300 s**).
- **Idle rule (installed-but-inactive):** roots present, nothing fresh —
  including an **empty-but-present** `task-invocations.json` or
  `background-processes.json` registry, only fresh terminal invocations, or
  dead background entries. An empty-but-present registry is the documented
  installed-but-inactive state, **not** stale.
- **Stale rule:** last timestamped signal beyond the 300 s window.
- **Repo attribution:** invocation `cwd`, or session-dir slug decode (`-Users-albertonunez-…` → `/Users/albertonunez/…`).
- **Notes:**
  - No pid registry; confidence is `activeSessionFile` by design — never `exactProcess`.
  - **Background-entry liveness (PID-reuse guard):** a background entry's
    recorded `startTime` is compared against the current process start time
    before `kill -0` (same standard as the claude-code probe). A pid whose
    current process started after the entry's recorded `startTime` is a
    reused pid and is treated as dead; a missing/unqueryable record skips
    the guard (`kill -0` decides). A PRESENT-but-invalid `startTime`
    (boolean, fractional, non-numeric) is malformed: the entry degrades
    typed with a probeHealth reason naming the malformed timestamp and
    never reaches liveness — it is never treated like an absent record.
  - **Installed-root evidence:** a present root with no signal files at all
    is `idle` (installed-but-inactive) and carries a `root-presence` signal
    source naming the declared root — every determined (non-unknown) row
    carries at least one evidence path (VAL-FLEET-016).

### 3. `codex` — Codex

- **Confidence:** `logHeartbeat`
- **Declared roots (read-only):**
  - `~/.codex/thread-writer-locks/*.lock` — zero-byte, per-thread; mtimes fresh within minutes when active
  - `~/.codex/state_5.sqlite-wal` — mtime
  - `~/.codex/.codex-global-state.json` — mtime
  - `~/.codex/sessions/2026/…` — rollouts
  - `~/.codex/session_index.jsonl`
- **Running rule:** any lock-file mtime fresh (< **300 s**), corroborated by `ps` for codex processes when available.
- **Idle rule:** nothing fresh.
- **Stale rule:** last fresh lock mtime beyond the 300 s window.
- **Repo attribution:** session_index/rollout `cwd` fields when cheap to read; else null.
- **Notes:**
  - **There is NO `~/.codex/active_sessions.json`** — the file with that name belongs to Grok CLI. No pid registry was found for Codex.
  - Lock files may survive crashes — confidence stays `logHeartbeat`, never `exactProcess`.

### 4. `hermes` — Hermes

- **Confidence:** `exactProcess` (best signal on the machine)
- **Declared roots (read-only):**
  - `~/.hermes/gateway.pid`
  - `~/.hermes/state/gateway.heartbeat` — rewritten ~continuously
  - `~/.hermes/state/gateway.lifecycle.json`
  - `~/.hermes/gateway_state.json`
  - `~/.hermes/processes.json`
- **Signal file shapes:**

```json
// ~/.hermes/gateway.pid
{"pid": 1452, "kind": "hermes-gateway", "argv": ["…"], "start_time": 1750000000, "hermes_home": "…"}

// ~/.hermes/state/gateway.heartbeat
{"pid": 1452, "updated_at": "…", "monotonic": 0, "start_time": 1750000000}

// ~/.hermes/state/gateway.lifecycle.json
{"phase": "running"}

// ~/.hermes/gateway_state.json — keys: pid, gateway_state, platforms{…}, active_agents, updated_at
{"pid": 1452, "gateway_state": "…", "platforms": {"…": "…"}, "active_agents": 0, "updated_at": "…"}

// ~/.hermes/processes.json — [] at probe time
[]
```

- **Running rule:** gateway heartbeat fresh (< **120 s**) AND (`active_agents > 0` OR `processes.json` non-empty).
- **Idle rule:** gateway alive (live pid + fresh heartbeat) with `active_agents == 0` and empty `processes.json`.
- **Stale rule:** heartbeat beyond the 120 s window.
- **Repo attribution:** `processes.json` entries / session dirs.
- **Notes:**
  - History: `~/.hermes/sessions/` (302 dirs at verification); `~/.hermes/state.db` is a 1.1 GB SQLite — do NOT open casually.
  - **`start_time` encoding (pinned):** the real `gateway.pid` writes
    epoch-milliseconds (`178653683051`) while the real heartbeat writes
    fractional epoch-seconds (`1786536834.708521`). The probe accepts both:
    values >= 1e11 are integral epoch-milliseconds, smaller values are
    epoch-seconds (fractional allowed). Records mapping to before 2000 are
    implausible for any current process (the real gateway.pid's
    ms-in-seconds bug yields 1975) and are treated as absent — a corrupt
    record can neither resurrect a dead pid nor falsely kill a live one.
  - **Pid-reuse guard (VAL-HARD-007):** the gateway pid is verified with the
    process-start identity check before `kill -0`. The heartbeat's recorded
    `start_time` is the authoritative identity (the real heartbeat writes
    accurate epoch-seconds); when the heartbeat carries no usable
    `start_time`, `gateway.pid`'s own record is used. A reused pid whose
    current process started after the recorded start is treated as dead and
    never yields `running`/`exactProcess`.
  - **Heartbeat identity:** the heartbeat's pid must match the gateway pid
    (or be absent). A fresh heartbeat written by a DIFFERENT live process is
    not evidence for the gateway — the row degrades typed, never running.
  - **Typed stale/missing-heartbeat degradation (VAL-FLEET-023):** a live
    gateway pid with `active_agents > 0` but a stale or missing heartbeat is
    NON-running (`stale`/`activeSessionFile`) AND carries a typed
    `degraded(reason)` probeHealth state naming the stale/missing heartbeat —
    the missing corroboration is never silently healthy.
  - **Malformed `active_agents` (VAL-FLEET-024):** a `gateway_state.json`
    missing or mistyping `active_agents` (including JSON booleans, which
    must never coerce to 1) is malformed-shape: the row is typed
    `unknown`/`unsupported` with a `degraded` health reason. It is NEVER
    defaulted to zero, which would fabricate an idle/exactProcess row from
    a malformed primary signal.
  - M4 delivery channel: the gateway exposes an `api_server` platform ("connected"); `gateway_state.json.platforms.burnbar` exists ("paused: failed to reconnect" since 2026-06-24), suggesting a BurnBar integration point once existed. M4 investigates writability; if no documented writable channel exists, ship honest `unsupported` + proposal-only.

### 5. `grok-bot` — Grok Bot

- **Confidence:** `exactProcess`
- **Declared roots (read-only):**
  - `~/.grokbot/local-exec-daemon.json`
  - `~/.grokbot/local-exec-supervisor.json` — refreshed ~minutely
  - `~/.grokbot/local-exec-daemon.log`
- **Signal file shapes:**

```json
// ~/.grokbot/local-exec-daemon.json
{"pid": 4874, "startedAt": 1750000000000, "inflightCount": 0}

// ~/.grokbot/local-exec-supervisor.json
{"pid": 4869, "at": 1750000000000}
```

- **Running rule:** daemon pid live AND `inflightCount > 0`. The supervisor
  alternate (supervisor `at` fresh with recent log activity) is NOT claimed:
  the supervisor file is refreshed ~minutely by the same daemon, so a fresh
  supervisor signal alone cannot distinguish active work from a merely alive
  daemon. Claiming it would risk reporting `running` from stale evidence
  (VAL-FLEET-023).
- **Idle rule:** daemon/supervisor alive with `inflightCount == 0` — this is the common case; do NOT report "running" just because the daemon exists.
- **Stale rule:** a live daemon with a stale or absent supervisor signal stays `idle`/`unknown` — a stale/absent supervisor signal never yields `running` from stale evidence.
- **Repo attribution:** connection/workspace hints if present; else null (the declared signal files carry no workspace hints, so projectName stays null).
- **Notes:**
  - `~/.grokbot/local-exec-daemon-connection.json` contains SECRETS (tokens) — never read beyond structural keys, never log contents, never copy into fixtures (see [Honest-liveness caveats](#honest-liveness-caveats)).
  - **Pid-reuse guard (VAL-HARD-007):** every pid-bearing liveness check
    (daemon pid, supervisor pid) applies the process-start identity check
    (`isLiveProcess`) before `kill -0` — a reused pid whose current process
    started after the recorded `startedAt`/`at` is treated as dead and can
    never resurrect `running`/`exactProcess`.
  - **Typed stale/absent-supervisor degradation (VAL-FLEET-023):** a live
    daemon with `inflightCount == 0` and a stale or absent supervisor signal
    stays `idle`/`exactProcess` (the daemon is genuinely idle) BUT carries a
    typed `degraded(reason)` probeHealth state naming the stale/absent
    supervisor — the missing corroboration is never silently healthy. A
    fresh supervisor with a live pid keeps the idle row's health `ok`.

### 6. `grok-cli` — Grok CLI

- **Confidence:** `exactProcess` (downgrades to `activeSessionFile` when the pid is dead but the file is fresh)
- **Declared roots (read-only):**
  - `~/.grok/active_sessions.json` (+ `active_sessions.lock`)
  - History (M2 parser): `~/.grok/sessions/<url-encoded-project>/` (59 project dirs, ~828 entries at verification), plus `~/.grok/session_search.sqlite`
- **Signal file shape** (`~/.grok/active_sessions.json`):

```json
[
  {"session_id": "019ff37c-…", "pid": 7966, "cwd": "/Users/albertonunez", "opened_at": "2026-08-12T01:01:05Z"}
]
```

- **Running rule:** an entry with a live pid.
- **Idle rule:** file empty or absent.
- **Confidence ladder:** live pid → `exactProcess`; pid dead but file fresh → non-running with `activeSessionFile`; empty/absent file → `idle`/`unknown`.
- **Repo attribution:** `cwd` from the entry.

### 7. `pi` — Pi

- **Confidence:** `logHeartbeat`
- **Declared roots (read-only):**
  - `~/.pi/agent/sessions/<project-dir>/*.jsonl` — project dirs are `--`-encoded (`--Users-albertonunez--…`); transcripts named `2026-08-12T00-58-36-546Z_<uuid>.jsonl`
  - Config only (never a live signal): `~/.pi/agent/{models.json,settings.json,trust.json}`
- **Running rule:** newest transcript mtime fresh (< **300 s**).
- **Idle rule:** nothing fresh.
- **Stale rule:** newest transcript mtime beyond the 300 s window.
- **Repo attribution:** `--`-encoded project dir name decode (split only on `--` boundaries; single hyphens inside one path component are preserved).
- **Notes:** no pid/state file exists — confidence is `logHeartbeat` by design, never `exactProcess`.

### 8. `cursor` — Cursor (partial confidence)

- **Confidence:** `activeSessionFile` (partial)
- **Declared roots (read-only):**
  - `~/.cursor/agent-cli-state.json` — `workerIdsByDisplayName{<project @ host>: <workerId>}`
  - `~/.cursor/ai-tracking/` — mtime
- **Signal file shape** (`~/.cursor/agent-cli-state.json`):

```json
{"workerIdsByDisplayName": {"AgentLens @ albertonunez": "…workerId…"}}
```

- **Running rule:** worker ids present AND `ai-tracking/` mtime fresh (< **300 s**). There are no pids.
- **Idle/stale rule:** absent worker ids, or tracking mtime outside the documented window, is `idle`/`stale` with honest partial confidence.
- **Notes:** worker ids without pids; mtime corroboration never becomes `exactProcess`. Cursor is exactly one fixed roster/probe-health row, even when only partial evidence exists.
  - **Worker-id value validation (VAL-FLEET-024):** every
    `workerIdsByDisplayName` VALUE must be a non-empty string. A null,
    non-string, or empty value (e.g. `{"Repo": null}`) is a malformed
    primary signal: the row is typed `unknown`/`unsupported` with a
    `degraded` health reason — never `running`/`activeSessionFile` with
    healthy probeHealth, even when `ai-tracking/` is fresh. One malformed
    value degrades the whole signal (no partial rows from the valid
    entries).

### 9. `kimi` — Kimi (typed unsupported)

- **Confidence:** `unsupported`
- **Declared root (read-only):** `~/.kimi` (stale since Jul 19 at verification time)
- **Running rule:** none defined; no live signal is claimed.
- **Idle/unknown rule:** always `unknown`/`idle` with a typed `unsupported` confidence and a documented probe-plan note.
- **Notes:** present in every snapshot as a typed unsupported row — never omitted, never presented as live.

### 10. `gemini-cli` — Gemini CLI (typed unsupported)

- **Confidence:** `unsupported`
- **Declared root (read-only):** `~/.gemini` (stale since Jul 14 at verification time)
- **Running rule:** none defined; no live signal is claimed.
- **Idle/unknown rule:** always `unknown`/`idle` with a typed `unsupported` confidence and a documented probe-plan note.
- **Notes:** present in every snapshot as a typed unsupported row — never omitted, never presented as live.

### Other tools (NOT in the fixed ten-row roster)

Not installed at verification time and not part of the roster: `goose` (`~/.config/goose`), `aider`, `continue`, `zai`, `minimax`, `augment`. Unknown wire ids decode losslessly to `.unknown(String)` for forward compatibility but are not declared roster rows.

---

## Machine status primitives

- Works: `host_statistics` / `vm_statistics64` (Mach), `getloadavg`, `statfs /`, `proc_pidinfo` per known pid, `ps` corroboration.
- Thermal: `pmset -g thermlog` returned EMPTY on this Mac — report `unavailable(reason)`. Power: treat as optional/unavailable unless a cheap API proves otherwise. Values are never invented.
- Machine identity if ever needed: `~/.factory/host.json` (`hostId`, `computerId`).

---

## Out of scope

The fleet layer explicitly does NOT do any of the following. Probes and the daemon must never drift into these:

- **P3 multi-agent execution graph** — agent spawning, run graphs, and cross-agent task arbitration are deferred (TODOS.md). This mission builds the shared live board + orchestrator surface only.
- **Cloud relay / multi-machine fleet sync** — no Firestore/cloud anywhere in the fleet serving path; local-first only. No multi-machine fleets.
- **Killing or signalling processes** — the mission never kills, signals, or renicies any process. Probes are **read-only**: liveness checks use `kill -0`-style existence checks only (`kill -0` / `proc_pidinfo`). No writes, no deletes outside the daemon's own temp/support dirs.
- **`~/.factory/artifacts/`** — system-reserved; never read, traversed, or written. Any recursive manifest over `~/.factory` MUST prune it first.
- **Writing into external agent sessions** — except the approved Hermes delivery channel behind explicit human approval (M4). Claude's `/tmp/cc-socks/*.sock` messaging socket is undocumented internal IPC and is EXCLUDED.
- **Arbitrary filesystem crawling** — probes touch only the registered/declared roots listed above (injectable for tests).
- **Extension changes** — `extensions/burnbar/**` is out of scope for this mission.

---

## Honest-liveness caveats

Known traps from the verified inventory. Every one of these is a documented behavior, not a bug:

1. **Grok Bot daemon alive ≠ running.** A live `local-exec-daemon.json` pid with `inflightCount: 0` is `idle`, not `running`. Only `inflightCount > 0` flips the row to `running`. The supervisor-signal alternate is NOT claimed: the supervisor file is refreshed ~minutely by the same daemon, so a fresh supervisor signal cannot distinguish active work from a merely alive daemon, and a stale/absent supervisor signal never yields `running` from stale evidence.
2. **Secrets in `~/.grokbot/local-exec-daemon-connection.json`.** This file bears tokens. It must never be parsed beyond structural keys, never logged, and never copied into fixtures, payloads, or snapshots. Fixtures for Grok Bot contain only synthetic content.
3. **Codex has NO `active_sessions.json`.** The file with that name belongs to Grok CLI (`~/.grok/active_sessions.json`). Codex has no pid registry; do not look for one.
4. **Codex locks may survive crashes.** Thread-writer lock mtimes are a heuristic; confidence stays `logHeartbeat` even when a lock looks fresh, and `ps` corroboration is used when available.
5. **Kimi and Gemini CLI have no live signal.** Their roots were stale (Jul) at verification; they must stay typed `unsupported` rows — never coerced into `running` or omitted.
6. **Log-mtime limits.** mtime-based signals (codex, pi, cursor) cannot distinguish real activity from a file touch, and cannot prove a process is alive. Confidence is capped at `logHeartbeat` (codex, pi) or `activeSessionFile` (cursor) — never `exactProcess`.
7. **Pid-reuse guard.** `kill -0` alone can be fooled by pid reuse after a reboot. Stale pid files after reboot are detected by comparing the file's `startedAt` to the process start time; a pid whose start time predates the file is treated as dead.
8. **Thermal unavailability.** `pmset -g thermlog` is empty on this machine; `thermal`/`power` are reported as `unavailable(reason)` — never invented numbers.
9. **Never fabricate liveness.** Every uncertain state is typed (`unknown`/`stale`/`unsupported`/`unavailable(reason)`/`degraded(reason)`). A row is `running` only when a documented running rule is satisfied by real evidence.

---

## Usage parsers (M2, implemented)

The app-side usage parsers (`PiParser`, `GrokCLIParser`) read the same declared
history roots as the probes, with the same root-injection seam
(`BURNBAR_FLEET_ROOT_PI` / `BURNBAR_FLEET_ROOT_GROK_CLI` per-probe overrides,
`BURNBAR_FLEET_ROOTS_DIR` base override; both point at the agent ROOT, the
parser appends `agent/sessions` / `sessions`). They are registered in
`UsageAggregator.parsers`; Grok Bot's usage parser is an honest empty no-op
(live-signal-only provider, VAL-PROV-008).

### Generic hermetic seam (M2 repair, aggregator-refreshall-proof)

A full `UsageAggregator.refreshAll()` is hermetic when constructed with the
generic injection seam (all defaults preserve the real-root behavior):

- **`ParserRootResolver`** (`AgentLens/Services/LogParser/ParserRootResolver.swift`)
  resolves EVERY registered parser's root through the same override seam the
  daemon probes use: `BURNBAR_FLEET_ROOTS_DIR` maps each provider to
  `<override>/<root-name>` (`claude`, `factory`, `copilot`, `aider`, `cursor`,
  `codex`, `kimi`, `cline`, `kilocode`, `roocode`, `forge`, `augment`,
  `hermes`, `grokbot`, `grok`, `pi`, `gemini`, `goose`; `zai`/`minimax` share
  the `factory` root), and per-provider `BURNBAR_FLEET_ROOT_<PROVIDER>` wins
  over the base. `~`-relative paths expand under the override root; a path
  that merely shares a prefix with the root (e.g. `~/.forge.db`) is not
  stripped. The live process environment is consulted via `getenv` at
  resolution time; an explicitly passed `environment` dictionary wins.
- **`UsageAggregator(appPaths:environment:)`** — `appPaths` redirects every
  parser cache (claude/factory/codex/model-filter) and the quota snapshots
  into the injected app-support dir; `environment` is passed to every
  registered parser (GooseParser's `GOOSE_PATH_ROOT` override included).
- **Quota hermeticity:** the quota service must be injected with a
  `TestKeychainBackend` key store (the real keychain holds a minimax key),
  an empty `environment` (the live env has `ZAI_API_KEY`), a failing URL
  session, `.payAsYouGo` minimax mode, and a temp home (no real `~/.claude`
  reads).
- **Sweep gating:** the summary sweep is gated off
  (`conversationIndexingEnabled`/`autoSessionSummariesEnabled` false) so no
  Ollama/cloud summarization runs; `artifactDiscoveryEnabled` stays false;
  the projection pipeline is injected with `DeterministicFakeEmbeddingProvider`
  (no OpenAI key lookup).
- **Proof:** `UsageAggregatorRefreshAllTests` runs a FULL `refreshAll()` twice
  over synthetic fixture trees (1 session per provider, 19 rows total) with
  per-provider exact row counts, zero duplicate sessionIds on the second
  refresh, and no writes outside the injected temp app-support dir
  (VAL-PROV-009/018).
- **Hermetic-boundary containment (round-2 scrutiny repair,
  hermetic-seam-containment-repair):** two escape paths are closed and proven
  by `HermeticSeamContainmentTests`:
  - `GooseParser` reads `GOOSE_PATH_ROOT` from the INJECTED environment dict
    when one is provided — the live process environment is never consulted in
    that case, and an explicit empty value in the injected dict disables the
    variable. With no injected environment the live variable is honored
    (real-root behavior preserved). Proven with a live-env decoy root whose
    database must never be scanned.
  - `CodexParser` only follows `rollout_path` values that resolve INSIDE the
    (possibly overridden) Codex root; out-of-root paths are skipped typed
    (`CodexParser.lastSkippedOutOfRootRolloutPaths`) and NEVER opened. The
    thread row still parses via the `tokens_used` fallback. Proven with a
    canary file outside the injected root whose backdated access time must
    stay unchanged and whose exact token content must never appear in the
    parsed row — at the parser level AND through a full `refreshAll()`.

### Pi transcripts (`~/.pi/agent/sessions/<project-dir>/*.jsonl`)

- **Line 1 is the authoritative session record:** `{"type":"session","version":3,"id":"<uuid>","timestamp":"…","cwd":"/Users/…"}`. The first nonblank session record is the header: it alone determines session identity (`id`), project path (`cwd`), and start time. Later session records never replace it; a transcript whose first line is not a well-formed session record (or whose header is malformed) is skipped honestly and degrades parse health. A later session header is NEVER accepted as the line-1 authority after a wrong-shaped first record (round-2 scrutiny, issue 5). The rule extends to malformed FIRST PHYSICAL BYTES: lossy-decode garbage or truncated JSON at the head of the file invalidates the transcript exactly like a wrong-shaped first record — a later well-formed session header is never accepted (round-3 scrutiny, issue 1). Only malformed lines AFTER a valid header continue.
- **Usage lines:** `{"type":"message",…,"message":{"role":"assistant","content":[…],"usage":{"input":N,"output":N,"cacheRead":N,"cacheWrite":N,"reasoning":N,"totalTokens":N,"cost":{…}}}}`. Usage primitives are validated strictly: a present-but-malformed usage field (boolean, fractional, out-of-range, non-numeric) degrades parse health instead of being silently coerced to zero; valid rows survive. A PRESENT `usage` value that is not an object (string, array, number, boolean) is wrong-typed and degrades parse health; absent and null usage remain acceptable (round-2 scrutiny, issue 1).
- **Tolerated record kinds (explicit allowlist):** `session`, `model_change`, `thinking_level_change`, `message`. Any other top-level record kind (e.g. `{"type":"bogus"}`) is unknown input and degrades the typed parse health — it is never silently accepted. New record kinds must be added to the allowlist deliberately (round-2 scrutiny, issue 2).
- **Model:** `message.model` on assistant lines, falling back to `model_change.modelId` events.
- **Project name (REAL ENCODING, verified 2026-08-12):** session dirs are
  `--` + `-`-joined path components + `--` (e.g.
  `--Users-albertonunez-Documents-Developer-imaginethat-llc--`), which is
  ambiguous for hyphenated components. The transcript line-1 `cwd` field is
  the AUTHORITATIVE project path when present; the `--`-boundary slug decode
  (split only on `--`, single hyphens preserved, components percent-decoded)
  is the fallback. The M1 probe implements the same split rule for repo
  attribution; the M2 parser prefers `cwd` per the M1 probe worker's note.
- **Timestamps:** ISO-8601 with optional fractional seconds and optional
  non-UTC offsets; a session with no parseable timestamps is skipped
  honestly (never epoch-zero).
- **Parse health:** each parser exposes `lastParseHealth`
  (`itemsScanned/itemsParsed/itemsSkipped/malformedLines`); malformed lines
  degrade the parse without dropping valid rows. Empty and zero-byte files
  are silent no-ops.

### Grok CLI sessions (`~/.grok/sessions/<url-encoded-project>/`)

- **Usage source priority:** `updates.jsonl` `turn_completed` frames
  (`params.update.usage.inputTokens/outputTokens/cachedReadTokens`), then
  `events.jsonl` `turn_ended` frames with a `usage` object. Real sessions
  verified 2026-08-12 carry usage only in `updates.jsonl`. Wrong-shape
  lines (valid JSON without the expected frame shape) and present-but-
  malformed usage fields degrade parse health; a `turn_completed`/`turn_ended`
  frame without a usage object is a legitimate variant (cancelled/error
  turns carry no usage) and is not malformed. A `turn_completed` frame must
  carry string `prompt_id` and string `stop_reason` fields (present in
  every real session); a bare or wrong-typed frame is malformed. A
  `turn_ended` frame must carry a string `outcome` field (round-3
  scrutiny, issue 2).
- **Events allowlist (explicit):** `events.jsonl` non-usage event kinds are
  `mcp_config_resolved`, `turn_started`, `loop_started`, `first_token`
  (verified 2026-08-12). Any other event kind (e.g. `{"type":"bogus"}`) is
  unknown input and degrades the typed parse health — never silently
  accepted. A known event kind carrying a present-but-wrong-typed `usage`
  value is also malformed (round-2 scrutiny, issue 3). The allowlist is
  NAME-AND-SHAPE: every allowlisted event validates its required fields
  and primitive types — `mcp_config_resolved` requires `servers`/`disabled`
  arrays; `turn_started` requires string `session_id`, integer
  `turn_number`, string `model_id`, boolean `yolo_mode`, integer
  `conversation_message_count`, string `session_relationship`, and
  `schema_version` (string or integer — real sessions carry both `"1.0"`
  and `1`); `loop_started` requires integer `loop_index`; `first_token`
  has no required fields. An allowlisted NAME with a malformed payload
  (missing required fields, wrong primitive types, JSON booleans in
  integer fields) degrades the typed parse health (round-3 scrutiny,
  issue 2).
- **Secondary-stream health:** when `updates.jsonl` supplies usage,
  `events.jsonl` is STILL scanned for malformed-shape health WITHOUT
  double-counting its usage frames — malformed secondary events are never
  invisible in the normal two-file session layout (round-3 scrutiny,
  issue 3).
- **Chat content strictness:** a `chat_history.jsonl` line with a PRESENT
  wrong-typed `content` value (number, boolean, object, non-part array) is
  malformed and degrades parse health — never silently skipped. Absent and
  null content remain legitimate (tool results, reasoning) and are not
  malformed (round-2 scrutiny, issue 4). Every DICTIONARY part must match
  the documented text-part shape (`{"type":"text","text":…}`): a part
  without a string `text` field (image-only parts, arbitrary-key
  dictionaries) is malformed and degrades parse health — never silently
  dropped (round-3 scrutiny, issue 4).
- **Numeric update timestamps** (`updates.jsonl` `timestamp`, epoch seconds)
  are validated for positivity and finiteness; a present-but-invalid
  numeric timestamp (zero, negative, boolean, non-numeric) degrades the
  session honestly and never emits an epoch-zero row.
- **Session metadata:** `summary.json` (`info.id`, `info.cwd`,
  `current_model_id`, `created_at`, `updated_at`); `cwd` is authoritative
  over the URL-decoded dir name.
- **Project names** are URL-decoded from the session dir name
  (`%2FUsers%2Falbertonunez` → `/Users/albertonunez`); percent-escapes and
  non-ASCII names decode exactly. The real agent double-encodes spaces in
  project dirs (`My%2520App` → `My App`), so the fallback decoder repeats
  percent-decoding until stable with a bounded safe loop (max 8 passes;
  each pass strictly shrinks the string, and a pass that fails to decode
  keeps the last successfully decoded form).
- **Timestamps:** ISO-8601 with optional fractional seconds; sessions with no
  parseable timestamps are skipped honestly (never epoch-zero).
- **Parse health:** same `lastParseHealth` surface as PiParser.

### Fixture etiquette (binding for parser fixtures)

- Fixtures under `AgentLensTests/Fixtures/pi` and `AgentLensTests/Fixtures/grok`
  contain only synthetic token/usage content. No fixture is derived from
  `local-exec-daemon-connection.json` or any credential-bearing file; no
  real token/secret-shaped values are committed (VAL-PROV-012).

---

## Probe etiquette (binding)

- Read-only everything; `kill -0` / `proc_pidinfo` for liveness; no signals, no writes, no deletes outside your own temp dirs.
- Reject SECRET-bearing files (connection/credential/auth JSON) from any parsing beyond structural keys; never write their contents to fixtures, logs, or snapshots.
- Roots are injectable for hermetic tests (probe-root override seam); real roots are used only for read-only smoke checks.
- Every declared agent appears exactly once in `agents[]` and `probeHealth[]`, even when absent/unsupported.
