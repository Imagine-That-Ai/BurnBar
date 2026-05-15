# Insights

> A first-class destination on macOS, iPad, and iPhone that turns the data
> OpenBurnBar already collects — token usage, conversations, agent runs,
> provider quotas — into a **living, AI-authored analytics canvas**.

## What it is

Insights is OpenBurnBar's analytics workbench. It now starts with an
**Intelligence Brief**: a structured analysis of what changed, why it
matters, which evidence supports it, and what to do next. You pick a model
family — Codex, Claude, MiniMax, Z.ai, Kimi, Hermes, Ollama/local, or the
always-available local rule engine — and Insights investigates, summarizes,
and recommends across your AI-coding-agent activity.

Each "canvas" is a persistent dashboard composed of typed widgets. The
canvas lives on disk (with optional cloud sync), survives app restarts, merges
imports by stable canvas ID, and exports cleanly to JSON, PNG, PDF, or
Markdown.

## Quick start

### macOS

1. Open OpenBurnBar and click the new **Insights** entry in the dashboard
   sidebar.
2. The first screen is an **Intelligence Brief**, not a telemetry dashboard.
   It shows the top findings, biggest spend driver, quota/provider risk,
   evidence citations, follow-up questions, and one generated supporting
   chart.
3. To investigate further, type a prompt in the composer at the bottom of the
   canvas and hit ⌘ Return. The model dropdown above the composer lets you
   pick which model authors the canvas.

### iPad

Same sidebar entry. Inspector lives in a sheet that you can pull up via
the slider icon. Widgets project to a 6-column layout — same intent as
macOS, projected to fit.

### iPhone

The Insights tab lives between Burn and Streams. Widgets stack single-column.
Long-press a canvas in the bottom-sheet library to reorder.

### Android

The Android Insights screen reads Firestore rollups/quota snapshots directly
and uses the same structured `InsightAnalysisResult` contract as iOS and
macOS; demo fixture data is no longer the production path. Its composer shows
the selected analysis model, persists that selection, and can run local-only
through the rule engine or Ollama where available.

## Mobile mission control

iOS, iPadOS, and Android can launch Intelligence Brief missions from mobile
while the signed-in Mac remains the execution host. Mobile writes a pending
document under `users/{uid}/cli_agent_mission_requests/{requestId}` with:

- `missionKind`: `debt`, `diligence`, `creative`, `accretive`, `security`,
  `ui_improvement`, `modernization`, `provider_routing`, `cost_efficiency`,
  `project_focus`, or `custom`.
- `requestedRuntime`: `auto`, `codex`, `claude`, `hermes`, `openclaw`,
  `piAgent` / `pi`, `opencode`, or `ollama`.
- Mission options: `targetProject`, `depth`, `approvalMode`,
  `commandsAllowed`, and `fileEditsAllowed`.

The Mac listener claims pending missions, chooses the requested or best-fit
runtime, and writes both a small parent-document preview and durable ordered
events to `events/{sequence}`. Event kinds cover status, LLM responses, tool
calls/results, approval requests, artifacts, changed files, errors, and final
answers. Mobile detail screens listen to the parent document plus the event
subcollection, so the timeline is resumable after app backgrounding and can be
filtered by LLM, tools, errors, approvals, artifacts, and status.

New mission events are written only to the ordered `events` subcollection. The
parent `events` array is treated as a legacy read fallback so older cached
documents still decode, but new mobile dispatches and Mac host updates must not
seed or mutate parent-document timeline history.

If the mission requests `manual_all`, or requests risky execution with
commands/file edits under `existing_policy` or `risky_only`, the Mac moves the
mission to `waiting_for_approval` before launching the runtime. Mobile shows the
approval prompt in the live detail sheet and writes `approvalStatus: approved`
or `rejected`; the Mac resumes only after approval and cancels rejected
missions without starting the agent.

Security boundaries:

- Firestore rules keep mission documents owner-scoped and reject unsupported
  runtimes, mission kinds, statuses, and event shapes. Lifecycle updates that
  claim, run, or complete a mission require `claimedBy` to point at a trusted
  macOS `escrow_devices` record, and mac-sourced event subcollection writes are
  accepted only after that trusted claim. Event subcollection documents are
  append-only: updates and deletes are denied so mobile cannot rewrite Mac
  history after it has streamed. Mobile approval responses are limited to the
  approval fields on an already waiting mission.
- The Mac listener registers itself in `escrow_devices` as a pending macOS
  executor and refuses to claim or run a mission unless that exact local Mac
  device record has `trustState: trusted`. Unapproved or signed-out Macs leave
  the mission pending so a trusted paired Mac can still claim it; Firestore
  rules deny pre-claim `failed`, `canceled`, or `unauthorized` mutations from
  mobile clients. Firestore rules also deny one-shot creation of already
  trusted macOS executor records; macOS executor records must first exist as
  `pending` and then be approved via the narrow trust-state update used by
  Devices and Sync.
- Approval-gated missions pause before dispatching direct CLI or chat-backed
  runtimes. Mobile approval responses are persisted on the mission document,
  and rejection leaves an ordered `approval_resolved` event for auditability.
- Mac-side event mirroring redacts common token, secret, authorization, bearer,
  and JWT-looking values before writing to Firestore.
- Direct CLI runtimes launch from the Mac environment only; mobile never
  receives or stores local runtime credentials. Shell-backed runtimes pass the
  mobile prompt through `OPENBURNBAR_MISSION_PROMPT` instead of interpolating it
  into the shell command. OpenClaw also maps mobile safety options onto process
  flags: read-only missions run in plan/no-tools mode, and command-only missions
  deny file-edit tools.

Setup and verification runbook:

1. Sign in to the same Firebase account on BurnBar Mac and BurnBar Mobile.
2. Open BurnBar Mac once so the mission listener can register the local Mac in
   `users/{uid}/escrow_devices/{deviceId}`. If it appears as pending, approve
   it in Devices and Sync before launching command/file-edit missions.
3. Confirm the selected runtime is installed on the Mac. Chat-backed runtimes
   use the configured BurnBar chat backend; direct CLI runtimes resolve from
   the Mac PATH (`pi`, `openclaude`, `opencode`, `ollama`).
4. From mobile, launch a recommended Intelligence Brief mission or a custom
   prompt, then open the mission detail sheet. Expected lifecycle is `pending`
   or `queued`, `accepted`, `starting`, `running`, optional
   `waiting_for_approval`, then `completed`, `failed`, `canceled`,
   `unauthorized`, or `agent_launch_failed`.
5. Background and reopen the mobile app. The detail sheet should rebuild from
   the parent mission document plus `events` ordered by `sequence`; no live
   timeline data should depend on in-memory state.
6. For local verification, run:
   - `npm --prefix functions run test:firestore-rules`
   - `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' test -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests CODE_SIGNING_ALLOWED=NO`
   - `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test -only-testing:OpenBurnBarMobileTests/IntelligenceBriefWiringTests CODE_SIGNING_ALLOWED=NO`
   - `cd android && ./gradlew testDebugUnitTest --tests com.openburnbar.data.insights.InsightsDataLayerTest --no-daemon`

Failure-mode checklist:

- `mac_offline`: no signed-in BurnBar Mac has claimed the mission within the
  stale-window threshold. Open BurnBar Mac, verify Firebase sign-in, and verify
  the mission listener is attached for the same UID.
- `unauthorized`: a trusted Mac refused or lost authorization after claiming.
  Pending missions that have not been claimed should normally remain queued or
  move to `mac_offline`, not be terminated by an untrusted Mac.
- `waiting_for_approval`: mobile must approve or reject the persisted approval
  request. Approval resumes the Mac listener; rejection cancels without agent
  launch.
- `agent_launch_failed`: the selected runtime was missing, failed startup, or
  exited non-zero. Inspect the ordered event stream and verify the runtime is
  installed and available on the Mac PATH.
- Missing timeline events: verify Firestore rules were deployed from
  `firestore.rules`, not a stale console copy, and confirm the app is listening
  to both the parent mission document and `events` subcollection. For new
  missions, the subcollection is the source of truth; parent `events` only exist
  as legacy fallback data.

## Intelligence contract

Every analysis run is structured JSON, not freeform prose. The shared
contract is:

- `InsightAnalysisRequest`
- `InsightAnalysisContext`
- `InsightAnalysisResult`
- `InsightFinding`
- `InsightAnomaly`
- `InsightRecommendation`
- `InsightCitation`
- `InsightGeneratedWidget`
- `InsightFollowUpQuestion`
- `InsightAnalysisAuditEntry`

Each platform builds a compact, LLM-safe context plus a richer local
evidence index. The context includes a budget report with encoded bytes,
estimated prompt tokens, included sources, and truncation notes. Findings
must carry evidence, confidence, severity, and a recommended action; generated
widgets keep citations back to source data.

## Widget catalog

The renderer dispatch table accepts 26 widget kinds — full list in
`InsightWidgetKind`. Highlights:

| Kind                | What it shows                                              |
|---------------------|------------------------------------------------------------|
| `kpiTile`           | Big-number with delta + sparkline                          |
| `timeSeriesLine`    | Daily trend, optional per-provider/model breakdown         |
| `timeSeriesArea`    | Stacked area for cost mix                                  |
| `streamGraph`       | ThemeRiver for provider/model dynamics                     |
| `barRanking`        | Top-N agents / models / projects / files                   |
| `donut`             | Cost/token share                                           |
| `treemap`           | Spend by `(provider × model)`                              |
| `heatmap`           | Hour × day-of-week activity                                |
| `scatter`           | Cost-per-Mtoken × volume, etc.                             |
| `sankey`            | Flow from agent → model → project                          |
| `radar`             | Per-agent capability fingerprint                           |
| `cohort`            | Weekly retention by cohort                                 |
| `funnel`            | Stage-by-stage drop-off                                    |
| `quotaPulse`        | Live provider quota gauges                                 |
| `forecast`          | Holt-linear projection with uncertainty band               |
| `anomalyTable`      | Robust-z anomaly list                                      |
| `narrative`         | LLM-written paragraph + bullets + cite chips               |
| `recommendation`    | Suggested change + impact + confidence                     |
| `useCaseCluster`    | LLM-clustered conversation topics                          |
| `agentFocusMatrix`  | Per-agent × focus heat                                     |
| `modelFocusMatrix`  | Per-model × focus heat                                     |
| `drilldownList`     | Click-through session list                                 |
| `mermaid`           | Diagrams the LLM emits                                     |
| `ascii`             | TUI-style snapshots                                        |
| `composed`          | Recursive stack of any of the above                        |
| `error`             | Graceful "this widget failed to compute" card              |

## Built-in templates

Eight ready-to-go canvases ship with the app:

1. **Today** — daily snapshot.
2. **Cost Audit (7d)** — where the money went last week.
3. **Agent Focus** — what each agent is being used for.
4. **Model Focus** — where each model excels.
5. **Use-Case Library** — topic clusters + examples.
6. **Quota Health** — provider headroom.
7. **Quarterly Review** — 90 days at a glance.
8. **Anomalies** — outlier days, spikes, dips.

## Model picker

Available families:

- **Local rules** (default, on-device, $0)
- **Codex** (user credentials or Hermes-advertised route)
- **Anthropic** (Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5; user's API key)
- **MiniMax**
- **Z.ai**
- **Kimi**
- **OpenAI** (GPT-5, GPT-5 mini; user's API key)
- **OpenRouter** (any model; user's API key)
- **Hermes** (your existing relay)
- **Pi** (local Pi runtime)
- **Ollama** (local)

The picker is sorted with `localOnly` first. Each chip shows an egress tier
badge so you always know where data is going. Insights uses the user's
configured provider credentials or local runtime; it does not route analysis
through OpenBurnBar-owned model accounts. The composer shows the selected
model before analysis and records that model in the audit log.

On macOS, OpenBurnBar registers user-key gateways for OpenAI/Codex, Claude,
MiniMax, Z.ai, and Kimi when those credentials are already configured in the
app/keychain or exported in the local environment, plus Ollama/local. iOS,
iPadOS, and Android use the same preference and audit contract while staying
inside their mobile-safe data and credential surfaces.

### Hosted fallback (BurnBar Pro)

The BurnBar-hosted route is part of **BurnBar Pro** — same SKU as Hosted
Quota Sync (`com.openburnbar.hostedQuotaSync.cloud.monthly`). Free-tier
users still get every user-owned LLM path; only the hosted MiniMax route
is paywalled. The `insightsHostedAnswer` Cloud Function requires Firebase
Auth + an active `users/{uid}/entitlements/hosted_quota_sync` doc and
returns `permission-denied` (`{ code: "subscription-required" }`) for
anyone else. Clients catch this and switch the brief's CTA from "Connect
a model" to **"Upgrade to BurnBar Pro"**, which the shell wires to
StoreKit (Apple) / Play Billing (Android).

Intelligence Brief Q&A turns will **always** try to use a real LLM. Routing
order:

1. The user's explicitly selected model (whatever the picker shows).
2. Any user-owned Hermes / Pi / OpenClaw relay.
3. Any registered user-key cloud route (Claude, OpenAI, MiniMax, Z.ai,
   Kimi, etc.).
4. Local Ollama.
5. **BurnBar Hosted** — the `insightsHostedAnswer` Firebase callable, which
   proxies to OpenRouter using **MiniMax 2.7** server-side so the
   OpenRouter API key never lands on a client device. This route is only
   reached when nothing user-owned is reachable. The brief discloses it
   honestly via the eyebrow ("Answered by MiniMax 2.7 · hosted fallback")
   and surfaces a "Connect your own model" CTA so the next turn can run
   on the user's own route.
6. Local rules (deterministic, no LLM). Always disclosed with
   `isFallback = true` so the UI shows a "showing local fallback" hint
   and a Retry affordance. Privacy mode short-circuits straight to local
   rules without ever touching the hosted route.

Operator configuration for the hosted route:

- **Secret:** `OPENROUTER_API_KEY` (Firebase Functions secret).
- **Override model slug:** `INSIGHTS_HOSTED_FALLBACK_MODEL` env var on the
  Cloud Function (default `minimax/minimax-m2`).
- **Override base URL:** `INSIGHTS_HOSTED_FALLBACK_BASE_URL` (default
  `https://openrouter.ai/api/v1`).
- **Override callable URL on clients:** `INSIGHTS_HOSTED_FALLBACK_URL`
  env var (mobile and macOS shells). Useful for staging / emulator.
- **App Check** is required by the callable in production; the iOS and
  Android shells attach attestation tokens automatically.

## Privacy

Insights enforces a strict privacy contract on what may be sent to a
non-local model:

- No file contents, no source code.
- No conversation message bodies. (Only short, inferred titles.)
- No API keys, no credential labels.
- Device names hashed to `device_xxxx`.
- Project names hashed to `project_xxxx`. The displayName is the last
  path component only.
- The digest is capped at **24 KB** end-to-end (enforced by tests).

Toggle **Privacy mode** in the composer or in Settings → Insights to
restrict the model picker to `localOnly` adapters.

Every investigation and analysis run writes to a local audit log
(`~/Library/Application Support/OpenBurnBar/Insights/audit.jsonl`) with
prompt, model, egress tier, byte count, source budget, truncation summary,
result hash, and cost where available.

## Workspace controls (macOS)

- ⌘ Return — send the composer prompt to the selected model.
- **Refresh** (canvas header) — recompute every widget's data from the
  current snapshot. Widgets refresh in place and show their freshness pill.
- **Audit** (canvas header) — open the local audit table of every
  investigation that has touched your data, with model, egress tier,
  byte count, status, and cost per row. Includes a destructive **Clear**.
- **Inspector** (right rail) — edit the selected widget's title, time
  range, and layout (Column / Row / Width / Height steppers, clamped to
  the 12-column grid). Theme and canvas-level time window live at the
  top of the inspector.
- **Canvas library** (left rail) — switch between canvases, delete via
  context menu, or stamp a fresh canvas from **New from template**.

## Storage layout

```
~/Library/Application Support/OpenBurnBar/Insights/
├── canvases.json     — append-safe canvas history, merged by stable canvas ID
├── audit.jsonl       — investigation audit trail
└── cache/            — content-addressed canvas cache
```

## See also

- [`docs/INSIGHTS_ARCHITECTURE.md`](INSIGHTS_ARCHITECTURE.md) — internal
  architecture, gateway protocol, JSON-Schema contract, extension recipe.
- [`docs/CHART_STUDIO.md`](CHART_STUDIO.md) — the exploratory single-canvas
  surface; shares the same renderer grammar.
- [`docs/PRIVACY.md`](PRIVACY.md) — overall data-collection posture.
