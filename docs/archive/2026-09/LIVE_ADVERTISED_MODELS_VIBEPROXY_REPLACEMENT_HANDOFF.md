# Live Advertised Models / VibeProxy Replacement Handoff

You are working in `/Users/albertonunez/Documents/Windsurf/BurnBar` on OpenBurnBar.

Goal: make BurnBar's live advertised model system first-class so BurnBar fully replaces VibeProxy. This must be easy as fuck for normal users to set up, understand, and trust.

## User Contract

- BurnBar must obey the model/provider/account the user selected in settings or the active agent harness. If Hermes is set to MiniMax 2.7, it must use MiniMax 2.7, not a stale hardcoded gpt-5.4-mini.
- No hidden stale defaults. No blind fallback to unavailable models. No "returned no text" when the real problem is quota, missing account, unsupported model, or no eligible route.
- This applies across Hermes, Pi, OpenClaw, Codex, and Claude.
- This also applies to every OpenAI-compatible CLI agent BurnBar wires now or later. Droid / Factory CLI, Forge CLI, OpenCode CLI, Codex CLI, Claude-compatible clients, and future CLI integrations must discover BurnBar's live catalog automatically instead of requiring Alberto-specific config or copied model names.
- Do not test Ollama/local models right now; they may crash from RAM pressure.
- Other agents are working in this repo. Do not revert unrelated changes.

## Vision

BurnBar should expose an OpenAI-compatible local proxy/router that makes VibeProxy unnecessary. Users should be able to add accounts/providers, see live advertised models, pick models per agent/tool, and send requests through BurnBar with predictable behavior. The product should feel obvious: Connections and Account Switcher already contain the right conceptual surfaces, but live advertised models need to become a real product capability, not scattered plumbing.

This must be forward-facing product behavior for future users, not a one-off local setup. A normal user should install BurnBar, connect accounts, press Connect for a supported CLI, and have that CLI receive the currently eligible BurnBar model list automatically. Adding new CLI clients later should mean pointing them at the same `/v1/models`, `/v1/chat/completions`, and `/v1/responses` contract, not adding another hardcoded model table.

## Start By Reading

- `AGENTS.md`
- `CLAUDE.md`
- `docs/HERMES_IROH_PRODUCTION_HANDOFF.md`
- `AgentLens/Views/Settings/ConnectionsSettingsView.swift`
- `AgentLens/Views/Settings/AccountSwitcher/`
- `AgentLens/Services/ProviderQuota/`
- `AgentLens/Services/SwitcherCLIFallbackPlanner.swift`
- `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/`
- `OpenBurnBarMobile/Services/HermesService.swift`
- `scripts/e2e/ios-iroh-chat.sh`
- `scripts/e2e/ios-iroh-gate.sh`

## Implement End To End

### 1. Build a canonical live advertised models source inside BurnBar

- Read live models from active configured providers/accounts and daemon gateway endpoints.
- Expose a coherent model catalog to UI and routing.
- Include provider/account/source identity, display name, model id, capabilities, quota state, enabled state, and last refresh/error.
- Prune stale model/account snapshots when accounts are removed or disabled.

### 2. Make routing obey user settings

- The selected model in Hermes/Pi/OpenClaw/Codex/Claude must be the exact model used by that harness.
- If selected model is unavailable, stop before sending and show a precise error.
- If no eligible route exists, show `No eligible route for <model>. Add or enable an account/provider that serves this model.` Do not emit fake assistant text.

### 3. Make Connections and Account Switcher first-class setup surfaces

- Users should see which providers are connected, which accounts exist, which models are currently advertised, and what quotas/plans each account has.
- OpenAI and Claude should support OAuth accounts where applicable, not only API keys.
- Adding another OAuth account must be possible and clearly isolated.
- Account rows must show individual quotas, not copied/shared account quota values.
- Settings should not say "No plans configured" when provider/account plans exist.

### 4. Replace VibeProxy functionality

- BurnBar daemon must expose OpenAI-compatible `/v1/models`, `/v1/chat/completions`, and `/v1/responses` behavior sufficient for external clients.
- `/v1/models` must reflect the live BurnBar catalog, not hardcoded defaults.
- The proxy should route through the selected/default account plan, support failover only when allowed, and return useful OpenAI-compatible errors.
- CLI wiring must consume the live BurnBar catalog for all supported clients, including Droid / Factory, Forge, OpenCode, Codex, and Claude-compatible clients. A user should not need to hand-copy model ids unless they are configuring an unsupported third-party client manually.
- Add docs/runbook explaining how a user sets up BurnBar as their VibeProxy replacement, including base URL, adding accounts, selecting models, and troubleshooting quota/no-route errors.

### 5. Fix scripts and automation

- Remove hardcoded gpt-5.4-mini defaults from iroh/Hermes E2E scripts.
- Resolve the test model from BurnBar's live `/v1/models` catalog, filtering out Ollama/local models unless explicitly requested.
- Keep explicit `--model` override support.
- Fail early with a clear error if no suitable live model is advertised.

### 6. Tests and verification

- Add focused tests for model catalog construction, stale snapshot pruning, per-account quota display data, selected-model routing, and no-eligible-route errors.
- Add/extend tests for HermesService streaming so upstream HTTP 503/no-route SSE chunks become user-visible errors, not empty replies.
- Add daemon tests proving `/v1/models` advertises the live catalog.
- Run focused xcodebuild tests for touched areas.
- Run `git diff --check`.
- Do not claim completion without evidence.

## Expected Outcome

A user can uninstall VibeProxy, open BurnBar, connect accounts/providers, see live advertised models, select one for Hermes/Pi/OpenClaw/Codex/Claude, press Connect for supported CLI agents such as Droid / Factory, Forge, OpenCode, and Codex, point any OpenAI-compatible client at BurnBar, and get the selected model every time. When something cannot run, BurnBar says exactly why and how to fix it.
