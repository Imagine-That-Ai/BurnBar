# The Castle

The Castle is OpenBurnBar's multi-runtime worker fan-out layer. The Ministry
still ranks candidates; Castle widens the candidate identity from `model` to
`(runtime, model)` and adapts each selected worker to the native CLI that can run
it headlessly.

## Success Gate

A Castle worker is successful only when all three conditions are true:

1. The wrapper wrote the `.done` sentinel.
2. The runtime-specific completion parser reports `isError == false`.
3. The worker worktree `HEAD` differs from the recorded base SHA.

The gate intentionally ignores plain process exit and generic "completed"
states. A no-op worker can finish cleanly and still remain non-landed. This is
the only source of truth for dashboard landed counts.

## Runtime Adapters

`tools/openburnbar-mcp/castle.py` owns the adapter registry. Each adapter
provides:

- candidate enumeration with a normalized `runtime` and `catalog_id`
- local install/auth preconditions
- native model argument resolution
- headless command construction
- runtime-specific completion parsing
- worktree scratch isolation through `.git/info/exclude`

Adapters currently cover `droid`, `codex`, `claude`, `gemini`, `opencode`,
`cursor-agent`, `kimi`, and `pi`. New adapters should be added behind the same
probe gate before they are considered launchable.

## Status Channel

Worker wrappers write prompt/result/done/stderr/status sentinels under
`~/Library/Application Support/OpenBurnBar/castle/runs/<run-id>/` by default.
`status.json` uses `CastleWorkerStatus` from OpenBurnBarCore and includes the
runtime, model argument, house label, phase, honesty flags, landed verdict,
commit SHA, and timestamp.

AgentLens reads the channel through `CastleStatusReader`. It returns both valid
records and unreadable-record failures so the Great Hall never silently hides a
bad status file. The reader discovers recent records from the default run
directory, or reads exact paths from `OPENBURNBAR_CASTLE_STATUS_PATHS`.

## Great Hall

`CastleGreatHallView` is the macOS dashboard surface for Castle fan-out. It uses
shared Core crest primitives, AgentLens color tokens, and the status channel
above. Its honesty rules are:

- landed workers are the only green/success state
- no-op workers remain neutral and do not increment landed counts
- failed or demoted workers are dimmed, not presented as success
- quota-unknown workers use a dashed ring
- unreadable status files surface as failures instead of disappearing

## Verification Checklist

Before calling Castle launch-ready, run:

```bash
tools/openburnbar-mcp/.venv/bin/python -m pytest tools/openburnbar-mcp/tests -q
python3 -m py_compile tools/openburnbar-mcp/ministry.py tools/openburnbar-mcp/castle.py tools/openburnbar-mcp/server.py
xcodegen generate --spec project.yml
xcodebuild -scheme OpenBurnBar -destination 'platform=macOS' -configuration Debug build
xcodebuild test -scheme OpenBurnBar -destination 'platform=macOS' -configuration Debug -only-testing:OpenBurnBarTests/CastleStatusReaderTests
```

For full release readiness, also prove a live N=3 selector fan-out across at
least three Houses with `prove_headless=true`, then verify each landed commit's
tree contains only intended task files.
