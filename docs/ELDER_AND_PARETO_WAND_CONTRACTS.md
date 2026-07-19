# Elder Wand and Pareto Wand contracts

This page maps the two independently implemented Wand workflows to their
executable contracts. The names are related product language, but the runtime
systems are deliberately separate:

- **Elder Wand** is a model-fusion chat plugin. It runs a panel, a comparison
  judge, and an originating-model synthesis inside the OpenBurnBar gateway.
- **Pareto Wand** is a fan-out model-routing policy. It chooses a concrete model
  for each worker before a mission is claimed.

Neither workflow invokes the other. They may run concurrently and share model
catalog, provider, quota, and accounting dependencies, but an Elder `fusion`
plugin must never alter a mission group's Wand route and a Pareto selection must
never add a chat plugin.

When prose and implementation disagree, the request decoder, persisted schema,
gateway/claim boundary, and their tests are the executable contract in that
order. Historical build plans are intent, not a reason to override those
boundaries.

## Contract map

| Surface | Elder Wand | Pareto Wand |
|---|---|---|
| Public entry | OpenAI-compatible `POST /v1/chat/completions` with an enabled `plugins[].id == "fusion"` | Hermes Square `Routing Wand > Pareto`, Mac Wand dispatch, or Ministry `ministry_select_*_for_wand` |
| Primary implementation | `OpenBurnBarDaemon/.../ElderWandFusionOrchestrator.swift` and `ElderWandToolLoop.swift` | `OpenBurnBarCore/.../WandModelRouter.swift` and `tools/openburnbar-mcp/ministry.py` |
| Gateway/claim integration | `OpenBurnBarHTTPGatewayServer+Endpoints.swift` and `OpenBurnBarHTTPGatewayElderWandIntegration.swift` | Mobile `CLIAgentMissionDispatcher+FanOut.swift`; Mac `CLIAgentMissionRequestListener+WandRouting.swift` |
| User callers | macOS chat, iOS Hermes chat, Windows companion gateway | iOS Hermes Square, macOS Great Hall/Missions lane, local MCP and selector CLI |
| Configuration | `ElderWandPreset`: panel IDs, judge ID, tool budget, default preset | `WandPolicy.Selector.pareto`; Ministry `wands.v1.json` constraints, backends, runtime preference, autonomy |
| Durable user state | macOS/iOS `UserDefaults` key `elderWand.presets.v1`; Windows storage uses the same logical key | Ministry `<database parent>/ministry/wands.v1.json`; fan-out route copied into each child's sealed `requestedModelID` |
| Cloud boundary | Optional hosted search allowance and normal per-subcall usage/route accounting | Sealed `mission_groups` plus child `cli_agent_mission_requests`; Firestore rules enforce width and parallelism |
| User feedback | Final chat stream/body, typed 4xx/5xx error, and itemized fusion spend | Inline composer error before write, claim summary naming the routed model/provider, group phase/results |

## Elder Wand behavior

### Entry points and configuration

The dashboard **Wand models** shortcut, the Settings search result, and the
in-chat wand button all open the Analysis Models configurator. In the running
macOS app, the configurator receives the shared `ChatSessionController` so its
panel and judge pickers use the gateway's live advertised-model catalog. A
controller-free preview or test surface may show the guidance-only empty state;
a production entry point with a runtime context must not.

An active preset is sent through the existing OpenAI-compatible chat surfaces:
Hermes, OpenClaw, or Pi Agent. The selected surface is transport UI only; Fusion
executes in the BurnBar daemon. While Fusion is active, the chat model picker
therefore switches to the daemon's exact `route_eligible` catalog. Automatic
uses the first eligible daemon model as the originating synthesis model. An
explicit model selection is preserved, but a stale or unroutable selection
fails before send with a recovery message instead of being silently replaced.
CLI-only chat engines do not carry the Fusion plugin and fail visibly while the
preset is active.

### Input and bypass

The active plugin id is `fusion`. An absent plugin or `enabled: false` bypasses
fusion and preserves the ordinary gateway request. An active request requires a
non-empty `messages` array and at least one non-blank analysis model. The panel
is bounded to 1...8 unique model IDs in declared order. Repeating a model ID does
not repeat its provider call, latency, or spend. `max_tool_calls` is clamped to
1...16 with a default of 8.

### Pipeline and failure rules

1. Panel members run concurrently against independently resolved routes. Their
   original order is restored before judging. A missing route, timeout, network
   error, or empty answer drops only that member; zero successful members return
   HTTP 502.
2. The configured judge, or the first successful panel model when omitted,
   must return exactly five string fields: `consensus`, `contradictions`,
   `partial_coverage`, `unique_insights`, and `blind_spots`. Missing routes,
   provider failures, empty output, malformed JSON, extra keys, or wrong value
   types fall back to the raw panel evidence. Unvalidated judge prose is never
   presented to synthesis as a verdict.
3. The top-level request model performs synthesis. Buffered calls return its
   upstream body and status; streaming calls return an SSE relay plan. No inner
   request contains `plugins`, which prevents recursive fusion.
4. Cancellation is terminal. A canceled pipeline returns the gateway's 499
   result and does not proceed from panel to judge or synthesis or record a
   canceled provider turn as an ordinary provider failure.

The tool loop offers `web_search` and SSRF-guarded `web_fetch` to panel and judge
models. Every assistant `tool_call` id receives a matching tool response, even
when one batch exceeds the remaining budget; over-budget calls are explicitly
skipped. Search unavailability and hosted-search quota rejection degrade to a
tool result rather than aborting fusion. Provider/network errors remain visible
through route logs and typed gateway errors.

Each executed panel, judge, and synthesis subcall has a distinct idempotency key
and shared `parentRequestID`. Token usage and cost are aggregated without
collapsing same-model calls. Hosted search entitlement and allowance enforcement
remains in `functions/src/elderWandHostedSearch.ts`.

## Pareto Wand behavior

### Selection

The user-facing promise is **best value per quota**, not simply the cheapest
model. Two selectors implement that promise for different launch universes:

- The shared Swift router ranks each selected runtime's live catalog. Pareto
  prefers included/profile quota sources, then catalog/local sources, custom or
  cloud sources, and finally the OpenBurnBar proxy; capability and deterministic
  provider/model ordering break ties. Capability labels are token matches, so a
  name such as `proxy` is not mistaken for the `pro` tier.
- The Python Ministry joins Factory launch candidates to the canonical catalog,
  model metadata, and gateway quota. It orders healthy quota first and then
  capability per known price. Unknown/zero price without a real cost signal is
  demoted rather than treated as free. Optional proof mode must land a commit in
  a disposable repository before a candidate is accepted.

Both selectors remove duplicate runtimes/models, apply minimum capability and
backend constraints where available, prefer provider diversity, relax diversity
only when necessary, and return deterministic ordering. Fan-out width is bounded
independently by the local environment cap, product tier, app cap, and Firestore
rules.

Headless proof selection is atomic at the CLI boundary. If fewer candidates are
proven than `requestedCount`, `selectedForIndex` is `null` for every sibling so a
partial result cannot wrap one proven model onto missing workers. Modulo wrapping
is retained only after the requested capped selection is complete, for groups
whose sibling count is larger than the tier cap.

### Dispatch, persistence, and claim

Mobile resolves an active Pareto policy before opening the Firestore batch. Every
selected runtime must have a non-empty catalog-backed route; a partial route is a
user-visible failure and writes no misleading fallback mission. The persisted
`parallelismLimit` is clamped to `1...childMissionIDs.count`, matching the rule
contract.

The sealed child `requestedModelID` is authoritative at claim time. This is how
mobile Pareto and Manual selections survive reload, transport, and retry. The Mac
listener invokes the Ministry selector only for a grouped child with no concrete
model ID, which preserves the Mac Wand workflow and backward compatibility with
older unrouted groups. It must not replace a mobile Pareto or Manual route with
the Mac's default wand.

The Ministry store is sanitized without mutating caller-owned dictionaries. It
has exactly one default, falls back to the built-in Headmaster/Pareto seed for a
missing, corrupt, or unreadable file, and reports why. Saves use a unique
same-directory temporary file, file fsync, atomic replace, best-effort directory
fsync, and cleanup. Concurrent writers cannot collide on one fixed temp path;
the last complete atomic replace wins. Validation ignores only the volatile
`updatedAt` field when deciding whether a saved store needs rewriting.

## Interaction invariants

- Elder configuration lives in preset storage and lowers only to a chat
  `plugins` payload. Pareto configuration lowers only to worker routes.
- A Pareto-routed model can independently be a provider/model also used by an
  Elder panel, judge, or synthesis, but accounting remains separate by request
  and parent id.
- A Manual fan-out route and a mobile Pareto route are both concrete dispatch
  choices and survive Mac claim unchanged. Only an unrouted Mac Wand group asks
  Ministry to select at claim time.
- Failure in one Wand does not silently activate the other. Both fail closed at
  their authority boundary and expose recovery text to the initiating surface.

## Verification ownership

| Contract | Primary regression surface |
|---|---|
| Fusion decoding, panel/judge/synthesis, ordering, duplicate suppression, timeout, cancellation, tool protocol, SSRF/search fallback | `OpenBurnBarDaemonTests/ElderWandFusionOrchestratorTests` and `ElderWandToolLoopTests` |
| Dashboard/Settings destination and live model-catalog wiring | `OpenBurnBarTests/SettingsDeepLinkRoutingTests` plus signed-app UI proof |
| Preset bounds, one-default persistence, reload, wire payload, local auth boundary | `OpenBurnBarTests/ElderWandPresetTests`, `ElderWandSettingsTests`, and `TextExpansionRewriteBoundaryTests` |
| Hosted search auth, provider fallback, quota reservation | Functions Elder Wand unit tests |
| Windows preset/configurator/persistence/fusion parity | Windows presentation tests filtered by `ElderWand` plus XAML parse checks |
| Pareto ranking and capability classification | `OpenBurnBarCoreTests/WandModelRouterTests` |
| Mobile all-or-nothing routing and parallelism boundary | `OpenBurnBarMobileTests/CLIAgentMissionDispatcherSealTests` |
| Dispatch-to-claim route authority | `OpenBurnBarTests/CLIAgentMissionRequestListenerMattersTests` |
| Ministry ranking, caps, proof fallback, persistence, concurrency, malformed/error paths | `tools/openburnbar-mcp/tests/test_ministry.py` |
| Cloud mission-group width and parallelism enforcement | `functions/scripts/test-firestore-rules.mjs` |

See [The Elder Wand](ELDER_WAND.md) for the wire and hosted-search details and
[The Ministry](THE_MINISTRY.md) for MCP commands and the live fan-out runbook.
