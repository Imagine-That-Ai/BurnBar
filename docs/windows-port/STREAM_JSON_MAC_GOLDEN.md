# Live `claude --output-format stream-json` Mac golden + parse-diff harness

**Contract:** `VAL-P0-STREAM-028` (Windows-port master plan §7.3 G0 criterion #5 —
the most product-representative G0 de-risk).
**Lane:** 🟢 macOS-now (LIVE). **Windows replay:** `VAL-P0-STREAM-029` (PENDING).

## What this delivers

A **real, authenticated** `claude --output-format stream-json` run captured on
macOS, committed verbatim, and re-parsed through the **shipped** live stream
parser to prove the `CLIBridge → stream → parser` path end-to-end — not a static
fixture, not a hand-forged stream.

| Artifact | Path | Role |
| --- | --- | --- |
| RAW stream | `AgentLensTests/Fixtures/StreamGolden/claude-stream-mac-golden.jsonl` | The verbatim NDJSON stdout of a live `claude --output-format stream-json` run (one deterministic PII redaction — see below). |
| Parsed events golden | `AgentLensTests/Fixtures/StreamGolden/claude-stream-mac-golden-events.json` | The N events the shipped parser emits, projected to the portable stream-parse contract, plus scenario + raw-histogram metadata. |
| Contract + projection | `AgentLensTests/Support/StreamParseContract.swift` | The byte-stable `StreamParseGolden` shape and the re-parse projection over `ClaudeCodeStreamJSONParser`. |
| Parse-diff test | `AgentLensTests/Active/Parsers/ClaudeStreamGoldenParseDiffTests.swift` | Re-parses the RAW golden through the shipped parser and asserts the N events match. |
| Capture script | `scripts/windows-port/capture-claude-stream-json-golden.sh` | Reproduces a fresh, canonical capture (env-stripped, redacted) end-to-end. |

The parser under test is `ClaudeCodeStreamJSONParser.events(fromLine:)` — the exact
closure `CLIProcessStreamRunner.runClaude` feeds each `stdout` line to
(`AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift`,
`AgentLens/Services/CLIBridge/CLIStreamParsers.swift`).

## The fixed scenario (for a fresh capture / Windows regeneration)

STREAM-029's primary Windows check is a **byte-replay** of the committed RAW
`.jsonl` through the Windows stream parser port — deterministic regardless of
environment, because it never re-runs the CLI. This section is only for
*regenerating* the raw bytes should that ever be wanted (e.g. a real Windows-side
capture to cross-check the replay).

**Marker-file scenario** — chosen because it *forces* exactly one tool round-trip:
the model cannot answer without running the tool, since the marker value is opaque
and unknowable a priori. (A trivial `printf`-a-known-string prompt is *not*
reliable — the model often answers from memory and skips the tool.) A Bash
`cat marker.txt` tool_use is product-representative: the app passes
`--allowedTools …,Bash` whenever the desktop-control grant carries the `.shell`
capability (`CLIArgumentBuilder.claudeAllowedTools`).

Run `scripts/windows-port/capture-claude-stream-json-golden.sh` (the canonical
recipe), or reproduce it by hand:

1. In a clean working directory, write an opaque marker file **without** a trailing
   newline (so the Bash `cat` output — and thus the parsed `tool_result` detail — is
   the bare marker):
   ```sh
   printf 'BURNBAR_STREAM_GOLDEN_MARKER_7F3A9C2E' > marker.txt
   ```
2. Invoke the **genuine** `claude` binary directly (not a `PATH` wrapper shim), in a
   **stripped environment**, capturing raw stdout verbatim:
   ```sh
   PROMPT="There is a file named marker.txt in the current working directory. Use the Bash tool to run: cat marker.txt — to read its contents. Then reply with ONLY the exact one-line contents of that file and nothing else. Do not guess; you must actually run the command to learn the value."

   env -i \
     HOME="$HOME" USER="$USER" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
     PATH="<dir-of-real-claude>:/usr/bin:/bin:/usr/sbin:/sbin" \
     "$(command -v claude)" -p "$PROMPT" \
       --model claude-haiku-4-5 \
       --output-format stream-json --verbose \
       --strict-mcp-config \
       --setting-sources "" --disable-slash-commands \
       --allowedTools Bash --permission-mode acceptEdits \
       > claude-stream-mac-golden.jsonl
   ```

Flag / environment rationale — each choice keeps the capture **live** while making
the `system/init` event **canonical** (so the committed golden carries no
machine-specific tooling inventory):

- `--output-format stream-json --verbose` — NDJSON events (`--verbose` is required
  with `-p` + `stream-json`).
- `--model claude-haiku-4-5` — pinned + cheapest capable model (resolves to
  `claude-haiku-4-5-20251001`).
- `--strict-mcp-config` — no MCP servers, so `system/init.tools` stays the built-in
  set only (`mcp_servers: []`).
- `--setting-sources ""` + `--disable-slash-commands` — load **no** user settings and
  no skills, so `system/init` reports `skills: []`, `plugins: []`,
  `slash_commands: []` and **no** plugin-injected `SessionStart` hook lines. Auth
  (OAuth/keychain) is independent of setting-sources, so the run stays authenticated.
- **Direct binary + `env -i`** — bypasses local dev wrappers (e.g. a cmux/tmux shim)
  that otherwise inject `hook_started`/`hook_response` and `session_state_changed`
  system lines via `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS`. These are inert to the
  parser (they project to zero events) but are excluded for a canonical golden.
- `--allowedTools Bash --permission-mode acceptEdits` — mirrors the product's
  desktop-control grant path so the Bash tool auto-approves non-interactively. (The
  app never passes `--dangerously-skip-permissions`; this recipe does not either.)

> ⚠️ Do **not** relocate `CLAUDE_CONFIG_DIR` to isolate settings — on macOS the
> OAuth token is keyed to the default `~/.claude` config dir, and a relocated dir
> reports `Not logged in`. Use `--setting-sources ""` against the default dir instead.

This golden was captured with **Claude Code 2.1.191** on macOS.

### PII redaction (one deterministic, event-neutral substitution)

The authenticated run must use the default `~/.claude` config dir (OAuth keying,
above), whose `system/init.memory_paths.auto` field embeds the local macOS home
path. That is the **only** machine-specific string in the capture. The committed
RAW golden applies exactly one substitution — `"/Users/<local-user>"` →
`"/Users/openburnbar"` — to that inert field. The stream parser never reads
`memory_paths`, so the substitution changes **zero** parsed events; this is proven
because the committed events golden is produced by re-parsing the committed
(redacted) RAW bytes. The capture script performs this redaction automatically.

## What the golden exercises

Raw stream event variety (the full histogram is committed in the events golden's
`rawEventKinds`):

- `system/init` — the canonical init (`skills: []`, `plugins: []`,
  `mcp_servers: []`, built-in `tools` only)
- `system/thinking_tokens` — streaming thinking-token estimates
- `rate_limit_event` — the account rate-limit snapshot line
- `assistant` — a thinking block, then a `tool_use` (Bash), then the final `text`
- `user` — the `tool_result`
- `result/success` — the final result **with usage** (`usage` + `total_cost_usd`)

The shipped `ClaudeCodeStreamJSONParser` projects this raw stream to exactly **3**
`CLIChatStreamEvent`s — the **complete reachable set** for this parser, which only
ever emits `.text` / `.toolUse` / `.toolResult` for Claude stream-json:

| # | raw line | event | value |
| --- | --- | --- | --- |
| 0 | 7 | `toolUse` | `name: "Bash", detail: "cat marker.txt"` |
| 1 | 8 | `toolResult` | `name: "<tool_use_id>", detail: "BURNBAR_STREAM_GOLDEN_MARKER_7F3A9C2E"` |
| 2 | 9 | `text` | `"BURNBAR_STREAM_GOLDEN_MARKER_7F3A9C2E"` |

The parser deliberately emits **no** `reasoning`/`usage` event for Claude: thinking
blocks and the `result`-line usage are not part of the live stream parser's output
(usage is accounted on a separate log/quota path). That is faithful production
behavior, and it is precisely why the parsed golden is **environment-stable** while
the raw capture carries non-reproducible fields (`session_id`, `uuid`s,
`duration_ms`, `total_cost_usd`). The parser ignores all of that — every non-event
line projects to zero events, which the test also asserts
(`eventCount` = 3 ≪ `rawLineCount` = 11).

## Byte-stability & Windows diff (STREAM-029)

The parsed-events contract excludes every non-reproducible field, encodes with
sorted keys + stable pretty-print + trailing newline, and records string/integer
values only. A Windows stream-parser port replaying the committed RAW `.jsonl` must
produce the **identical** parsed events (`sourceLineIndex` included, since it
replays the identical line layout). Because the tool ids / marker are frozen in the
committed raw bytes, the replay is fully deterministic — same input bytes → same
parsed events, cross-platform.

## Regenerating after a deliberate parser change

The parse-diff test is TCC-safe: it never writes into the repo. It emits a fresh
candidate events golden to a writable output dir. To refresh:

```sh
TEST_RUNNER_OPENBURNBAR_STREAM_GOLDEN_OUT=/tmp/obb-stream-golden-out \
  scripts/test-openburnbar-app.sh \
  -only-testing:OpenBurnBarTests/ClaudeStreamGoldenParseDiffTests
# copy /tmp/obb-stream-golden-out/claude-stream-mac-golden-events.json into
# AgentLensTests/Fixtures/StreamGolden/, then `xcodegen generate` and re-run.
```

Only refresh after confirming the parser output change is intended. Do **not**
hand-edit either golden file (a hand-forged / non-canonical golden fails the test).
