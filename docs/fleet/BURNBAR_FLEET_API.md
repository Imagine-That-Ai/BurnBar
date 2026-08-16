# BurnBar Fleet API

This is the local, agent-readable contract for BurnBar's live fleet
projection. It describes both read surfaces:

1. `daemon.fleet.snapshot`, a versioned one-shot JSON-RPC method over a Unix
   domain socket; and
2. `fleet-snapshot.json`, an atomically replaced file containing the raw
   snapshot.

The daemon is local-only. Fleet reads do not use Firebase, Firestore, a cloud
relay, or a multi-machine transport. The daemon is the control plane; clients
must not read agent roots to reconstruct or supplement a snapshot. The
per-agent signal paths and freshness rules are in
[`BURNBAR_FLEET_SIGNALS.md`](./BURNBAR_FLEET_SIGNALS.md).

## Socket address and transport

### Default path and overrides

The default socket is:

```text
~/Library/Application Support/BurnBar/burnbar-daemon.sock
```

The path is resolved as follows:

1. `BurnBarDaemon --socket-path PATH` wins when supplied.
2. Otherwise `BURNBAR_DAEMON_SOCKET_PATH` is used when non-empty. An empty
   value is treated as unset, so shell, Python, and the daemon executable all
   fall back to the support-directory-derived socket.
3. Otherwise the daemon uses
   `<support-directory>/burnbar-daemon.sock`.

The default support directory is
`~/Library/Application Support/BurnBar`. Setting
`BURNBAR_DAEMON_SUPPORT_DIR=/path/to/support` changes the default support
directory, and therefore changes the default socket, `fleet.sqlite`, and
`fleet-snapshot.json` paths together. A command-line `--socket-path` can point
somewhere else without moving the fleet files.

The examples below use this shell convention. It is intentional: a harness
may substitute `BURNBAR_DAEMON_SOCKET_PATH`, or redirect
`BURNBAR_DAEMON_SUPPORT_DIR` and let the default socket follow that directory,
without editing the example. Do not put `~` inside quotes and expect the shell
to expand it.

```sh
SUPPORT="${BURNBAR_DAEMON_SUPPORT_DIR:-${HOME}/Library/Application Support/BurnBar}"
SOCK="${BURNBAR_DAEMON_SOCKET_PATH:-${SUPPORT}/burnbar-daemon.sock}"
```

The daemon creates a local Unix socket, not a TCP listener. The transport is
one-shot:

```text
one connection → one newline-terminated request → one newline-terminated response → clean close
```

A client must open a new connection for a second request. Connections that
send no request do not block other clients. The request frame is raw UTF-8,
must be no more than 65,536 bytes excluding its trailing newline, and the
response is one JSON line. Reads are safe for multiple clients.

The socket is created with owner-only POSIX mode `0600` (and is owned by the
invoking user). Group and world access are never granted, regardless of the
process umask. Same-user AF_UNIX clients can use the documented read examples
below; other users are denied by the operating system.

## Protocol version and envelopes

`BurnBarProtocolVersion.current` is **1** and the daemon supports `[1]`.
Fleet methods are additive and do not require a protocol-version bump. A
request may omit `protocolVersion`, which means version 1 for compatibility
with older clients. A client that sends `protocolVersion` must send `1`.
The daemon never silently interprets a declared unsupported version as v1.

### Snapshot request

`daemon.fleet.snapshot` takes no required parameters. The smallest valid
request is:

```json
{"id":"fleet-read-1","method":"daemon.fleet.snapshot"}
```

An empty `params` object is harmless for this method, but consumers should
omit it. A request with a declared version is also valid:

```json
{"id":"fleet-read-2","method":"daemon.fleet.snapshot","protocolVersion":1}
```

`id` is a required string and is echoed exactly. `method` is the exact wire
string above. Request `protocolVersion` is optional and is not the same field
as the response version.

### Snapshot response

On success, the response is a standard
`BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>`:

```json
{
  "id": "fleet-read-1",
  "protocolVersion": 1,
  "result": {
    "snapshot": {
      "schemaVersion": 1,
      "generatedAt": "2026-08-15T12:00:00.000Z",
      "cadenceSeconds": 15,
      "machine": {},
      "agents": [],
      "repos": [],
      "runningCount": 0,
      "countsByAgent": {},
      "orchestrator": {},
      "probeHealth": [],
      "persistenceHealth": {}
    }
  }
}
```

The abbreviated objects above are only to show envelope nesting. The complete
snapshot schema is specified in [Snapshot schema](#snapshot-schema) below.
The file surface contains the inner `snapshot` object directly, without the
`id`, `protocolVersion`, or `result` wrapper.

### Typed error responses

Errors use the same response envelope. `result` is absent/null and `error` is
an object with all three fields, including the always-present,
machine-actionable, non-secret `details` string:

```json
{
  "id": "fleet-read-1",
  "protocolVersion": 1,
  "error": {
    "code": -32603,
    "message": "BurnBar fleet snapshot is not ready yet: the first probe tick has not completed. Retry shortly.",
    "details": "state=not_ready; retry_after=first_tick"
  }
}
```

The supported transport error matrix is:

| Input or condition | Code | Required behavior |
| --- | ---: | --- |
| Bytes are not valid JSON | `-32700` (`parseError`) | Return a typed error; use `id: "no-id"` when an id cannot be recovered. |
| Valid JSON but not a request object, or missing/wrong-typed `id`/`method` | `-32600` (`invalidRequest`) | Return the expected-envelope details; use `"no-id"` when needed. JSON fragments (`null`, number, string, boolean) are in this row. |
| Unknown method | `-32601` (`methodNotFound`) | Return `details: "method=<wire method>"`. |
| `params` has the wrong type for a method that declares object parameters | `-32602` (`invalidParams`) | Return expected/received type details; do not partially apply a mutation. |
| `daemon.fleet.snapshot` has a `params` value | Success or the normal snapshot result | Snapshot uses the plain envelope and ignores an omitted, object, or other JSON `params` value; consumers should omit it. |
| Daemon-side failure, including snapshot before its first tick | `-32603` (`internalError`) | Return a typed reason. Pre-first-tick snapshot reads use `state=not_ready; retry_after=first_tick`. |
| Declared `protocolVersion` is not supported | `-32001` (`protocolVersionMismatch`) | Return `declared_version=<n>; supported_versions=[1]`; never silently downgrade. |
| Request payload is larger than 65,536 raw UTF-8 bytes | `-32002` (`frameTooLarge`) | Count bytes excluding the newline and return the received byte count. |

Every error response carries `protocolVersion: 1`, the recoverable request
id, no successful `result`, and `error.code`, `error.message`, and
`error.details`. The `"no-id"` value is a daemon-defined correlation
sentinel, not a client id.

## Runnable examples

These examples are intentionally self-contained. Set
`BURNBAR_DAEMON_SOCKET_PATH` to use an overridden socket, or set
`BURNBAR_DAEMON_SUPPORT_DIR` and leave the socket override unset to use
`<support-directory>/burnbar-daemon.sock`. A hermetic daemon can instead be
started with `--socket-path "$TMPD/test.sock"` and
`BURNBAR_DAEMON_SOCKET_PATH="$TMPD/test.sock"` exported to the examples. The
daemon's first fleet tick starts immediately, but the examples retry the typed
pre-first-tick response so they are safe at cold start.

### `nc -U` snapshot read

```sh
SUPPORT="${BURNBAR_DAEMON_SUPPORT_DIR:-${HOME}/Library/Application Support/BurnBar}"
SOCK="${BURNBAR_DAEMON_SOCKET_PATH:-${SUPPORT}/burnbar-daemon.sock}"
response=
for _ in $(seq 1 40); do
  response="$(printf '%s\n' '{"id":"fleet-doc-nc","method":"daemon.fleet.snapshot"}' | nc -U "$SOCK" 2>/dev/null || true)"
  if printf '%s' "$response" | grep -q '"result"'; then
    printf '%s\n' "$response"
    exit 0
  fi
  sleep 0.05
done
printf '%s\n' "$response" >&2
exit 1
```

The successful stdout line is a JSON response envelope. `jq
'.result.snapshot.runningCount'` can extract the running count.

### Python 3 AF_UNIX snapshot read

```sh
python3 - <<'PY'
import json
import os
import socket
import time

support = os.environ.get(
    "BURNBAR_DAEMON_SUPPORT_DIR",
    os.path.join(
        os.path.expanduser("~"),
        "Library",
        "Application Support",
        "BurnBar",
    ),
)
socket_override = os.environ.get("BURNBAR_DAEMON_SOCKET_PATH")
SOCK = socket_override or os.path.join(support, "burnbar-daemon.sock")
REQUEST = b'{"id":"fleet-doc-python","method":"daemon.fleet.snapshot"}\n'

def read_once():
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2.0)
    try:
        client.connect(SOCK)
        client.sendall(REQUEST)
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b"".join(chunks))
    finally:
        client.close()

for _ in range(40):
    response = read_once()
    if "result" in response:
        if response.get("protocolVersion") != 1:
            raise SystemExit("unexpected protocolVersion")
        print(json.dumps(response, sort_keys=True))
        break
    error = response.get("error", {})
    if error.get("code") != -32603 or "not ready" not in error.get("message", ""):
        raise SystemExit(json.dumps(response, sort_keys=True))
    time.sleep(0.05)
else:
    raise SystemExit("fleet snapshot did not become ready")
PY
```

### Read the well-known file

The following is a file-only read. `BURNBAR_FLEET_SNAPSHOT_PATH` is a
**consumer-side convenience override**; it is not a daemon configuration
variable. Without it, the consumer looks under
`BURNBAR_DAEMON_SUPPORT_DIR` when set, then under the default support
directory.

```sh
SNAPSHOT="${BURNBAR_FLEET_SNAPSHOT_PATH:-${BURNBAR_DAEMON_SUPPORT_DIR:-${HOME}/Library/Application Support/BurnBar}/fleet-snapshot.json}"
jq '{schemaVersion, generatedAt, cadenceSeconds, runningCount, persistenceHealth}' "$SNAPSHOT"
```

After the first successful tick this command prints valid JSON. On a fresh
support directory, before that tick, the documented state is absence, not an
empty placeholder. If the daemon is restarted with an existing support
directory, the prior last-good file remains in place and this command can read
that stale generation until the new daemon completes its first tick.

## Well-known file

### Path and raw format

The default path is:

```text
~/Library/Application Support/BurnBar/fleet-snapshot.json
```

With `BURNBAR_DAEMON_SUPPORT_DIR=/tmp/burnbar/support`, it is:

```text
/tmp/burnbar/support/fleet-snapshot.json
```

The file is the raw `BurnBarFleetSnapshot` object. It is **not** an RPC
response envelope:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-08-15T12:00:00.000Z",
  "cadenceSeconds": 15,
  "machine": {},
  "agents": [],
  "repos": [],
  "runningCount": 0,
  "countsByAgent": {},
  "orchestrator": {},
  "probeHealth": [],
  "persistenceHealth": {}
}
```

The object above is a shape reminder; every field and nested object is
defined below.

### Refresh and atomicity

- The default cadence is 15 seconds. `BURNBAR_FLEET_CADENCE_SECONDS` accepts
  an integer of at least 1; invalid or smaller values use 15. The value is
  both the ticker interval and the snapshot's `cadenceSeconds`.
- The ticker anchors deadlines to a monotonic clock, so build time does not
  accumulate drift. For an override `C` seconds, validators use
  `tolerance(C) = max(0.5 seconds, 2 seconds × C / 15 seconds)`;
  each interval is expected in `[C - tolerance(C), C + tolerance(C)]`, and
  end-to-end drift over the run is bounded by the same tolerance. Thus the
  default 15-second cadence is bounded to 13–17 seconds over 20 ticks.
- The first build starts immediately after daemon startup. On a **fresh**
  support directory, no file is created before the first successful snapshot
  build.
- Each completed build writes `fleet-snapshot.json.tmp` and then atomically
  renames it to `fleet-snapshot.json`. The temporary file is removed on
  failure and does not remain after a completed write.
- A reader during the short `rename(2)` replacement window sees either the
  preceding complete JSON document or the new complete JSON document. It
  never sees a partial document and, after the first tick, never sees an
  absent file because of the replace.
- Under healthy persistence, the RPC and file expose the same **last
  completed generation**, including `generatedAt` and `persistenceHealth`.
  There is no intentional full-tick file lag. Compare the file after the
  completed-tick response barrier, not while the rename is in flight.
- If the file writer fails, the last-good file remains byte-identical and
  stops advancing. The RPC continues serving the current completed
  generation with `persistenceHealth.kind == "degraded"` and a non-empty
  reason. This is the explicit typed exception to normal file/RPC parity.
- If the SQLite write fails, the RPC and file carry the current generation and
  degraded health; the latest `fleet_snapshots` row remains the previous
  successful row. A subsequent successful persist can clear the degradation.

### Daemon down and pre-first-tick behavior

Stopping the daemon does not delete the file. The last snapshot remains
readable and valid, but its mtime and contents stop changing. On restart, the
daemon also preserves that last-good file while the new service is in its
pre-first-tick `notReady` window. A file that exists during that window is
therefore a stale previous generation, not proof that the restarted daemon has
completed a tick. Consumers must evaluate `generatedAt` against their
freshness policy and must not claim that the daemon is still probing from the
file alone.

For this API's consumer policy, a snapshot is `fresh` while
`now - generatedAt <= 2 * cadenceSeconds` and `stale` only when the strict
`>` comparison is true. This uses the snapshot's own reported cadence, not a
hardcoded 15-second default. The embedded consumer below reports this
classification in its `result.freshness` annotation; callers using only the
raw file or daemon RPC must apply the same comparison themselves.

Before the first successful build, `fleet-snapshot.json` is absent **only for
a fresh support directory**. The snapshot RPC in the same window returns a
typed `-32603` `internalError` with
`details: "state=not_ready; retry_after=first_tick"`. It never returns a
fabricated all-idle snapshot. A client should retry the RPC or, for a fresh
support directory, wait for the file to appear.

## Snapshot schema

The schema version of this document is **1**. The top-level snapshot has the
following fields:

| Field | JSON type | Required | Meaning |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | Exactly `1` for this contract. |
| `generatedAt` | ISO-8601 UTC string | yes | Time at which this generation was built. |
| `cadenceSeconds` | positive integer | yes | Configured ticker interval, normally 15 or the cadence override. |
| `machine` | object | yes | Host resource and sensor status. |
| `agents` | array of objects | yes | One row for each current declared roster id; the daemon emits exactly ten rows. |
| `repos` | array of objects | yes | Derived groups for non-empty `projectName` values. |
| `runningCount` | integer | yes | Number of rows whose `status` is `running`. |
| `countsByAgent` | object of string → integer | yes | Running count per wire id. Current daemon output includes every row, with `0` or `1`. |
| `orchestrator` | object | yes | Daemon-owned designation and pending-directive count. |
| `probeHealth` | array of objects | yes | One typed health entry for each current declared roster id. |
| `persistenceHealth` | object | yes | Combined health of `fleet.sqlite` and the file writer. |

Unknown top-level keys are additive extensions and must be ignored by a v1
consumer. Unknown required fields or wrong types are not additive and should
be reported as a malformed snapshot. A v1 consumer must reject
`schemaVersion: 2` (the Swift contract error is
`incompatibleSchemaVersion(found:supported:)`) rather than silently
interpreting it as v1.

### Agent identity

The current daemon roster is exactly these ten wire ids. Each appears once in
both `agents` and `probeHealth`, including when its root is missing:

```text
claude-code
factory-droid
codex
hermes
grok-bot
grok-cli
pi
cursor
kimi
gemini-cli
```

The contract also has a lossless forward-compatible identity form: any
string outside this list is an **unknown agent id**. A consumer
must preserve an unknown id such as `"aider"` and must not map it to a
known provider or drop its row. The current daemon does not add unknown ids
to its fixed roster, but a future additive producer may.

### Agent row

Every `agents[]` item is an object with these fields:

| Field | JSON type | Required | Optionality and meaning |
| --- | --- | --- | --- |
| `id` | string | yes | One roster id, or an unknown id preserved verbatim. |
| `displayName` | string | yes | Human-readable label; do not use it as identity. |
| `status` | string | yes | Exactly `running`, `idle`, `stale`, or `unknown`. |
| `confidence` | string | yes | Exactly `exactProcess`, `activeSessionFile`, `logHeartbeat`, `estimated`, or `unsupported`. |
| `currentTask` | string | no | Omitted or `null` means unavailable. |
| `projectName` | string | no | Omitted or `null` means no project attribution. |
| `model` | string | no | Omitted or `null` means no model signal. |
| `lastActivityAt` | ISO-8601 UTC string | no | Omitted or `null` means no activity timestamp. |
| `process` | object | no | Omitted or `null` unless exact-process evidence permits a process block. |
| `signals` | array of objects | yes | Evidence trail; each source has a declared-root path. |
| `note` | string | no | Omitted or `null`; an honest caveat such as a lock-file heuristic. |

Status semantics:

- `running`: an active work signal exists now, not merely an installed
  daemon.
- `idle`: infrastructure is alive but no active work is detected.
- `stale`: a previously observed signal is beyond its freshness window.
- `unknown`: the probe cannot determine a state.

The producer's encode-side consistency guard forbids `running` with
`unsupported` or `estimated` confidence, and forbids `unknown` with
`exactProcess`. Consumers should reject those combinations as invalid fleet
truth even though the v1 decoder remains tolerant for forward compatibility.

Confidence is ordered from strongest to weakest:

```text
exactProcess > activeSessionFile > logHeartbeat > estimated > unsupported
```

The levels mean:

- `exactProcess`: a declared signal identifies a process and liveness was
  checked without signalling it.
- `activeSessionFile`: a fresh session/registry signal exists but does not
  identify an exact live process.
- `logHeartbeat`: freshness comes from a lock, transcript, log, or similar
  mtime; no pid registry is claimed.
- `estimated`: an inferred signal with weaker evidence.
- `unsupported`: no supported live signal exists.

Confidence is evidence quality, not a promise that `status` is `running`.
For example, a live Grok Bot daemon with `inflightCount: 0` is
`idle`/`exactProcess`, while Kimi and Gemini CLI are typed
`unknown`/`unsupported`.

#### `process`

When present, `process` has:

| Field | JSON type | Required | Meaning |
| --- | --- | --- | --- |
| `pid` | positive integer | yes | Process id associated with exact-process evidence. |
| `cpuPercent` | number | no | Per-process CPU sample; omitted or `null` when unavailable. |
| `memoryBytes` | integer | no | Per-process memory sample; omitted or `null` when unavailable. |
| `startedAt` | ISO-8601 UTC string | no | Process start time; omitted or `null` when unavailable. |

`process` is never fabricated for a non-exact confidence row. A consumer
should treat its optional metrics independently; absence is not zero.

#### `signals`

Each `signals[]` object has:

| Field | JSON type | Required | Meaning |
| --- | --- | --- | --- |
| `kind` | string | yes | Evidence kind, for example `session-registry`, `heartbeat-file`, `task-ledger`, `lock-file`, `log-mtime`, or `process-list`. |
| `path` | string | yes | Absolute path inside the agent's declared signal root. |
| `detail` | string | no | Omitted or `null`; non-secret diagnostic detail. |

Signal paths are provenance, not permission for a consumer to read the path.
Probes use only the registered roots and known patterns in
`BURNBAR_FLEET_SIGNALS.md`; `~/.factory/artifacts/` is excluded.

### Machine status

`machine` is an object:

| Field | JSON type | Required | Optionality and meaning |
| --- | --- | --- | --- |
| `cpuPercent` | number | no | Host CPU sample; omitted or `null` if unavailable. |
| `memoryUsedBytes` | integer | no | Used host memory; omitted or `null` if unavailable. |
| `memoryTotalBytes` | integer | yes | Total host memory reported by the machine probe. |
| `loadAverage` | array of numbers | no | Load averages; omitted or `null` if unavailable. The current macOS probe normally emits three values. |
| `diskFreeBytes` | integer | no | Free bytes for `/`; omitted or `null` if unavailable. |
| `thermal` | sensor object | yes | `available` numeric value or typed `unavailable`. |
| `power` | sensor object | yes | `available` numeric value or typed `unavailable`. |

Sensor objects are tagged objects, never bare numbers:

```json
{"kind":"available","value":42.5}
```

or:

```json
{"kind":"unavailable","reason":"pmset thermlog returned no reading"}
```

`available` requires a numeric `value`. `unavailable` requires a non-empty
`reason`. The current machine commonly reports both thermal and power as
unavailable; consumers must not invent a numeric value.

### Repositories and counts

Each `repos[]` item is:

```json
{
  "projectName": "/Users/example/Project",
  "agents": ["claude-code", "codex"]
}
```

`projectName` is a string and `agents` is an array of wire-id strings. A
group is derived from agent rows with the same non-empty `projectName`;
agents whose project is omitted/null are not placed in a group. Group order
is stable first-appearance order, but consumers must not depend on array
ordering.

`runningCount` must equal the number of `agents[]` rows with
`status == "running"`. `countsByAgent` maps wire-id strings to non-negative
integers. In the current fixed one-row-per-agent model, every row has a key
and its value is `1` exactly when that row is running, otherwise `0`;
therefore the sum of values equals `runningCount`. A forward-compatible
consumer should tolerate an omitted key for a non-running future row as
equivalent to zero, but must reject an omitted key for a running row and must
reject a mismatch for a present key. The current daemon emits all keys.

### Orchestrator state

`orchestrator` is:

| Field | JSON type | Required | Optionality and meaning |
| --- | --- | --- | --- |
| `designation` | tagged object | yes | `none`, `burnBarManaged`, or an `agent` designation. |
| `setAt` | ISO-8601 UTC string | no | Omitted or `null` when no daemon-owned set has occurred. |
| `pendingDirectives` | non-negative integer | yes | Count of directive records in `proposed` or `approved` state. |

Designation wire shapes are:

```json
{"kind":"none"}
```

```json
{"kind":"burnBarManaged"}
```

```json
{"kind":"agent","id":"hermes","sessionRef":"session-123"}
```

For `kind: "agent"`, `id` is required and is a wire id. `sessionRef` has
intentional three-way optionality:

1. omitted means no session reference field was supplied;
2. explicit `null` means the session reference was supplied as null; and
3. a string means that exact session reference.

The daemon preserves those three forms in the contract. `setAt` is daemon
stamped for accepted `orchestrator.set` requests; clients must not treat a
client-supplied timestamp as authoritative. A declared but currently
non-running agent may still be designated; designation is intent, not a
liveness claim.

`pendingDirectives` is not a count of all history. `proposed` and `approved`
count; `dismissed`, `delivered`, and `failed` do not count. The same value is
used by `orchestrator.get`, the snapshot, and the file.

### Probe health

Each `probeHealth[]` item is:

| Field | JSON type | Required | Meaning |
| --- | --- | --- | --- |
| `agent` | string | yes | The corresponding wire id. |
| `state` | tagged object | yes | `ok`, `degraded`, or `failed`. |
| `rootPath` | string | yes | The declared root used by this probe, or an empty string when no probe is registered. |
| `checkedAt` | ISO-8601 UTC string | yes | Time this probe health was checked. |

State shapes:

```json
{"kind":"ok"}
```

```json
{"kind":"degraded","reason":"heartbeat is stale"}
```

```json
{"kind":"failed","reason":"declared root is missing"}
```

`degraded` and `failed` require a non-empty, non-secret `reason`. Health
describes the probe, not persistence; file/SQLite failures belong only in
top-level `persistenceHealth`. A fixed-roster row is never removed because
its probe failed.

### Persistence health

`persistenceHealth` is always present and is one of:

```json
{"kind":"ok"}
```

```json
{"kind":"degraded","reason":"fleet-snapshot.json write failed: ..."}
```

`degraded` requires a non-empty, non-secret reason and covers both daemon
`fleet.sqlite` persistence and the atomic well-known-file writer. It is the
single persistence-health surface; do not look for store/file errors in
`probeHealth`.

The daemon-owned database path is
`<support-directory>/fleet.sqlite`. It contains the latest completed
snapshot plus bounded transition history and the M4 control tables. The
default event retention is exactly 24 hours; validators may set
`BURNBAR_FLEET_EVENT_RETENTION_SECONDS` to a positive number. Up to 240
completed snapshot payloads are retained by default.

The live projection is rebuildable from probes. If `fleet.sqlite` is corrupt,
has an incompatible/partial schema, or is deleted/replaced while the daemon is
running, the daemon closes the old handle, deletes/recreates the store, and
publishes the first recovery snapshot with
`persistenceHealth.kind == "degraded"` and a reason containing `rebuilt`.
If the store is deleted while the daemon is stopped but a last-good snapshot
file remains, startup takes the same typed rebuild path before the first tick.
Malformed persisted snapshot or orchestrator-state JSON is treated as the same
corrupt-store boundary, rather than silently becoming an empty baseline.
Compatible older v1 stores migrate in place. The rebuild degradation clears
only after the next successful persist. Deleting or rebuilding the store
discards daemon-owned orchestrator designation and directive history;
designation re-initializes to `{"kind":"none"}`. This is intentional and must
be treated as data loss for control history, not as a restored empty state.

If the support directory is read-only, the daemon still serves probe-backed
RPC snapshots. The top-level `persistenceHealth` is
`{"kind":"degraded","reason":"..."}` for the SQLite/file-writer failure;
clients must not reinterpret this as per-agent probe health. Atomic file
replacement uses a temporary path and `rename(2)`. A crash or `SIGKILL`
during a write leaves the previous complete file in place; an orphaned
temporary file is never promoted and is ignored/cleaned on the next tick.

## Dates and optionality

All fleet `Date` values are encoded as ISO-8601 UTC strings with a `Z`
suffix. Encoded values normally include fractional seconds, for example
`2026-08-15T12:00:00.000Z`. A consumer should accept both fractional and
non-fractional ISO-8601 UTC forms and should never interpret a date as an
epoch number or epoch zero.

The general rule for Swift optional fields is:

- encoding a missing value omits the JSON key;
- an explicit JSON `null` decodes as unavailable for ordinary optional
  fields; and
- a present value must have the documented type.

The following ordinary optional fields use that omitted-or-null rule:

```text
agents[].currentTask
agents[].projectName
agents[].model
agents[].lastActivityAt
agents[].process
agents[].note
agents[].process.cpuPercent
agents[].process.memoryBytes
agents[].process.startedAt
agents[].signals[].detail
machine.cpuPercent
machine.memoryUsedBytes
machine.loadAverage
machine.diskFreeBytes
orchestrator.setAt
directives[].targetAgent
directives[].decidedAt
directives[].deliveryChannel
directives[].deliveryAttemptID
```

`orchestrator.designation.sessionRef` is the exception: omitted, explicit
null, and present string are distinct wire states and must not be collapsed
when a consumer forwards or re-encodes a designation.

## Versioning and consumer policy

There are two independent version fields:

- `schemaVersion` belongs to the snapshot object and is currently `1`.
  Version 1 consumers ignore additive unknown JSON keys. They reject a
  newer schema version with a typed incompatibility result rather than
  guessing field meanings.
- `protocolVersion` belongs to RPC response envelopes and is currently `1`.
  Request declarations are optional for v1; a declared value other than `1`
  receives `-32001` with a typed error. A response with an unsupported
  protocol version must not be silently downgraded.

There is no long-lived handshake or push channel. A consumer negotiates by
supporting protocol version 1, omitting the request declaration when it wants
the compatibility default, and checking `protocolVersion` on every response.
New additive RPC methods and additive snapshot keys do not require a version
bump. A breaking change requires a new schema/protocol version and a typed
upgrade decision by the consumer.

## M4 control methods and write scope

The M4 write surface is intentionally small. The daemon supports:

- `daemon.fleet.orchestrator.get` (read): no params; result is
  `{"state":{"designation":...,"setAt":...,"pendingDirectives":...}}`.
- `daemon.fleet.orchestrator.set` (write): params are
  `{"state":{"designation":...}}`. The daemon validates the designation,
  stamps `setAt`, recomputes `pendingDirectives`, and returns the updated
  state. Setting an unrecognised agent id is rejected with a typed error and
  does not mutate stored state. Setting `none` while already `none` is a
  successful idempotent no-op.
- `daemon.fleet.directive.record` (write): params are
  `{"directive":{...}}`; result is `{"directive":{...}}`. There is no
  directive-list RPC by design. Inspect `fleet_directives` with read-only
  `sqlite3` when a history listing is required.

The copy-paste examples in this M5 consumer document are deliberately
**read-only** and exclude `orchestrator.set` and `directive.record`; those
methods are control-plane writes, not a permission grant to an arbitrary
agent. The JSON blocks below document their exact wire shapes for an
authorized BurnBar client. Any caller must obtain its own human approval and
must handle the typed validation/error response before treating a write as
accepted.

The request/response envelope for `orchestrator.get` is:

```json
{"id":"orch-get-1","method":"daemon.fleet.orchestrator.get"}
```

```json
{
  "id":"orch-get-1",
  "protocolVersion":1,
  "result":{
    "state":{
      "designation":{"kind":"none"},
      "pendingDirectives":0
    }
  }
}
```

The request/response envelope for `orchestrator.set` is:

```json
{
  "id":"orch-set-1",
  "method":"daemon.fleet.orchestrator.set",
  "params":{"state":{"designation":{"kind":"agent","id":"hermes"}}}
}
```

The daemon owns `setAt` and `pendingDirectives`; client values for those
fields are not authority.

### Directive schema and state

Although directives are not nested in a snapshot, they are part of the
documented M4 write surface. A directive has:

| Field | JSON type | Required | Optionality |
| --- | --- | --- | --- |
| `id` | non-empty string | yes | Stable idempotency key, called `directive_id` in the SQLite table. |
| `kind` | string | yes | `summarize`, `focusRepo`, `askStatus`, `suggestAssignee`, or `custom`. |
| `targetAgent` | string | no | Omitted/null or a declared roster id. |
| `payload` | non-empty string | yes | Human-approved directive content. |
| `state` | tagged object | yes | `proposed`, `approved`, `dismissed`, `delivered`, or `failed`. |
| `createdAt` | ISO-8601 UTC string | yes | Creation time. |
| `decidedAt` | ISO-8601 UTC string | no | Omitted/null until decided. |
| `deliveryChannel` | string | no | Omitted/null until a channel is selected; Branch A uses `hermes`. |
| `deliveryAttemptID` | string | no | Omitted/null until a durable external-delivery handoff is recorded. |

Non-failure states are tagged objects with only `kind`:

```json
{"kind":"proposed"}
{"kind":"approved"}
{"kind":"dismissed"}
{"kind":"delivered"}
```

Failure is:

```json
{"kind":"failed","reason":"non-empty explanation"}
```

An example record request and successful response are:

```json
{
  "id":"directive-record-1",
  "method":"daemon.fleet.directive.record",
  "params":{
    "directive":{
      "id":"directive-1",
      "kind":"askStatus",
      "targetAgent":"hermes",
      "payload":"Report the current gateway status.",
      "state":{"kind":"proposed"},
      "createdAt":"2026-08-15T12:00:00.000Z"
    }
  }
}
```

```json
{
  "id":"directive-record-1",
  "protocolVersion":1,
  "result":{
    "directive":{
      "id":"directive-1",
      "kind":"askStatus",
      "targetAgent":"hermes",
      "payload":"Report the current gateway status.",
      "state":{"kind":"proposed"},
      "createdAt":"2026-08-15T12:00:00.000Z"
    }
  }
}
```

The failure reason is required and cannot be empty or whitespace-only.
`directive.record` validates the id, payload, state reason, and target-agent
roster membership before persistence. Re-recording the same id is an
idempotent upsert, not a second record. `dismissed` and `delivered` are
immutable terminal authority. A failed record remains authoritative for
ordinary candidates; a user retry may submit a fresh `approved` record only
with a new non-empty `deliveryAttemptID` and a non-empty delivery channel.
An approved record carrying an attempt id is a durable handoff fence: later
proposed/approved candidates cannot erase it before reconciliation.

### Hermes delivery branch declaration

**Branch A is implemented: Hermes has a writable local channel.** For a
human-approved directive targeting Hermes, BurnBar sends
`POST /v1/chat/completions` to the Hermes `api_server` on loopback
(`http://127.0.0.1:8642` by default) with `Authorization: Bearer
<resolved-api-key>`. The key resolution order is
`BURNBAR_HERMES_API_KEY` first, then the `API_SERVER_KEY=` line in
`~/.hermes/.env`. `BURNBAR_HERMES_GATEWAY_URL` may override the endpoint only
to `127.0.0.1`, `localhost`, or `::1` by default. A non-loopback URL is
rejected unless `BURNBAR_HERMES_ALLOW_REMOTE=1` (the implementation also
accepts `true` or `yes`) is explicitly set. Credentials are never logged or
copied into snapshots/fixtures, and the default loopback-only rule prevents a
real key from being sent to an arbitrary endpoint.

The delivery sequence is:

1. A proposal is shown with explicit Approve and Dismiss actions. A proposal
   is not delivered before human approval.
2. Approval records `state.kind == "approved"` and a non-null `decidedAt`
   before any external request.
3. BurnBar records `deliveryChannel: "hermes"` and a unique
   `deliveryAttemptID` before handing off to the gateway.
4. Only HTTP 200 with this exact acknowledgement reaches delivered:
   `{"burnbar_delivery":{"directive_id":"<id>","status":"delivered"}}`.
5. Transport failures, non-200 responses, invalid JSON, missing/mismatched
   ids, unknown statuses, and contradictory statuses fail closed as
   `state.kind == "failed"` with a non-empty reason. They never claim
   `delivered`.
6. Dismissed directives make no channel call. A failed delivery has one
   explicit user-action retry; there is no silent retry loop. Retry preserves
   the original `decidedAt` and uses a new attempt id.
7. Agents without a documented writable channel remain `approved` and
   honest-degrade as unsupported; no side effect is attempted.

Claude's `/tmp/cc-socks/*.sock` path is undocumented internal IPC and is
never used as a delivery channel.

## From-the-doc-alone Python consumer

The following is a complete standard-library-only consumer. It deliberately
does not import BurnBar source or assume Swift types. It locates the board
from `BURNBAR_FLEET_SNAPSHOT_PATH`, then the daemon support directory, then
the default support path. If the file is absent, or if
`BURNBAR_FLEET_USE_RPC=1` / a non-empty `BURNBAR_DAEMON_SOCKET_PATH` is set,
it reads the RPC socket instead. The socket fallback derives from
`BURNBAR_DAEMON_SUPPORT_DIR` when no explicit socket override is set. It
validates every required top-level and nested field, all enum values, date
forms, aggregates, sensor variants, health reasons, the status/confidence
rule, and ordinary optionality. Unknown additive keys are ignored. A
successful run prints a response-shaped JSON object with the validated
snapshot and a `result.freshness` annotation using the strict
`generatedAt`/`2 * cadenceSeconds` policy, so it can be used as a doc-driven
smoke test as well as a standalone consumer.

For a file fixture, set `BURNBAR_FLEET_SNAPSHOT_PATH=/path/to/fixture.json`.
For an overridden daemon socket, set `BURNBAR_DAEMON_SOCKET_PATH=/path/to/test.sock`.
For a redirected default socket, set `BURNBAR_DAEMON_SUPPORT_DIR=/path/to/support`.

```sh
python3 - <<'PY'
import json
import math
import os
import socket
import time
from datetime import datetime, timezone

KNOWN_IDS = {
    "claude-code", "factory-droid", "codex", "hermes", "grok-bot",
    "grok-cli", "pi", "cursor", "kimi", "gemini-cli",
}
STATUSES = {"running", "idle", "stale", "unknown"}
CONFIDENCES = {
    "exactProcess", "activeSessionFile", "logHeartbeat", "estimated",
    "unsupported",
}
support = os.environ.get(
    "BURNBAR_DAEMON_SUPPORT_DIR",
    os.path.join(
        os.path.expanduser("~"),
        "Library",
        "Application Support",
        "BurnBar",
    ),
)
socket_override = os.environ.get("BURNBAR_DAEMON_SOCKET_PATH")
SOCK = socket_override or os.path.join(support, "burnbar-daemon.sock")


def require(condition, message):
    if not condition:
        raise SystemExit("fleet consumer validation failed: " + message)


def integer(value, field, minimum=None):
    require(type(value) is int, field + " must be an integer")
    if minimum is not None:
        require(value >= minimum, field + " is below its minimum")


def number(value, field):
    require(type(value) in (int, float) and not isinstance(value, bool), field + " must be numeric")
    require(math.isfinite(float(value)), field + " must be finite")


def iso_date(value, field):
    require(type(value) is str and value.endswith("Z"), field + " must be a Z-suffixed ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise SystemExit("fleet consumer validation failed: " + field + " is not ISO-8601") from error
    require(parsed.tzinfo is not None, field + " must carry a timezone")
    return parsed


def wire_id(value, field):
    require(type(value) is str, field + " must be a wire-id string")
    return value


def optional_string(obj, key, field):
    if key not in obj or obj[key] is None:
        return
    require(type(obj[key]) is str, field + " must be a string, null, or omitted")


def optional_number(obj, key, field):
    if key not in obj or obj[key] is None:
        return
    number(obj[key], field)


def optional_integer(obj, key, field, minimum=None):
    if key not in obj or obj[key] is None:
        return
    integer(obj[key], field, minimum)


def optional_date(obj, key, field):
    if key not in obj or obj[key] is None:
        return
    iso_date(obj[key], field)


def validate_sensor(sensor, field):
    require(type(sensor) is dict, field + " must be an object")
    kind = sensor.get("kind")
    if kind == "available":
        require("value" in sensor, field + ".value is required")
        number(sensor["value"], field + ".value")
    elif kind == "unavailable":
        require(type(sensor.get("reason")) is str and sensor["reason"].strip(), field + ".reason is required")
    else:
        raise SystemExit("fleet consumer validation failed: " + field + ".kind is unknown")


def validate_agent(row, index):
    field = "agents[" + str(index) + "]"
    require(type(row) is dict, field + " must be an object")
    aid = wire_id(row.get("id"), field + ".id")
    require(type(row.get("displayName")) is str, field + ".displayName must be a string")
    status = row.get("status")
    confidence = row.get("confidence")
    require(status in STATUSES, field + ".status is unknown")
    require(confidence in CONFIDENCES, field + ".confidence is unknown")
    require(not (status == "running" and confidence in {"unsupported", "estimated"}),
            field + " violates running/confidence consistency")
    require(not (status == "unknown" and confidence == "exactProcess"),
            field + " violates unknown/exactProcess consistency")
    optional_string(row, "currentTask", field + ".currentTask")
    optional_string(row, "projectName", field + ".projectName")
    optional_string(row, "model", field + ".model")
    optional_date(row, "lastActivityAt", field + ".lastActivityAt")
    optional_string(row, "note", field + ".note")

    if "process" in row and row["process"] is not None:
        process = row["process"]
        require(confidence == "exactProcess", field + ".process requires exactProcess confidence")
        require(type(process) is dict, field + ".process must be an object")
        integer(process.get("pid"), field + ".process.pid", 1)
        optional_number(process, "cpuPercent", field + ".process.cpuPercent")
        optional_integer(process, "memoryBytes", field + ".process.memoryBytes", 0)
        optional_date(process, "startedAt", field + ".process.startedAt")

    require(type(row.get("signals")) is list, field + ".signals must be an array")
    for source_index, source in enumerate(row["signals"]):
        source_field = field + ".signals[" + str(source_index) + "]"
        require(type(source) is dict, source_field + " must be an object")
        require(type(source.get("kind")) is str and source["kind"], source_field + ".kind is required")
        require(type(source.get("path")) is str and source["path"], source_field + ".path is required")
        optional_string(source, "detail", source_field + ".detail")
    return aid, status, row.get("projectName")


def validate_snapshot(snapshot):
    require(type(snapshot) is dict, "snapshot must be an object")
    required = {
        "schemaVersion", "generatedAt", "cadenceSeconds", "machine", "agents",
        "repos", "runningCount", "countsByAgent", "orchestrator",
        "probeHealth", "persistenceHealth",
    }
    missing = required.difference(snapshot)
    require(not missing, "missing top-level fields: " + ",".join(sorted(missing)))
    integer(snapshot["schemaVersion"], "schemaVersion")
    require(snapshot["schemaVersion"] == 1, "unsupported schemaVersion")
    iso_date(snapshot["generatedAt"], "generatedAt")
    integer(snapshot["cadenceSeconds"], "cadenceSeconds", 1)

    machine = snapshot["machine"]
    require(type(machine) is dict, "machine must be an object")
    optional_number(machine, "cpuPercent", "machine.cpuPercent")
    optional_integer(machine, "memoryUsedBytes", "machine.memoryUsedBytes", 0)
    integer(machine.get("memoryTotalBytes"), "machine.memoryTotalBytes", 0)
    if "loadAverage" in machine and machine["loadAverage"] is not None:
        require(type(machine["loadAverage"]) is list, "machine.loadAverage must be an array")
        for load_index, load in enumerate(machine["loadAverage"]):
            number(load, "machine.loadAverage[" + str(load_index) + "]")
    optional_integer(machine, "diskFreeBytes", "machine.diskFreeBytes", 0)
    validate_sensor(machine["thermal"], "machine.thermal")
    validate_sensor(machine["power"], "machine.power")

    require(type(snapshot["agents"]) is list, "agents must be an array")
    agents_by_id = {}
    running_count = 0
    project_by_id = {}
    for index, row in enumerate(snapshot["agents"]):
        aid, status, project = validate_agent(row, index)
        require(aid not in agents_by_id, "duplicate agent id " + aid)
        agents_by_id[aid] = row
        project_by_id[aid] = project
        running_count += status == "running"
    require(KNOWN_IDS.issubset(agents_by_id), "current roster id is missing")
    integer(snapshot["runningCount"], "runningCount", 0)
    require(snapshot["runningCount"] == running_count, "runningCount does not match agents")

    counts = snapshot["countsByAgent"]
    require(type(counts) is dict, "countsByAgent must be an object")
    for aid in agents_by_id:
        if aid not in counts:
            require(
                agents_by_id[aid]["status"] != "running",
                "countsByAgent is missing running agent " + aid,
            )
            continue
        integer(counts[aid], "countsByAgent[" + aid + "]", 0)
        expected = int(agents_by_id[aid]["status"] == "running")
        require(counts[aid] == expected, "countsByAgent disagrees for " + aid)
    for aid, count in counts.items():
        wire_id(aid, "countsByAgent key")
        integer(count, "countsByAgent[" + aid + "]", 0)
    require(sum(counts.values()) == snapshot["runningCount"],
            "countsByAgent sum does not match runningCount")

    require(type(snapshot["repos"]) is list, "repos must be an array")
    grouped = {}
    for index, group in enumerate(snapshot["repos"]):
        field = "repos[" + str(index) + "]"
        require(type(group) is dict, field + " must be an object")
        project = group.get("projectName")
        require(type(project) is str and project, field + ".projectName is required")
        members = group.get("agents")
        require(type(members) is list, field + ".agents must be an array")
        for member in members:
            require(member in agents_by_id, field + " refers to an unknown row")
            require(project_by_id[member] == project, field + " has a mismatched project")
        grouped[project] = set(members)
    for aid, project in project_by_id.items():
        if isinstance(project, str) and project:
            require(aid in grouped.get(project, set()), "project group omits " + aid)

    orchestrator = snapshot["orchestrator"]
    require(type(orchestrator) is dict, "orchestrator must be an object")
    designation = orchestrator.get("designation")
    require(type(designation) is dict, "orchestrator.designation must be an object")
    kind = designation.get("kind")
    require(kind in {"none", "burnBarManaged", "agent"}, "unknown designation kind")
    if kind == "agent":
        wire_id(designation.get("id"), "orchestrator.designation.id")
        if "sessionRef" in designation and designation["sessionRef"] is not None:
            require(type(designation["sessionRef"]) is str,
                    "orchestrator.designation.sessionRef must be string/null/omitted")
    optional_date(orchestrator, "setAt", "orchestrator.setAt")
    integer(orchestrator.get("pendingDirectives"), "orchestrator.pendingDirectives", 0)

    require(type(snapshot["probeHealth"]) is list, "probeHealth must be an array")
    health_ids = set()
    for index, health in enumerate(snapshot["probeHealth"]):
        field = "probeHealth[" + str(index) + "]"
        require(type(health) is dict, field + " must be an object")
        aid = wire_id(health.get("agent"), field + ".agent")
        require(aid not in health_ids, "duplicate probe health id " + aid)
        health_ids.add(aid)
        require(type(health.get("rootPath")) is str, field + ".rootPath must be a string")
        iso_date(health.get("checkedAt"), field + ".checkedAt")
        state = health.get("state")
        require(type(state) is dict, field + ".state must be an object")
        state_kind = state.get("kind")
        require(state_kind in {"ok", "degraded", "failed"}, field + ".state.kind is unknown")
        if state_kind != "ok":
            require(type(state.get("reason")) is str and state["reason"].strip(),
                    field + ".state.reason is required")
    require(KNOWN_IDS.issubset(health_ids), "current roster health id is missing")
    require(health_ids.issubset(set(agents_by_id)), "probe health has no agent row")

    persistence = snapshot["persistenceHealth"]
    require(type(persistence) is dict, "persistenceHealth must be an object")
    persistence_kind = persistence.get("kind")
    require(persistence_kind in {"ok", "degraded"}, "unknown persistenceHealth kind")
    if persistence_kind == "degraded":
        require(type(persistence.get("reason")) is str and persistence["reason"].strip(),
                "persistenceHealth.reason is required")
    return snapshot


def rpc_snapshot():
    request = b'{"id":"fleet-doc-consumer","method":"daemon.fleet.snapshot"}\n'
    for _ in range(40):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2.0)
        try:
            client.connect(SOCK)
            client.sendall(request)
            chunks = []
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            response = json.loads(b"".join(chunks))
        except (OSError, json.JSONDecodeError) as error:
            client.close()
            raise SystemExit("fleet consumer RPC read failed: " + str(error))
        finally:
            client.close()
        if "result" in response:
            require(response.get("protocolVersion") == 1, "RPC protocolVersion is not 1")
            result = response["result"]
            require(type(result) is dict and type(result.get("snapshot")) is dict,
                    "RPC result.snapshot is missing")
            return result["snapshot"]
        error = response.get("error", {})
        if error.get("code") == -32603 and "not ready" in error.get("message", ""):
            time.sleep(0.05)
            continue
        raise SystemExit("fleet consumer RPC error: " + json.dumps(response, sort_keys=True))
    raise SystemExit("fleet consumer snapshot did not become ready")


def load_snapshot():
    file_path = os.environ.get("BURNBAR_FLEET_SNAPSHOT_PATH")
    if not file_path:
        support = os.environ.get(
            "BURNBAR_DAEMON_SUPPORT_DIR",
            os.path.join(os.path.expanduser("~"), "Library", "Application Support", "BurnBar"),
        )
        file_path = os.path.join(support, "fleet-snapshot.json")
    force_rpc = os.environ.get("BURNBAR_FLEET_USE_RPC") == "1" or bool(socket_override)
    if not force_rpc and os.path.isfile(file_path):
        with open(file_path, "r", encoding="utf-8") as stream:
            return json.load(stream)
    return rpc_snapshot()


snapshot = validate_snapshot(load_snapshot())
generated_at = iso_date(snapshot["generatedAt"], "generatedAt")
age_seconds = max(
    0.0,
    (datetime.now(timezone.utc) - generated_at).total_seconds(),
)
threshold_seconds = 2 * snapshot["cadenceSeconds"]
print(json.dumps({
    "id": "fleet-doc-consumer",
    "protocolVersion": 1,
    "result": {
        "snapshot": snapshot,
        "freshness": {
            "state": "stale" if age_seconds > threshold_seconds else "fresh",
            "ageSeconds": age_seconds,
            "thresholdSeconds": threshold_seconds,
        },
    },
}, sort_keys=True, separators=(",", ":")))
PY
```

The consumer's output is a valid RPC-shaped envelope. The validation itself
fails closed on missing fields, unknown enum values, bad dates, inconsistent
aggregates, invalid sensor/health tags, or a forbidden
status/confidence combination. It accepts additive top-level and nested keys
by ignoring them, while preserving unknown agent-id strings.

## Stability and safety notes

- Reads are side-effect free. Snapshot reads, file reads, and
  `orchestrator.get` do not mutate control state.
- Probes are read-only. They use process-existence checks such as `kill -0`
  or `proc_pidinfo`; they never signal, kill, or renice an agent process.
- The fixed roster is intentionally present even for missing, malformed, or
  unsupported roots. Treat `probeHealth` and confidence as part of the
  truth, not as optional UI decoration.
- Do not parse credential-bearing files. In particular,
  `~/.grokbot/local-exec-daemon-connection.json` contains secrets and is not
  a fleet signal source.
- The API is local and single-machine. It does not promise cross-machine
  identity, remote agents, process control, spawning, execution graphs, or
  arbitration.
- The daemon's persistence is rebuildable, but rebuilding the daemon-owned
  fleet store intentionally loses orchestrator designation and directive
  history as described above.
