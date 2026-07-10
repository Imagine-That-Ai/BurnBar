# Ledger row: f2-browser-computer-use / f2-elder-wand-fusion / f2-model-proxy-router / f2-companion-cli

**What this proves:** Remaining F2 workstreams ship production cores:

1. **Browser CU:** BrowserComputerUseLifecycle with IBrowserDriver (InProcess + Process
   Playwright command env) — launch/navigate/evaluate/close fail-closed.
2. **Elder Wand fusion:** ElderWandFusionOrchestrator tool loop with max-step budget
   and terminal/fail-closed outcomes.
3. **Model proxy router:** ModelProxyRouter selects healthy routes, degrades across
   vendors, records metrics, fails closed when none healthy.
4. **Companion CLI:** CompanionCliServer multi-client loopback TCP JSON-line plane
   (ping/version ops).

**Tests:** BrowserLifecycleTests, ElderWandFusionOrchestratorTests,
ModelProxyRouterTests, CompanionCliServerTests.
