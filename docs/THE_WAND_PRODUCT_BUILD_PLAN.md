# The Wand — Product + Gating Build Plan

> Make "The Wand" (quota-aware routing; modes **Headmaster's Wand** = best, **Pareto Wand** = best value) a real, tier-gated end-user product so `burnbar.ai` can market the true Free → Cloud → Cloud Pro → Ultra parallelism ladder honestly. Repo: `/Users/albertonunez/Documents/Developer/BurnBar`.

## Reality today (verified — 3 disconnected layers)

- **Routing Wands** = Python-only `tools/openburnbar-mcp/ministry.py` (`SEED_WANDS` `id:headmaster`/`id:pareto`; `select_models_for_wand` clamps to `OPENBURNBAR_WAND_PARALLEL_MAX`, hard ceiling **16**). MCP-tool-only (cmux/tmux orchestrators). No app callers yet.
- **End-user fan-out** = real, **iOS-only**, Firestore-backed: `FanOutComposerSheet` → `CLIAgentMissionDispatcher.dispatchFanOut` (floor 2, **no ceiling, no tier**, **quota-unaware** — manual runtimes + hardcoded `selectedModelID`) → `mission_groups` + N `cli_agent_mission_requests`; `MissionFanOutGroupCard`/`MissionGroupObserver` render it; macOS `CLIAgentMissionRequestListener` claims each child and spawns one local CLI subprocess.
- **Gating** = `OpenBurnBarCore/.../Membership/GatedFeature.swift` (`CloudTier` ladder + `GatedFeatureID` + `requiredTier`), checked via `.gatedFeature(.id, tier:)` (binary only). Tier from `MacCloudEntitlementStore`/`HostedQuotaSubscriptionStore`. **The only unforgeable cross-client cap is `firestore.rules validMissionGroup()` — a flat `<=16` for everyone.**

## The cap ladder (locked): Free **1** · Cloud **3** · Cloud Pro **8** · Ultra **16**
Single source of truth: `WandFanOut.maxParallel(for:)` in Core, mirrored in `firestore.rules` (unforgeable cap), `functions/src/callables/dataDomainUsage.ts` (server read seam), `website/src/data/site.ts` (display), Android `GatedFeature.kt`, and `OPENBURNBAR_WAND_PARALLEL_MAX` when the local MCP is spawned.

## Phase 1 — Real tier gate (bounded, the crux of "real gating")
- **Declare:** add `GatedFeatureID.theWand` (`requiredTier .cloud`, honesty-checked copy) to `GatedFeature.swift`; Android parity (`android/.../ui/pro/GatedFeature.kt`); `docs/FEATURE_GATING_SPEC.md` §3.
- **Ladder data:** `WandFanOut.maxParallel(for:)` in Core (Free 1 / Cloud 3 / Pro 8 / Ultra 16).
- **Enforce (the real cap):** `firestore.rules validMissionGroup()` — replace the flat `childMissionIDs/runtimeTokens/parallelismLimit <= 16` with a **tier-derived bound** using existing helpers (`hasActiveHostedQuotaEntitlement`, entitlement paths, ultra ids). Regenerate the generated SKU block (`node tools/gen-rules-entitlements.mjs`); **add rules tests**. *(Security-sensitive — on a feature branch, not the security branch.)*
- **Gate the UI:** `FanOutComposerSheet` (iOS) — clamp selectable runtimes to `maxFanOut(tier)`; present `FeatureUnlockSheet(gatedFeature(.theWand))` when exceeding; show "N of cap" + upsell (copy the Elder Wand pattern in `ElderWandChatEntry.swift`).
- **Display + cap feed:** `site.ts` `wandParallelMax` per tier + `PricingPlans.astro` line; `functions/src/callables/dataDomainUsage.ts` returns `wandParallelMax` and must resolve Cloud to cap 3, not Free cap 1.

## Phase 2 — Make it a true Wand (quota-aware routing)
- Bridge Headmaster's/Pareto routing into the app fan-out: **port `ministry.select_models_for_wand` ranking into the Swift daemon** (preferred, local-first/E2EE — the Mac listener already resolves backend+model at claim time) OR a tier-aware server callable. `dispatchFanOut` consumes routed `(runtime, model)` workers (already tier-capped) instead of manual runtimes + the hardcoded model switch. Keep the MCP env cap (`OPENBURNBAR_WAND_PARALLEL_MAX`), Firestore rules cap, and app cap against one catalog.

## Phase 3 — macOS surface + website
- Build a **macOS fan-out "cast a Wand" composer** (none exists; `MissionConsoleMacHost` is single-mission today). Then execute the website plan (`…/create-an-investigation-prompt-radiant-blanket.md`) to market the now-real ladder.

## Notes
- Branch off `security/run-09…` for this work (don't edit `firestore.rules` on the security branch directly).
- Keep the MCP env cap, rules cap, callable cap, website data, and platform copy in lockstep.
- `FanOutComposerSheet` comment says "2-5" but enforces no ceiling — fix as part of the gate.
