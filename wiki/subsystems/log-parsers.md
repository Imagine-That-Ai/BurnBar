# Log Parsing Heuristics and Provider Capabilities

This document details OpenBurnBar's dual-engine logging parser architecture, outlining how the platform monitors, intercepts, and normalizes AI agent usage transcripts and quota metrics.

---

## 1. Dual-Subsystem Architecture: Transcripts vs. Quotas

OpenBurnBar implements two independent logging and telemetry loops:

### Subsystem A: Quota Adapters ("How much remains?")
* **Role:** Resolves remaining credits, token limits, and interval-based rate limits.
* **Target:** Feeds the Popover dashboard, Menu Bar display, and routing engine.
* **Output:** Generates `ProviderQuotaSnapshot` schemas showing absolute remaining bounds and cooldown/cooldown rate limits.

### Subsystem B: Transcript Parsers ("What was said?")
* **Role:** Reads full conversational logs (text, prompts, tool calls, costs, directory contexts) from local files.
* **Target:** Normalizes and indexes raw inputs into the local SQLite `conversations` schema.
* **Output:** Feeds local Retrieval (FTS5 + semantic search), the Streams Cockpit view, and client-side zero-knowledge encrypted backups. Registered in `ParserRegistry.defaultParsers()`.

---

## 2. Supported Providers & Log Geometries

OpenBurnBar supports a wide array of local CLI tools, code editors, and cloud-routed vendors. Below is the mapping of core local-file telemetry integrations:

| Provider / CLI Tool | Parser / Adapter | Log Path / Directory | Confidence | Format / Details |
|:---|:---|:---|:---|:---|
| **Claude Code** | `ClaudeCodeParser.swift` | `~/.claude/projects/**/*.jsonl` | `.exact` | Real-time JSONL session turns |
| **Codex CLI** | `CodexQuotaAdapter.swift` | `~/.codex/sessions/rollout-*.jsonl` | `.exact` | Cumulative token counter events |
| **Cursor Agent CLI** | `CursorAgentParser.swift` | `~/.cursor-agent/sessions/*.jsonl` | `.exact` | Plain-text prompts with exact token counts |
| **Grok Build CLI** | `GrokParser.swift` | `~/.grok/sessions/<encoded-cwd>/` | `.exact` | JSON-based `signals.json` & `chat_history.jsonl` |
| **Goose AI** | `GooseParser.swift` | `~/.local/share/goose/sessions/sessions.db` | `.exact` | SQLite relational schema |
| **OpenCode** | `OpenCodeParser` | `~/.local/share/opencode/opencode.db` | `.exact` | SQLite relational schema |
| **Pi Agent** | `PiAgentParser` | `~/.pi/sessions/*.jsonl` | `.exact` | Turn-based offline JSONL logging |
| **Antigravity** | `AntigravityParser.swift` | `~/.gemini/antigravity-cli/history.jsonl` | `.exact` | Turn-based JSONL with token totals |

---

## 3. SQLite Relational Log Geometries

Certain modern AI agent CLI platforms store session logs inside local relational SQLite databases rather than simple JSONL lines. OpenBurnBar utilizes robust database readers to parse and extract transcripts:

### Goose AI Database Schema
Goose stores sessions under `~/.local/share/goose/sessions/sessions.db`. OpenBurnBar monitors this file and executes structured reads across two principal tables:
* **Table `sessions`:** Unique session GUIDs, creation epochs, and project names.
* **Table `messages`:** Stores sequential turn payloads. Token totals are retrieved from `accumulated_input_tokens`, `accumulated_output_tokens`, or synthesized if missing.

### OpenCode Database Schema
OpenCode writes database rows to `~/.local/share/opencode/opencode.db`. OpenBurnBar indexes transcripts by monitoring:
* **Table `session`:** Maps user directories and dates to active run contexts.
* **Table `message` / `part`:** Stores message blocks and parsed JSON `data` blocks that detail prompt text, tools used, and model indicators.

---

## 4. Robustness and Crash Recovery

Because disk logging is asynchronous and prone to partial writes (e.g., if an agent crashes or is panic-halted), OpenBurnBar implements defensive ingestion rules:

* **Partial JSONL Line Recovery:** The JSONL parser processes logs line-by-line using structured `Swift.Decoder`. If a line is truncated, corrupt, or contains invalid syntax, the parser logs a warning, skips the corrupt line, and continues processing the rest of the file rather than throwing a fatal crash.
* **Safe SQLite Decode (GRDB Core):** To prevent crash-loops caused by upstream schema changes (such as a column type shifting from `INTEGER` to `TEXT`), OpenBurnBar accesses SQLite cells via `DatabaseValue.storage` rather than mapping strictly typed fields. If a type mismatch occurs (such as a string-serialized epoch time), the decoder resolves it gracefully.
* **Cumulative-Delta Protection:** Codex and Cursor logs use cumulative counters. If log lines are missing or out of sequence, OpenBurnBar’s cumulative-delta calculator resets to the latest valid absolute boundary, ensuring tracking remains accurate without creating negative usage anomalies.

---

## 5. Post-June-15 Anthropic Billing Split & Routing

From June 15, Anthropic splits billing between interactive subscription windows and programmatic API usage. To support developer flexibility, OpenBurnBar's local proxy router supports five opt-in configurations to manage this metering divide:

1. **Console API Route (Default):** Standard routing via an official `sk-ant-api...` Console key, billing the standard metered plan.
2. **Interactive Handoff (Manual CLI):** Bypasses programmatic rates by invoking `openburnbar-cli claude-handoff`. This opens an interactive handoff session, prompting the user's subscription quota and calculating the delta locally.
3. **PTY Interactive Executor (Experimental):** Runs the `claude` CLI inside a background PTY wrapper, routing traffic directly through the user's logged-in CLI terminal session (`sk-ant-oat...` tokens).
4. **Cross-Vendor Degrade (Failover):** If a Sonnet quota is exhausted, the router can optionally degrade to an alternative OpenAI-compatible model key seamlessly.
5. **Meter-Pool Diagnostic:** A dedicated test utility (`openburnbar-cli claude-meter-experiment`) that queries whether the last prompt turn was drawn from the user's interactive subscription pool or programmatic metered pool.
