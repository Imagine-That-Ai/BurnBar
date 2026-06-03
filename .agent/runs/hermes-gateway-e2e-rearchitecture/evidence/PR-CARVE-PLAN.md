# PR CARVE PLAN

## Fork repo (Ajnunezg/hermes-agent) — 2 stacked PRs
Baseline branch `ajnunezg/burnbar-platform` @ 7ac8ae02 (already has commit 7ac8ae023 = BurnBar platform).

### PR1 — "BurnBar platform addition" (no crypto)
Branch: `ajnunezg/burnbar-platform` (existing). Content:
- `plugins/platforms/burnbar/adapter.py` reconciled to canonical (oversight subsystem + runtime-status `_agent_version`/`agentVersion`) — **with the F-adapter sealing additions STRIPPED** (no relay_e2ee import, no _RelaySealer, no seal/open in _post_message/_init_attachment/_handle_burnbar_event).
- `tests/gateway/test_burnbar_plugin.py` (the non-sealing test additions: send happy/error, attachment, cursor, oversight).
- `plugins/platforms/burnbar/README.md` platform docs (NOT the E2E section).
- **REVERT `gateway/platforms/api_server.py`** off this branch (`git checkout 7ac8ae02 -- gateway/platforms/api_server.py`) — unrelated core change (152 ins), separate concern.
- EXCLUDE untracked junk: `assets/user_ascii_apple.txt` (not ours), `__pycache__`.

### PR2 — "Gateway E2EE" (stacked on PR1)
Branch: new `ajnunezg/burnbar-gateway-e2ee` based on PR1 head. Content:
- NEW `gateway/crypto/__init__.py` + `gateway/crypto/relay_e2ee.py`.
- NEW `tests/gateway/test_relay_e2ee.py` + `tests/gateway/fixtures/HermesRelayWireVector.json`.
- `pyproject.toml` (gateway-e2ee extra `cryptography>=46`) + `uv.lock` (regenerated).
- `plugins/platforms/burnbar/adapter.py` — the sealing additions (relay_e2ee import, _RelaySealer, pairing keygen, seal send / open receive, refuse-plaintext).
- `tests/gateway/test_burnbar_plugin.py` — the seal round-trip test.
- `plugins/platforms/burnbar/README.md` — the E2E section + 5-line integration.

### Carve mechanics
Because the working tree has reconcile+sealing combined in adapter.py, produce two versions:
1. Save current (sealed) adapter.py + README + test → these are the PR2 state.
2. Produce the PR1 (unsealed-reconciled) adapter.py by stripping the sealing (dedicated focused edit/agent), commit PR1.
3. Re-apply the sealed versions on the PR2 branch, commit PR2.

## BurnBar repo (Imagine-That-Ai/BurnBar) — companion + tails
Single branch (current codex/format-functions-callables) or a new branch. Content = all BurnBar-side edits:
- Gateway companion: functions/src/{callables/hermesGateway.ts, hermesGateway.ts, types/legacy.ts}, OpenBurnBarMobile gateway (FunctionsRepository, HermesSettingsView, HermesGatewayRelayKeypair), OpenBurnBarCore HermesRelayCrypto wrappers, firestore.rules gateway comments, registry/honesty, dataExport tier.
- Tails: media (AppDelegate + MediaAttachmentManifestStore + rule flag-day), dedup (knowledgeMemory/knowledgeSearch/index.ts/indexes.json/embed.ts/PensieveVectorCloak), subscription (AgentBrandZoneView + AgentSubscriptionTopicStore.kt + CloudVaultCrypto), rollback (RollbackContracts + RollbackService + rule cancelled).
- This is the user's own app repo — commit there; optionally a companion PR. The 2 PRs the user asked for are the FORK ones.

## Open PRs
After Alberto reviews diffs: `gh pr create` for PR1 (base = fork upstream main or Ajnunezg main, head = ajnunezg/burnbar-platform) and PR2 (base = PR1 branch, head = ajnunezg/burnbar-gateway-e2ee). Confirm exact base with Alberto.
