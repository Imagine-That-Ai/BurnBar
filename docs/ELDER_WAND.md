# The Elder Wand — model-fusion router

The Elder Wand answers a hard prompt with a **panel** of models instead of one. It
reproduces the behavior of [OpenRouter's Fusion plugin](https://openrouter.ai/docs/guides/features/plugins/fusion):
1–8 *analysis models* answer the prompt in parallel, a *judge* model **compares**
their answers into a structured verdict (it never merges them), and the user's own
*originating* chat model writes the final answer from that verdict.

Wire-compatible plugin id: **`"fusion"`**. User-facing name: **The Elder Wand**.
Membership gate: **Cloud Pro** (`burnbar_pro_max`).

## Request shape

The Elder Wand rides on the existing OpenAI-compatible `/v1/chat/completions`
endpoint via a `plugins` block. A request without an active fusion plugin is
forwarded unchanged.

```jsonc
{
  "model": "<originating model — writes the final answer>",
  "stream": true,
  "messages": [ ... ],
  "plugins": [
    {
      "id": "fusion",
      "enabled": true,              // omit or true = on; false = bypass this request
      "analysis_models": ["...", "..."],   // 1–8 panel models
      "model": "<judge model>",            // optional; falls back to first panel model
      "max_tool_calls": 8                  // 1–16, default 8 (per-model web-tool budget)
    }
  ]
}
```

Bounds and defaults are centralized on `ElderWandPreset`
(`OpenBurnBarCore/.../SharedModels/ElderWandPreset.swift`):
`analysisPanelRange = 1...8`, `maxToolCallsRange = 1...16`, `defaultMaxToolCalls = 8`.

## Pipeline

`ElderWandFusionOrchestrator` (`OpenBurnBarDaemon/.../ElderWandFusionOrchestrator.swift`)
runs entirely inside the daemon gateway (`BurnBarHTTPGatewayServer`):

1. **Panel** — each analysis model answers the original prompt in parallel
   (`withTaskGroup`), on its own resolved route, each running the server-side web
   tool-loop. A panel member that fails to route or errors is dropped; the request
   fails only if **zero** members succeed (HTTP 502). Answers are re-sorted into the
   declared panel order so the judge prompt is deterministic.
2. **Judge** — receives the N panel answers verbatim and returns a strict
   5-field JSON verdict: `consensus`, `contradictions`, `partial_coverage`,
   `unique_insights`, `blind_spots`. It compares; it never writes a new answer. If
   no judge is configured it falls back to the first panel model; if the judge call
   fails the raw panel answers are handed to synthesis.
3. **Synthesis** — the **originating** model (`model`) writes the final user-facing
   answer from the verdict, streamed when `stream: true`, else buffered.

### Recursion guard

Inner panel/judge/synthesis sub-calls deliberately **omit** the `plugins` block, so
a re-entered body has no active fusion plugin and can never re-trigger fusion. A
belt-and-suspenders marker key (`x_burnbar_fusion_depth`) is also detected by
`bodyCarriesFusionRecursionMarker` but is not written onto the wire body (so no
non-standard key leaks to upstream providers).

### Usage accounting

Every sub-call (each panel member, the judge, the synthesis) records **one** usage
event and **one** route-log row, with a **distinct** idempotency key (so identical
same-model/same-body sub-calls are not deduped) and a **shared** `parentRequestID`
(so the N rows roll up to one fusion request). Total spend for one fusion request
equals the sum of its parts. The tool-loop sums token usage across its turns into a
single per-sub-call event.

## Server-side web tools

Panel models and the judge get `web_search` + `web_fetch`, capped per model by
`max_tool_calls` (`ElderWandToolLoop` + `ElderWandWebTools`).

- **`web_fetch`** reuses the daemon's SSRF-safe fetch posture
  (`OpenBurnBarBrowserTargetPolicy` + redirect guard) and returns stripped page
  text. Always available.
- **`web_search`** has two modes:
  - Production hosted search runs through `performElderWandHostedSearch`
    (`functions/src/elderWandHostedSearch.ts`) with server-owned keys. It calls
    **Perplexity Search API first** and uses **Tavily basic search as fallback**
    when Perplexity fails or is unconfigured. Brave is not in the hosted path.
  - Local/dev daemon search resolves from the daemon process environment in this
    order: `BURNBAR_PERPLEXITY_SEARCH_API_KEY`, `PERPLEXITY_SEARCH_API_KEY`, or
    `PERPLEXITY_API_KEY`; then `BURNBAR_TAVILY_API_KEY` or `TAVILY_API_KEY`.

  When hosted search quota is exhausted or no key is configured, `web_search`
  degrades gracefully — the tool returns "search unavailable" and panel models
  proceed on their own knowledge plus anything reachable via `web_fetch`.
  Fusion still works without hosted live search; only the live-search capability
  is dark.

### Hosted Fusion search quota

Hosted `web_search` is a paid Cloud Pro/Ultra meter, separate from model-token
usage:

- Meter: `fusion_searches` in
  `users/{uid}/billing/allowances/months/{yyyy-MM}`.
- Included monthly quota: **100 hosted searches** for Cloud Pro, **300 hosted
  searches** for Ultra.
- Monthly cap: **1,000 hosted searches** for Cloud Pro, **2,000 hosted searches**
  for Ultra, including top-ups.
- Top-ups:
  - Apple: `com.openburnbar.elderWand.searches100` ($4.99),
    `com.openburnbar.elderWand.searches500` ($19.99).
  - Google Play: `com.openburnbar.elderwand.searches100` ($4.99),
    `com.openburnbar.elderwand.searches500` ($19.99).
  - Server kind: `elder_wand_searches_100` or `elder_wand_searches_500`,
    credited to `topupFusionSearchesPurchased`.
- One successful hosted provider search call consumes one search credit, even
  when the provider returns zero results. Failed provider calls do not consume a
  credit. `web_fetch` does not consume search quota.
- Fan-out protection: per Fusion run, hosted search has a default cap of 12
  searches and an absolute cap of 24. Identical `(runId, query)` searches are
  cached by query hash for the month so repeated tool calls in one Fusion run do
  not re-hit the provider.
- Quota tracker: Functions writes
  `users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion` with provider
  `OpenBurnBar`, account `Elder Wand Fusion`, and a monthly
  `Elder Wand hosted searches` bucket.

## Prerequisite: providers configured on the daemon gateway

The orchestrator resolves each panel/judge/originating model through the daemon
gateway's provider router (`BurnBarProviderRouter`). The daemon gateway (default
port 8317) must therefore have the relevant providers + credentials configured —
this is the same provider config the rest of BurnBar's routing uses. If a model has
no eligible route, that panel member is dropped (or, for the originating model, the
request returns 503 with a clear message). The configurator's panel/judge pickers
are built from the gateway's live advertised models, so a user with no routable
models sees a "No live models advertised yet" empty state rather than blank pickers.

When an Elder Wand preset is active, the macOS/iOS chat send path redirects the
request from the Hermes CLI relay to the daemon gateway so it reaches the
orchestrator.

## Entitlement gate (Cloud Pro)

- **Server-authoritative:** the hosted relay path (`functions/src/callables/hermesGateway.ts`)
  calls `assertActiveBurnBarCloudProEntitlement` before forwarding any request that
  carries an active fusion plugin, returning `403 { error: "entitlement_required",
  requiredTier: "pro", feature: "elderWand" }` for non-Pro callers — before any
  fan-out spend.
- **Client:** the configurator entry is wrapped with `.gatedFeature(.elderWand, …)`
  (`GatedFeatureID.elderWand`, `requiredTier: .pro`) and presents the standard Pro
  paywall when locked.

> A purely local daemon fan-out runs over the user's own provider keys on a machine
> they control, so it is licensing-gated client-side, not cryptographically
> bypass-proof. The server gate is the real protection boundary for BurnBar-hosted
> credit spend.

## Presets

Users name, save, and pick a default panel+judge configuration (`ElderWandPreset`).
Exactly one preset is the default, enforced by `Array.presetsSanitized()` (the same
one-default invariant `AgentPersona` uses). Presets persist local-first via the
platform settings store (`elderWand.presets.v1`):

- macOS: `AgentLens/Services/Settings/Stores/ElderWandSettings.swift` (via
  `SettingsPersistenceCoordinator`), surfaced on `SettingsManager.elderWand`.
- iOS: `OpenBurnBarMobile/Services/Hermes/ElderWandSettings.swift` (`.shared`).

`elderWandPluginsPayload()` lowers the active preset into the `plugins` block on the
outgoing request; it returns `nil` (no fusion) when no preset is active or the
active preset has an empty panel / blank judge.

## UI

A configurator on macOS (`AgentLens/Views/Chat/ElderWand/`) and iOS
(`OpenBurnBarMobile/Views/Hermes/ElderWand/`): a provider-grouped multi-select
analysis panel, a single-select judge picker, a `max_tool_calls` budget slider, and
a named-preset manager (save / rename / set-default / delete). Composed only from
the existing design system (Liquid Glass adapters, `DesignSystem` tokens, `GlassCard`).
Reachable from the chat header (live model list in scope) and the Settings tree
(empty state, since Settings has no chat session).

## Tests

- Daemon: `ElderWandFusionOrchestratorTests` — plugin decode incl. `enabled:false`
  bypass + snake_case, recursion-marker detection, tool-call clamp, message
  extraction, full pipeline with stub deps, partial-panel-failure degradation,
  all-fail → 502, streaming plan omits `plugins`, tool-loop run, web-tool graceful
  degradation + SSRF rejection, search-backend env resolution.
- macOS: `ElderWandPresetTests` (sanitizer + contract bounds) and
  `ElderWandSettingsTests` (persistence round-trip, one-default invariant, payload
  shape).
- Functions: `hermesGatewayElderWandEntitlement.test.ts` — non-Pro → 403 with no
  downstream spend; Pro → proceeds; `enabled:false` not gated.

## Extending

- **Another search backend:** add a case to `ElderWandSearchBackend` + its
  request/parse arms in `ElderWandWebTools`.
- **Another panel tool:** append an `ElderWandTool` from `ElderWandWebTools.makeTools()`;
  the loop advertises and dispatches it automatically.
- **Cloud-synced presets:** mirror the `ProviderAccountDoc` (`label` + `isDefault`,
  Firestore) pattern; the preset model is already `Codable`.
