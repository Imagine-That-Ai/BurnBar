# P03 — Activity, session logs, search

**Wave 1 · Route: `activity` · Replaces the generic `activity` daemon surface.**

## Mission

Session-log activity feed with parser-checkpoint provenance, per-session drilldown (tokens, cost, model, provider), and local search over sessions. Parser output is Tier A parity — render what the daemon returns; never re-derive token/cost numbers.

## Read first

- README §1–§2.
- macOS oracle: `AgentLens/Views/Components/SessionLedgerSection.swift`, session log views under `AgentLens/Views/Dashboard/`, search in `ChatSessionController+Search.swift` (interaction semantics only).
- Daemon: `BurnBarDaemonServer+RPCSearch.swift`, `+RPCUsage.swift`; parser checkpoint concepts in `AgentLens/Services/LogParser/`.

## Data contract

1. Bridge: `session_list` (paged; `{ sessions: {id,provider,model,startedAt,tokens,costUsd,title}[], nextCursor }`) and `session_search` (query → same shape) mapped from real RPC methods found in `+RPCSearch.swift`.
2. Fixture: ≥12 sessions across ≥3 providers so pagination and search have substance.
3. Provenance line must name the source (`live daemon session index` / `fixture transcript`).

## Files

- Create: `src/state/activityStore.ts`; `src/surfaces/activity/SessionRow.tsx`, `SessionDetail.tsx`, `SearchBox.tsx`, `ActivitySurface.tsx`; tests alongside.
- Modify: `SurfaceRouter.tsx` one line (`activity: ActivitySurface`).
- Append: `app.css` `/* ---- P03 activity ---- */`.

## Build steps

1. `SearchBox`: labelled `input[type="search"]` + debounced (300ms) store query; Escape clears; **no global key listeners** (evidence harness scans for keydown listeners in text-expansion files; keep this component's handlers on the input element only).
2. `SessionRow`: provider glyph dot, title, model chip, token/cost columns (tabular-nums, `.mono`), relative timestamp with absolute title attr.
3. List virtualization is NOT needed below 200 rows — paginate with a "Load more" button instead (WebKitGTK-friendly, simpler a11y).
4. `SessionDetail`: disclosure panel under the row (`aria-expanded` on the row's toggle button) with full metadata grid.

## Required states

Populated / Loading (skeleton rows) / Empty ("No sessions ingested — check provider log paths in Settings") / Error banner + retry / Offline (`OfflineNotice`); plus **search-empty** ("No sessions match ‘…’").

## A11y / Perf / Tests

- Search input labelled; results count announced via `aria-live="polite"`; disclosure buttons keyboard-operable.
- Debounce 300ms; page size 50; no rAF loops.
- Tests: debounce behavior (fake timers), pagination append, disclosure toggle, all six states, cost/token formatting.

## Done / Forbidden

README §4. Forbidden: client-side recomputation of tokens/cost; virtualization libraries; global listeners.

## P-17 parity delta

The Linux activity route now keeps the original P03 usage contract while using
the daemon's existing canonical surfaces for deeper work:

- `daemon.usage.recent` remains the source of exact provider/model, timestamp,
  cost, and token fields. The renderer does not synthesize a total from input
  and output counters.
- `daemon.search.query` powers transcript search and on-demand indexed excerpts
  for a session. Search hits retain `sourceID`, `sourceKind`, project, and
  snippet provenance; missing index/body data is shown as unavailable.
- `run.resume` is the only resume mutation. The daemon chooses the native
  harness and launches the detached process; the renderer receives redacted
  outcome metadata only.
- No canonical session-export RPC exists. The activity detail action is
  disabled with that reason rather than routing through diagnostics export or
  inventing a method.

### P-17 verification

1. With a live daemon, load Activity and expand a row carrying `sessionID`;
   verify the detail panel calls `daemon.search.query`, shows indexed excerpts,
   and preserves source IDs without client-side transcript fabrication.
2. Search for a known transcript phrase; verify rows are marked as indexed
   matches and show an `Unknown date`/date-unavailable state when the search
   hit has no timestamp.
3. Resume a resumable row; verify `run.resume` launches the daemon-owned native
   harness and the UI reports the outcome. Missing/unsupported sessions must
   show the daemon recovery message without retry loops.
4. Verify Export remains disabled and explains that no session-export RPC is
   available. Fixture/offline mode must never claim live transcript or resume
   support.
