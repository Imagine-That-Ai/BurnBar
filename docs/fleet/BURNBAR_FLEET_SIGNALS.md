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
- **Running rule:** a non-terminal invocation with `updatedAt` fresh (< **300 s**), OR a live background-process entry, OR a session-dir mtime fresh (< **300 s**).
- **Idle rule:** roots present, nothing fresh.
- **Stale rule:** last fresh signal beyond the 300 s window.
- **Repo attribution:** invocation `cwd`, or session-dir slug decode (`-Users-albertonunez-…` → `/Users/albertonunez/…`).
- **Notes:** no pid registry; confidence is `activeSessionFile` by design — never `exactProcess`.

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

- **Running rule:** daemon pid live AND `inflightCount > 0` (or supervisor `at` fresh (< **120 s**) with recent log activity).
- **Idle rule:** daemon/supervisor alive with `inflightCount == 0` — this is the common case; do NOT report "running" just because the daemon exists.
- **Stale rule:** supervisor signal beyond the 120 s window.
- **Repo attribution:** connection/workspace hints if present; else null.
- **Notes:**
  - `~/.grokbot/local-exec-daemon-connection.json` contains SECRETS (tokens) — never read beyond structural keys, never log contents, never copy into fixtures (see [Honest-liveness caveats](#honest-liveness-caveats)).

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

1. **Grok Bot daemon alive ≠ running.** A live `local-exec-daemon.json` pid with `inflightCount: 0` is `idle`, not `running`. Only `inflightCount > 0` (or the fresh-supervisor/recent-log alternate) flips the row to `running`.
2. **Secrets in `~/.grokbot/local-exec-daemon-connection.json`.** This file bears tokens. It must never be parsed beyond structural keys, never logged, and never copied into fixtures, payloads, or snapshots. Fixtures for Grok Bot contain only synthetic content.
3. **Codex has NO `active_sessions.json`.** The file with that name belongs to Grok CLI (`~/.grok/active_sessions.json`). Codex has no pid registry; do not look for one.
4. **Codex locks may survive crashes.** Thread-writer lock mtimes are a heuristic; confidence stays `logHeartbeat` even when a lock looks fresh, and `ps` corroboration is used when available.
5. **Kimi and Gemini CLI have no live signal.** Their roots were stale (Jul) at verification; they must stay typed `unsupported` rows — never coerced into `running` or omitted.
6. **Log-mtime limits.** mtime-based signals (codex, pi, cursor) cannot distinguish real activity from a file touch, and cannot prove a process is alive. Confidence is capped at `logHeartbeat` (codex, pi) or `activeSessionFile` (cursor) — never `exactProcess`.
7. **Pid-reuse guard.** `kill -0` alone can be fooled by pid reuse after a reboot. Stale pid files after reboot are detected by comparing the file's `startedAt` to the process start time; a pid whose start time predates the file is treated as dead.
8. **Thermal unavailability.** `pmset -g thermlog` is empty on this machine; `thermal`/`power` are reported as `unavailable(reason)` — never invented numbers.
9. **Never fabricate liveness.** Every uncertain state is typed (`unknown`/`stale`/`unsupported`/`unavailable(reason)`/`degraded(reason)`). A row is `running` only when a documented running rule is satisfied by real evidence.

---

## Probe etiquette (binding)

- Read-only everything; `kill -0` / `proc_pidinfo` for liveness; no signals, no writes, no deletes outside your own temp dirs.
- Reject SECRET-bearing files (connection/credential/auth JSON) from any parsing beyond structural keys; never write their contents to fixtures, logs, or snapshots.
- Roots are injectable for hermetic tests (probe-root override seam); real roots are used only for read-only smoke checks.
- Every declared agent appears exactly once in `agents[]` and `probeHealth[]`, even when absent/unsupported.
