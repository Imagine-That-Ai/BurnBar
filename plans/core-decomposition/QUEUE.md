# Core-decomposition packet queue (lane-ordered)

Integrator-owned. Each lane runs in its own worktree (`scripts/lane-setup.sh <lane>`)
and pulls the TOP `QUEUED` packet for its lane, executes it from the packet card, opens
a PR, and keeps moving. Packets never self-merge; the software-factory loop reviews
(Codex), branch protection merges. Update STATE in `docs/CORE_DECOMPOSITION_PROGRAM.md`
as packets land. Cross-lane dependencies are noted; a lane holds a packet whose
DEPENDS-ON is not yet MERGED.

Full cards: P-01…P-10, P-04c. Draft cards (enumerate mv lists at wave start): P-11…P-20, S-H.

**S0-repair status (2026-07-12):** the four wave-1 systemic defects (marker-size sibling
ceilings, missing cross-module AE-IMPORT policy, missing AE-TESTABLE policy, P-03
SearchContracts closure) plus the wave-1b card defects (FIX-5 path-pin sweep, FIX-6
Insights dependency-inversion re-slice, FIX-8 Demo-fixture re-slice to P-09, P-02
staging-machinery scope) are FIXED on `core-decomp/s0-scaffold` (PR #1559 threads
resolved). See
docs/CORE_DECOMPOSITION_PROGRAM.md "Wave-1 learnings" and "Standard Allowed-edit classes"
(AE-IMPORT / AE-TESTABLE — verbatim in every move packet).

**Wave-1e status (2026-07-12):** compile-closure recorded a resource-loader dependency hub
(`BurnBarCatalogLoader.bundledCatalog`, learning 9). It created successor packet **P-04c**
(CLIRuntimeModelCatalog + WandModelRouter → Kernel) and added an undeclared **DEPENDS-ON
P-02 (#1582)** to **P-08** and **P-09** (three Insights adapters do a `bundledCatalog` pricing
lookup: AnthropicInsightAdapter:445, OpenAIInsightAdapter:377, OpenAICompatibleInsightAdapter:187).
P-04c/P-08/P-09 are QUEUED-WAVE1F, held until #1582 (P-02) merges. Wave-1e also converged the
S12 adapter/registry re-slice: `InsightProviderGatewayRegistry.swift` rides P-09;
`AnthropicInsightAdapter` + `BurnBarHostedInsightAdapter` (catalog-free) ride P-08;
`OpenAIInsightAdapter` + `OpenAICompatibleInsightAdapter` stay in P-09.

## Wave 1c (parallel after the repaired cards land on scaffold)
| Lane | Packet | Card | STATE | Notes |
|---|---|---|---|---|
| B | P-01 SQLiteReader | full | PR_OPEN #1573 | K3 fix; unblocks P-12/P-13. Was the marker-ceiling named blocker → FIXED (SQLiteReader planned 3/450) |
| Integrator | P-02 Kernel resources | full | PR_OPEN #1582 | daemon staging-machinery (3 files: Manager constant/error, BinaryResolver locator, +Lifecycle copy) + release/CI/MCP edits; stage Kernel bundle IN ADDITION to Core bundle; unblocks P-12. **Wave-1e: also unblocks P-04c, P-08, P-09** (`BurnBarCatalogLoader.bundledCatalog` hub) |
| D | P-03 root contracts → Kernel | full | PR_OPEN #1576 | 6 files (SearchContracts re-sliced to P-14); canon stays green |
| D | P-04a SharedModels pure → Kernel | full | PR_OPEN #1586 | after P-03 in lane D; CloudVaultCrypto path-pins (CODEOWNERS + 3 CI gates) FIX-5 — CODEOWNERS line flagged for security review |
| D | P-04b SharedModels crypto → Kernel | full | PR_OPEN #1587 | stacked on p-04a-e2 (needs CloudVaultCrypto) |
| D | P-04c catalog-model SharedModels → Kernel | full | QUEUED-WAVE1F | successor to P-04a; **DEPENDS-ON P-02 (#1582)** + P-04a (#1586). CLIRuntimeModelCatalog + WandModelRouter (RE-SLICED OUT of P-04a — `bundledCatalog` default-args at :698/:709) |
| D | P-05 Hermes | full | PR_OPEN #1580 | adds `import OpenBurnBarKernel` to HermesAtomNavigator (AE-IMPORT) |
| D | P-06 Pretext | full | **MERGED into scaffold via #1561** | resources manifest edit; re-ran green vs Pretext planned 5/850 |
| C | P-10 Insights models | full | QUEUED-WAVE1C | lands before P-08/P-09; FIX-6: AgentInsightsBundleAssembler re-sliced to P-08, extracts InsightProviderFamily/Entry to P-10; FIX-8: Demo fixture re-sliced OUT to P-09 |
| C | P-08 Insights Services core | full | QUEUED-WAVE1F (blocked on #1582) | after P-10; FIX-6: absorbs AgentInsightsBundleAssembler. **Wave-1e: +DEPENDS-ON P-02** (AnthropicInsightAdapter:445 `bundledCatalog`); absorbs `AnthropicInsightAdapter` + `BurnBarHostedInsightAdapter` (catalog-free) from P-09's Adapters/ |
| C | P-09 Insights Services remainder | full | QUEUED-WAVE1F (blocked on #1582) | after P-08; FIX-8: absorbs Demo/InsightVerdictDemoFixture + owns its Package.swift exclude deletion. **Wave-1e: +DEPENDS-ON P-02** (OpenAIInsightAdapter:377, OpenAICompatibleInsightAdapter:187 `bundledCatalog`); absorbs `InsightProviderGatewayRegistry` (root, rides its adapters) from P-08 |
| A | P-07 TextExpansion | full | PR_OPEN #1579 | ui-purity --update; lane A serial |

## Wave 1f (after P-02 #1582 merges — the `BurnBarCatalogLoader.bundledCatalog` hub, learning 9)
| Lane | Packet | Card | STATE | Notes |
|---|---|---|---|---|
| D | P-04c catalog-model SharedModels → Kernel | full | QUEUED-WAVE1F | DEPENDS-ON P-02 (#1582) + P-04a (#1586); after P-04a/P-04b in lane D |
| C | P-08 Insights Services core | full | QUEUED-WAVE1F | DEPENDS-ON P-10, P-02 (#1582); wave-1e adapter re-slice |
| C | P-09 Insights Services remainder | full | QUEUED-WAVE1F | DEPENDS-ON P-10, P-08, P-02 (#1582); wave-1e adapter/registry re-slice |

## Wave 2 (after their deps merge)
| Lane | Packet | Card | DEPENDS-ON |
|---|---|---|---|
| B | P-12 LogParsers | draft | P-01, P-02 |
| C | P-13 Quota | draft | P-01, **P-15b** (CodexQuotaAdapter/OMPQuotaAdapter call CLILaunchAdapter — must resolve via Kernel, not Apple-only LaunchServices) |
| D | P-14 VectorKit (+ OpenBurnBarSearchContracts, re-sliced from P-03) | draft | P-03 |
| A | P-11 MissionGroupContracts inversion | draft | P-04a/b |
| A | P-15 LaunchServices | draft | P-04a/b (SwitcherProfile/CLIAuthDiscovery → Kernel) |
| A | P-15b CLILaunchAdapter → Kernel (+P-12 FileManager Sendable follow-up) | full | P-15 — NEW predecessor to P-13 (Quota adapters) + P-18 (daemon repoint); extracts the Foundation-pure resolution/env surface DOWN so both consumers reach it without AppKit-adjacent LaunchServices; PR #1648 |
| Integrator | S-H headless app build CI | draft | S0 (anytime before P-16) |
| Integrator | per-wave ratchet-down PR (membership JSON) | — | after each wave merges |

## Wave 3 (UI / K4 — lane A serial)
| Lane | Packet | Card | DEPENDS-ON |
|---|---|---|---|
| A | P-16a…f UI (Views by subdir) | draft | S-H green, P-04a/b, P-11, P-13, P-05, P-06, P-08/09/10 |

## Wave 4 (Engine + repoints — integrator serial)
| Lane | Packet | Card | DEPENDS-ON |
|---|---|---|---|
| Integrator | P-17 Engine umbrella verify | draft | P-12, P-13, P-14, P-05, P-06 |
| Integrator | P-18 daemon/CLI repoint | draft | P-17 |
| Integrator | P-19 Widget repoint | draft | P-16 (UI), P-10 |
| Integrator | P-20 Keyboard repoint | draft | P-07, **P-16 (UI)** — `KeyboardView.swift` uses `UnifiedDesignSystem`; compile-closure BLOCKED until UI extracted (see card) |

## Optional / close-out
- S15 OBBCAbi → CoreCAbi relocation (needs P-12, P-10).
- S20 AgentLens/Mobile narrow repoints (ratchet-only; NEVER bulk-rewrite — the umbrella
  imports for AgentLens/OpenBurnBarMobile stay by design).
- Final: membership baseline at floor (main target ≈ 4 files); ui-purity near-zero;
  daemon/widget/keyboard umbrella-imports = 0; wire canon byte-identical throughout.

## Lane ownership recap
- **A** (serial): owns `core-ui-purity-baseline.json`. P-07 → P-11 → P-15 → P-15b → P-16a…f.
  (P-15b touches no baseline — Kernel is UI-purity assert-zero — so it does not contend
  for the `--update` lock, but it is scoped to lane A because it splits P-15's file.)
- **B**: P-01 → P-12.
- **C**: P-10 → P-08 → P-09 → P-13.
- **D**: P-03 → P-04a → P-04b → P-04c (WAVE1F, after P-02 #1582) → P-14; P-05; P-06.
- **Integrator**: P-02, S-H, P-17, P-18, P-19, P-20, ratchet-down PRs.
