# Core-decomposition packet queue (lane-ordered)

Integrator-owned. Each lane runs in its own worktree (`scripts/lane-setup.sh <lane>`)
and pulls the TOP `QUEUED` packet for its lane, executes it from the packet card, opens
a PR, and keeps moving. Packets never self-merge; the software-factory loop reviews
(Codex), branch protection merges. Update STATE in `docs/CORE_DECOMPOSITION_PROGRAM.md`
as packets land. Cross-lane dependencies are noted; a lane holds a packet whose
DEPENDS-ON is not yet MERGED.

Full cards: P-01…P-10. Draft cards (enumerate mv lists at wave start): P-11…P-20, S-H.

**S0-repair status (2026-07-12):** the four wave-1 systemic defects (marker-size sibling
ceilings, missing cross-module AE-IMPORT policy, missing AE-TESTABLE policy, P-03
SearchContracts closure) are FIXED on `core-decomp/s0-scaffold` + the six Codex threads
on PR #1559 are resolved. All wave-1 packets are re-runnable as **wave-1b** once #1559
merges. See docs/CORE_DECOMPOSITION_PROGRAM.md "Wave-1 learnings" and "Standard
Allowed-edit classes" (AE-IMPORT / AE-TESTABLE — now verbatim in every move packet).

## Wave 1b (parallel after the repaired S0 / #1559 merges)
| Lane | Packet | Card | STATE | Notes |
|---|---|---|---|---|
| B | P-01 SQLiteReader | full | QUEUED-WAVE1B | K3 fix; unblocks P-12/P-13. Was the marker-ceiling named blocker → FIXED (SQLiteReader planned 3/450) |
| Integrator | P-02 Kernel resources | full | QUEUED-WAVE1B | ops-file bundle staging; unblocks P-12 |
| D | P-03 root contracts → Kernel | full | QUEUED-WAVE1B | 6 files (SearchContracts re-sliced to P-14); canon stays green |
| D | P-04a SharedModels pure → Kernel | full | QUEUED-WAVE1B | after P-03 in lane D; symbol-closure re-checked |
| D | P-04b SharedModels crypto → Kernel | full | QUEUED-WAVE1B | after P-04a (needs CloudVaultCrypto) |
| D | P-05 Hermes | full | QUEUED-WAVE1B | adds `import OpenBurnBarKernel` to HermesAtomNavigator (AE-IMPORT) |
| D | P-06 Pretext | full | **PR_OPEN #1561** (OPEN_WITH_NAMED_BLOCKER on #1559) | resources manifest edit; re-runs green vs Pretext planned 5/850 |
| C | P-10 Insights models | full | QUEUED-WAVE1B | lands before P-08/P-09 |
| C | P-08 Insights Services core | full | QUEUED-WAVE1B | after P-10 |
| C | P-09 Insights Services remainder | full | QUEUED-WAVE1B | after P-08 |
| A | P-07 TextExpansion | full | QUEUED-WAVE1B | ui-purity --update; lane A serial |

## Wave 2 (after their deps merge)
| Lane | Packet | Card | DEPENDS-ON |
|---|---|---|---|
| B | P-12 LogParsers | draft | P-01, P-02 |
| C | P-13 Quota | draft | P-01 |
| D | P-14 VectorKit (+ OpenBurnBarSearchContracts, re-sliced from P-03) | draft | P-03 |
| A | P-11 MissionGroupContracts inversion | draft | P-04a/b |
| A | P-15 LaunchServices | draft | P-04a/b (SwitcherProfile/CLIAuthDiscovery → Kernel) |
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
| Integrator | P-20 Keyboard repoint | draft | P-07 |

## Optional / close-out
- S15 OBBCAbi → CoreCAbi relocation (needs P-12, P-10).
- S20 AgentLens/Mobile narrow repoints (ratchet-only; NEVER bulk-rewrite — the umbrella
  imports for AgentLens/OpenBurnBarMobile stay by design).
- Final: membership baseline at floor (main target ≈ 4 files); ui-purity near-zero;
  daemon/widget/keyboard umbrella-imports = 0; wire canon byte-identical throughout.

## Lane ownership recap
- **A** (serial): owns `core-ui-purity-baseline.json`. P-07 → P-11 → P-15 → P-16a…f.
- **B**: P-01 → P-12.
- **C**: P-10 → P-08 → P-09 → P-13.
- **D**: P-03 → P-04a → P-04b → P-14; P-05; P-06.
- **Integrator**: P-02, S-H, P-17, P-18, P-19, P-20, ratchet-down PRs.
