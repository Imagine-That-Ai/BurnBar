# Usage ingest — live and catch-up

OpenBurnBar measures token burn from local agent session logs. Corpora on a
busy machine are huge (multi-GB Claude transcripts, 10GB+ Grok sessions,
Codex trees that also contain `tmp/` clones). A single sequential refresh
with one shared byte budget lets the first alphabetical provider (Claude)
consume every tick. Later providers look dead even though they are burning.

## Lanes

| Lane | When | What it reads | UI |
|---|---|---|---|
| **Live** | Every refresh / menu-bar Scan | Files touched in the last 12 hours, providers in parallel | Spinner: “Scanning live burn…” |
| **Catch-up** | After each live tick, background | Historical unread bytes, 3-wide, 48MB/provider/slice | “Catching up older sessions…” |
| **Full** | Recount | No date filter; emits cached rows so a wiped table rebuilds | Scan spinner |

Live persists only live-window rows. It applies a parser invalidation
(`usageSessionIDsToDelete`) only when this persist set also contains a
replacement id or `id#…` day bucket. Otherwise Codex can delete a lifetime
row whose historical replacements were filtered out.

Catch-up cannot hold `isRefreshing`. Live, catch-up, and single-provider
persists take `UsageIngestPersistGate`, a non-reentrant async mutex. A
plain Swift actor is not enough: `await` inside persist would re-enter and
let two lanes delete/insert the same session ids.

Live parse sets `includeCachedUnchangedUsages` to false so a 12-hour tick
does not materialize a lifetime of already-durable `TokenUsage` rows.

## Budgets

- Live: 16MB new content per provider, up to 8 providers at once.
- Catch-up: 48MB per provider, 3 at once, at most 6 slices per kick.
- Process memory ceiling remains 4GB for any one governor.

## Incremental parsers

Claude, Factory, and Codex already skip unchanged files via disk cache and
only charge the governor for new tails. Grok now does the same for leaf
sessions (`grok_parser_cache.json`). Parent Grok sessions always re-read so
child-subtraction stays correct; cached child breakdowns are still injected
into that reconciliation.

## Settings paths

`ParserRegistry` constructs Factory and Grok with the sanitized resolved
settings path. Newline-duplicated Factory roots and an xAI SuperGrok quota
sidecar persisted as `logPath_xai` no longer hide `~/.factory/sessions` or
`~/.grok/sessions`.

## Operator notes

- `recountAll()` uses the full/catch-up path so a reset is complete.
- Memory pressure cancels catch-up.
- Grok live ticks skip idle session directories after cheap mtimes
  (`updates.jsonl`, `summary.json`, `signals.json`, `chat_history.jsonl`).
- Codex thread fetch never opens rollout files just to classify subagents.
- Catch-up still enumerates provider trees (metadata stats, not full-file
  reads once a cache exists). FSEvents-driven discovery is the next
  efficiency step if directory walks become the limiter.
