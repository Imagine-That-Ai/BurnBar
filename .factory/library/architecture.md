# Architecture

## Scope for This Mission: Context Packs

This mission adds a one-click **Context Pack** pipeline that assembles the most relevant session context and exports it in agent-specific envelopes.

## Core Components

### 1) ContextPack domain model
- Value object representing assembled handoff content:
  - project
  - ranked sessions (bounded)
  - deduplicated key files
  - key commands
  - usage summary
  - total char estimate
  - reason labels per included session

### 2) ContextPackService (assembly + ranking + capping)
- Pulls candidate session data from existing datastore/search/session-formatting services.
- Applies ranking heuristics:
  - same-project boost
  - recency weighting: last 7 days weighted 2x, older sessions decay
  - summary-presence boost
  - signal boost from key files + key commands
- Deterministic tie-break policy:
  - `endTime` desc, then `startTime` desc, then `indexedAt` desc, then stable ID.
- Processing sequence:
  - dedupe logical session identity -> rank -> cap to 5 sessions -> enforce 12k char cap by removing oldest included sessions first.
- Applies hard limits:
  - max 5 sessions
  - max 12k chars
  - if over budget, trim oldest included sessions first.
- Produces deterministic output (stable ordering and tie-break behavior).

### 3) Export formatting layer
- `ContextPackExportTarget` supports: `claude`, `codex`, `cursor`, `hermes`, `markdown`.
- Shared session body is produced once.
- Each target applies only envelope/header differences; shared body semantics remain equivalent.
- Envelope specifics:
  - `claude` / `hermes`: CLAUDE-style header + `<context_pack>...</context_pack>`
  - `codex`: minimal prompt with `## Context`
  - `cursor`: `.cursorrules`-style framing
  - `markdown`: canonical markdown brief (title, sessions, key files, usage summary)

### 4) UI surface: ContextPackSheet
- Central export UI:
  - included sessions list
  - export target pills
  - copy action + confirmation state
  - char-budget visualization + warning state
  - empty-state handling
- Uses existing DesignSystem and glass-card interaction patterns.
- Budget semantics:
  - UI warning threshold at 16k chars.
  - Service assembly hard cap remains 12k chars.

### 5) Entry points
- **Dashboard overview**: Context Pack card entry.
- **Session Detail**: contextual entry anchored to selected session/project when available.
- Both entrypoints route to the same sheet/service pipeline; only launch context differs.
- Launch policy:
  - Session Detail anchor takes precedence over ambient Dashboard filters/time range.
  - Dashboard launch is unanchored and uses deterministic default-anchor policy.

## Data Flow

1. User opens Context Pack from Dashboard or Session Detail.
2. Launch context (anchored or unanchored) is resolved.
3. ContextPackService gathers candidates, ranks, dedupes, and applies caps.
4. Sheet renders included sessions and metadata.
5. User chooses export target.
6. Export formatter wraps shared body in target envelope.
7. Copy writes final payload to pasteboard.

## Invariants

- Ranking and export are deterministic for identical inputs.
- Every export target uses the same underlying shared context body semantics.
- Empty data never crashes and never allows invalid copy payloads.
- Entry-point differences affect context selection policy only, not formatting correctness.
