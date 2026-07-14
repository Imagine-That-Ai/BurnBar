# Ledger row: f2-browser-computer-use / f2-elder-wand-fusion / f2-model-proxy-router / f2-companion-cli

**What this proves:** Remaining F2 workstreams ship production cores:

1. **Browser CU:** the core proof here is superseded by
   `browser-computer-use-production-composition.md`, which covers the packaged
   bridge, production app composition, settings UX, and live Chromium lifecycle.
2. **Elder Wand fusion:** ElderWandFusionOrchestrator tool loop with max-step budget
   and terminal/fail-closed outcomes.
3. **Model proxy router:** ModelProxyRouter selects healthy routes, degrades across
   vendors, records metrics, fails closed when none healthy.
4. **Companion CLI:** CompanionCliServer multi-client loopback TCP JSON-line plane
   (ping/version ops).

**Tests:** BrowserLifecycleTests, ElderWandFusionOrchestratorTests,
ModelProxyRouterTests, CompanionCliServerTests.
