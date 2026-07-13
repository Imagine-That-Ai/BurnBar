# OpenBurnBarCore decomposition program

**Status:** S0 scaffold landed (this PR). Move packets QUEUED.
**Parent plan:** `plans/how-do-i-take-joyful-falcon.md` (approved). This doc is the
condensed, executable form: end-state map, slice DAG, lane map, chokepoint table,
failure playbook, and the live packet status table.
**Predecessor program:** `docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md`
(K1/K2 landed; this program is the K3/K4 completion).

## TL;DR

The "157k god module" is a 95.6k-LOC main target inside a package that already has
11 products. Its internal dependency graph is **acyclic** — almost everything is a
mechanical `git mv`. S0 (this PR) creates all 11 new targets + regrowth gates up
front; then ~26 small move-packets run in 4 parallel lanes, each executable from a
rigid packet card (exact `git mv` list, exact validation, hard STOP rules). The K3
revert is fixed by extracting the 325-LOC SQLite reader **first** so Quota and
LogParsers extract independently. The daemon is repointed to a UI-free
`OpenBurnBarEngine` umbrella (the security payoff), and a file-membership deny gate
makes it impossible for new code to land in the old Core target again. Zero behavior
change throughout; apps keep `import OpenBurnBarCore` working via `@_exported` shims.

## End-state target map

All targets live in `OpenBurnBarCore/Sources/<Target>/`. Edges point downward
(acyclic). Privileged K2 closure {Kernel, Media, IrohRelay, FirestoreModels, crypto}
is untouched by every slice.

| Target | Product | Approx LOC (end) | Contents | Deps |
|---|---|---|---|---|
| `OpenBurnBarKernel` | yes (exists) | ~37k | root mission contracts (NOT `OpenBurnBarSearchContracts.swift` — VectorKit-bound, see P-03 re-slice), TraceContext, pure/crypto SharedModels, catalog-model SharedModels (`CLIRuntimeModelCatalog`/`WandModelRouter` — via P-04c, after P-02 lands the loader), MissionGroupContracts + MissionConsoleTypes (post-inversion), catalog loader + PII gate + their resources, Platform/ | FirestoreModels, crypto |
| `OpenBurnBarSQLiteReader` | **no** | 325 | `Services/SQLite/` + the SQLite backend conditional. The K3 fix. | SQLite backend |
| `OpenBurnBarLogParsers` | yes | ~9.3k | `Services/LogParser/` + `Services/LogPath/` + 2 log-discovery SharedModels | Kernel, SQLiteReader |
| `OpenBurnBarQuota` | yes | ~10.4k | `ProviderQuota/` + root `XAISuperGrokPacingLog.swift` | Kernel, SQLiteReader, crypto |
| `OpenBurnBarVectorKit` | yes | ~3.6k | HNSW/Persistent/Signpost vector indexes, VectorIndexDelta, SearchPlanner, **`OpenBurnBarSearchContracts.swift`** (references `BurnBarEmbeddingDistanceMetric` + `BurnBarSearchPlan` — VectorKit symbols, so it cannot precede them into Kernel), Pensieve chunker/cloak | Kernel |
| `OpenBurnBarInsights` | yes (Apple-only) | ~16k | `Services/Insights/` (minus ShareCardRenderer) + `SharedModels/Insights/` + AgentInsights models + Demo fixture | Kernel |
| `OpenBurnBarHermes` | yes | 1.4k | `Hermes/` (Foundation-only) | Kernel |
| `OpenBurnBarPretext` | yes | 650+res | `Pretext/` + its own `Resources/` bundle | Kernel |
| `OpenBurnBarTextExpansion` | yes (Apple-only) | 826 | `TextExpansion/` | Kernel |
| `OpenBurnBarLaunchServices` | yes (Apple-only) | ~4.8k | Switcher/Browser/CLI launch + discovery root files | Kernel |
| `OpenBurnBarUI` | yes (Apple-only) | ~32k | all `Views/`, theme/RGBA/design-token SharedModels, PixelClock renderers, ShareCardRenderer, LiveActivity attrs. This is K4 | Kernel, Quota, Insights, Hermes, Pretext, LogParsers |
| `OpenBurnBarEngine` | yes | 1 file | `@_exported` {Kernel, LogParsers, Quota, VectorKit, Hermes, Pretext} — what daemon/CLI/parity link | those 6 leaves |
| `OpenBurnBarCore` | yes (exists) | ~4 files | `@_exported` re-exports of everything (Apple-only ones pruned off-Apple) + `Engine/OBBCAbi*.swift` | all decomposition targets |

**Invariants baked into the S0 manifest:**
- Off-Apple pruning of UI/Insights/TextExpansion/LaunchServices uses the existing
  host-evaluated `#if os(Linux) || os(Windows)` seam (`buildApplePrunedDecompositionTargets`),
  mirroring how `OpenBurnBarData` is pruned. Off-Apple, Core does not depend on them.
- `OpenBurnBarSQLiteReader` mirrors `coreSQLiteDependencies` via
  `sqliteReaderSQLiteDependencies` so its per-platform SQLite backend stays
  byte-identical to Core's current wiring.
- **Core must NOT depend on Engine, and Engine must NOT depend on Core** (both
  depend on the leaf targets; a Core↔Engine edge would be circular). Engine sits
  below Core; there is no `EngineReexport.swift` in Core.
- Per-target off-Apple `exclude:` arrays exist next to `openBurnBarCoreExcludes`,
  empty at S0, so move packets only edit their own array's lines (auto-merge).

## Slice DAG (parallelism map)

```
S0 (scaffold+gates, SERIAL, integrator) — THIS PR
 ├─⇒ S1 SQLiteReader ─⇒ S6 LogParsers ─┬─⇒ S16 Engine umbrella ─⇒ S17 daemon/CLI repoint
 │        └────────────⇒ S7 Quota ─────┤
 ├─⇒ S2 Kernel resources (catalog+PII+ops staging) ─⇒ S6
 ├─⇒ S3 root contracts→Kernel ─⇒ S8 VectorKit ──────┘
 ├─⇒ S4 SharedModels pure/crypto→Kernel ─⇒ S5 MissionGroupContracts ─┐
 ├─⇒ S9 Hermes   ├─⇒ S10 Pretext   ├─⇒ S11 TextExpansion ⇒ S19 Keyboard repoint
 ├─⇒ S12 Insights   ├─⇒ S13 LaunchServices (⇐S4)                     │
 ├─⇒ S-H headless-app-build CI job (anytime before S14)              │
 └─⇒ S14 UI (K4) ⇐ {S4,S5,S7,S9,S10,S12,S-H} ─⇒ S18 Widget repoint ◄┘
Optional: S15 OBBCAbi→CoreCAbi (⇐S6,S12) · S20 AgentLens/Mobile narrowing (ratchet-only)
```

Wave-1 parallel set after S0: S1, S2, S3, S4, S9, S10, S12 (+ S11 in the serial UI lane).

## Lane map

Four parallel move lanes + one serial integrator, each in its own worktree
(`scripts/lane-setup.sh` / `scripts/lane-teardown.sh`), feeding the software-factory
PR loop (Codex reviews, branch protection merges; agents never self-merge).

| Lane | Owns | Packets (order) |
|---|---|---|
| **A** (serial-within-lane; ONLY lane that `--update`s `core-ui-purity-baseline.json`) | UI purity baseline | S11 TextExpansion → S13 LaunchServices → S5 MissionGroupContracts inversion → S14 UI (K4) |
| **B** | parser cluster | S1 SQLiteReader → S6 LogParsers (+ parity executable runs) |
| **C** | quota + insights | S7 Quota → S12 Insights (3 sub-packets) |
| **D** | kernel-ward moves | S3 root contracts → S4 SharedModels → S8 VectorKit; S9 Hermes; S10 Pretext |
| **Integrator** (serial) | shared surfaces | S0, S2 (ops-file staging), S-H, S16 Engine, S17–S19 repoints, per-wave ratchet-down PRs |

## Chokepoint table

| Chokepoint | Policy |
|---|---|
| `Package.swift` target/product/dependency declarations | S0 only, once. Packets only delete from `openBurnBarCoreExcludes` + add to their own target's exclude array. S10 is the one exception (adds `resources: [.process("Resources")]` to the Pretext target). |
| `docs/LINT_RATIONALE.md` allowlist | S0 only, once (two budget paths added). |
| `budgets/core-ui-purity-baseline.json` `--update` | Only Lane A, internally sequential. |
| `budgets/core-target-membership-baseline.json` | Never touched by packets (deny-gate; shrink is non-fatal). Integrator lands JSON-only ratchet-down PRs per merged wave. |
| `budgets/core-umbrella-imports-baseline.json` | Shrink-only. Integrator ratchets a root to zero after its repoint packet (daemon S17, widget S18, keyboard S19). |
| Consumer repoints (project.yml/pbxproj) | Integrator-only serial packets, between waves. |
| Canon-bearing moves | None in S1–S13 (canon generator only reads `OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift` + `BurnBarRPCIPCCanon.generated.swift`; the root mission contracts S3 moves are NOT canon sources — verified). |

## Regrowth gates (landed in S0)

1. **`scripts/debt/check-core-target-membership-budget.sh`** + `budgets/core-target-membership-baseline.json`
   — deny-gate: any NEW `.swift` in `Sources/OpenBurnBarCore/` fails CI; main-target
   totals may only shrink; each sibling has a 1.25× {files, LOC} ceiling. Shrink is
   non-fatal (`Improved: … run --update`, exit 0).
2. **`scripts/debt/check-core-umbrella-imports-budget.sh`** + `budgets/core-umbrella-imports-baseline.json`
   — per-consumer-root `import OpenBurnBarCore` snapshot; any NEW umbrella import in a
   tracked root fails CI; privileged roots ratchet to zero after their repoints.
3. All new UI-free targets are in `pureTargets` (assert-zero SwiftUI/AppKit from
   birth). `OpenBurnBarUI`, `OpenBurnBarTextExpansion`, `OpenBurnBarLaunchServices`
   are deliberately excluded (each carries ≥1 SwiftUI/AppKit file).
4. Both new budgets registered in the FIRST allowlist block of
   `docs/LINT_RATIONALE.md` + wired into the `debt-budgets` job of
   `.github/workflows/fast-feedback.yml`.

Both new gates were negative-tested at S0 (dummy Core file → membership FAIL; dummy
daemon umbrella import → umbrella FAIL; dummies removed → green), the same way
PR #1421's ratchets were.

## Failure playbook (verbatim in every packet)

1. **Build/test red mid-packet:** `git reset --hard <packet-base-sha>`; re-run the
   failing command once to confirm a green tree; report packet ID + failing command
   + output tail as `BLOCKED(build)`. Never open a PR from a red tree; never widen
   the Allowed-edit list.
2. **Merge conflict:** rebase onto main; take main's version of the conflicted region
   wholesale, re-apply ONLY your enumerated line-edits; if not obviously mechanical →
   `BLOCKED(conflict)`.
3. **Resource-bundle grep hit** (a `Bundle.module` file in your mv list outside
   S2/S10): hard STOP before any `git mv`; `BLOCKED(resource-bundle)`; back to
   architect.
4. **Canon `--check` red:** regen once, inspect diff; path-constant/prose-only →
   commit (only if the packet is CANON-flagged); any wire-name diff →
   `git reset --hard`, `BLOCKED(canon-drift)` (sibling PR race — rebase after it
   merges).
5. **CI red on a gate you couldn't run locally:** one-attempt rule (only if the fix
   is a missing exclude-list line in your own Allowed files) + Cross-agent receipt;
   else `OPEN_WITH_NAMED_BLOCKER`.
6. **Teardown:** `[ -L Vendor ] && rm Vendor` BEFORE `git worktree remove` (the
   deletion-through-symlink hazard). `scripts/lane-teardown.sh` does this for you.
   Never run `git worktree remove` by hand in a lane with a live Vendor symlink.

## Standard Allowed-edit classes (verbatim in every move packet)

These two edit classes are ALLOWED in every move packet in addition to its
enumerated `git mv` list and its own Package.swift line-edits. They exist because
`@_exported`/`@_exported import` re-exports carry a target's PUBLIC symbols to
consumers of the umbrella, but they do NOT satisfy the COMPILER inside the moved
files themselves, nor do they carry INTERNAL symbols to `@testable` tests. Both
classes are compiler-driven (add only what the build/tests demand) and every added
line is enumerated in the PR body.

- **AE-IMPORT (cross-module imports in MOVED files).** Add `import <Dep>` lines at
  the top of MOVED files only, where `<Dep>` is a module the DESTINATION target's
  manifest declares as a dependency, exactly as the compiler demands (e.g. a file
  moved into a leaf target that used `PlatformLogger`/`TraceContext`/etc. from the
  Kernel now needs `import OpenBurnBarKernel`, since within the old Core target
  those symbols resolved without an import but the destination target must import
  its declared dep). Enumerate every added import line in the PR body. Importing
  `OpenBurnBarCore` from a moved file is FORBIDDEN (it inverts the layering — the
  decomposition targets sit BELOW Core). If the compiler demands an import of a
  module the destination target does NOT declare as a dependency, STOP — the move
  is not dependency-closed; the architect re-slices (do NOT add a manifest
  dependency edge in a move packet).

- **AE-TESTABLE (`@testable` for moved internals).** For test files under
  `OpenBurnBarCore/Tests/` that fail to compile because they reach INTERNAL symbols
  of MOVED files, add `@testable import <NewTarget>` beneath the existing
  `@testable import OpenBurnBarCore`. Do NOT modify test logic and do NOT move test
  files (they stay in `OpenBurnBarCoreTests`, reaching moved PUBLIC symbols via the
  `@_exported` umbrella and moved INTERNAL symbols via the added `@testable`).
  Enumerate every touched test file in the PR body. Each card's pre-flight lists the
  ANTICIPATED affected tests (grep of the Core test tree for the moved files' type
  names); the actual set is whatever fails to compile — a card that anticipated a
  test needing `@testable` but finds it compiles without one simply omits it (public
  symbols need no `@testable`), and vice-versa.

## Packet status

Every packet ends as `MERGED`, `CLOSED`, or `OPEN_WITH_NAMED_BLOCKER`. Full cards
(exact enumerated `git mv` lists) exist for wave-1 (P-01…P-10); draft cards (scope +
`TO-ENUMERATE-AT-WAVE`) exist for later slices. Cards live in
`plans/core-decomposition/packets/`; the lane-ordered pull queue is
`plans/core-decomposition/QUEUE.md`.

Wave-1 state after the S0-repair follow-up: the four systemic defects PLUS the wave-1b
card defects (FIX-5 CloudVaultCrypto path-pin sweep, FIX-6 Insights dependency-inversion
re-slice, FIX-8 Demo-fixture re-slice P-10→P-09, P-02 daemon staging-machinery scope) are
fixed on `core-decomp/s0-scaffold`.
P-06 (Pretext) has MERGED into the scaffold via #1561; P-01/#1573, P-02/#1582, P-03/#1576,
P-04a/#1586, P-04b/#1587, P-05/#1580, P-07/#1579 are PR_OPEN; the remaining move packets are
QUEUED-WAVE1C. (PR #1560 is the unrelated `ratchet-repair/mission-splitbrain-1550` ratchet,
NOT a decomposition packet.)

Wave-1e compile-closure (learning 9) recorded a resource-loader dependency hub
(`BurnBarCatalogLoader.bundledCatalog`): it created successor packet **P-04c**
(CLIRuntimeModelCatalog + WandModelRouter → Kernel, DEPENDS-ON P-02) and added an undeclared
**DEPENDS-ON P-02** edge to **P-08** and **P-09** (three Insights adapters do a `bundledCatalog`
pricing lookup). P-08/P-09 are now **QUEUED-WAVE1F, blocked on #1582 (P-02) merge**. Wave-1e
also converged the Insights adapter/registry re-slice inside S12 (see the P-08 card):
`InsightProviderGatewayRegistry.swift` rides P-09 (registry follows its adapters);
`AnthropicInsightAdapter.swift` + `BurnBarHostedInsightAdapter.swift` ride P-08;
`OpenAIInsightAdapter.swift` + `OpenAICompatibleInsightAdapter.swift` stay in P-09.

| Packet | Slice | Target | Lane | Card | STATE |
|---|---|---|---|---|---|
| P-01 | S1 | OpenBurnBarSQLiteReader | B | full | PR_OPEN #1573 (was named-blocker on marker ceiling — FIXED) |
| P-02 | S2 | Kernel resources (catalog+PII+ops staging) | Integrator | full | PR_OPEN #1582 |
| P-03 | S3 | root contracts → Kernel (SearchContracts re-sliced to P-14) | D | full | PR_OPEN #1576 |
| P-04a | S4 | SharedModels pure → Kernel | D | full | PR_OPEN #1586 (CODEOWNERS line flagged for security review) |
| P-04b | S4 | SharedModels crypto chains → Kernel | D | full | PR_OPEN #1587 (stacked on p-04a-e2) |
| P-04c | S4 | catalog-model SharedModels (CLIRuntimeModelCatalog + WandModelRouter) → Kernel (successor to P-04a; DEPENDS-ON P-02) | D | full | QUEUED-WAVE1F (blocked on #1582 merge) |
| P-05 | S9 | OpenBurnBarHermes | D | full | PR_OPEN #1580 |
| P-06 | S10 | OpenBurnBarPretext (+resources manifest edit) | D | full | MERGED into scaffold via #1561 |
| P-07 | S11 | OpenBurnBarTextExpansion | A | full | PR_OPEN #1579 |
| P-08 | S12 | Insights — Services core engine (+AgentInsightsBundleAssembler, FIX-6; +wave-1e P-02 edge) | C | full | QUEUED-WAVE1F (blocked on #1582 merge) |
| P-09 | S12 | Insights — Services remainder (Verdict/Adapters/Cadence/Trace +Demo fixture, FIX-8; +wave-1e P-02 edge) | C | full | QUEUED-WAVE1F (blocked on #1582 merge) |
| P-10 | S12 | Insights — SharedModels + AgentInsights models (FIX-6 + FIX-8 re-slices) | C | full | QUEUED-WAVE1C |
| P-11 | S5 | MissionGroupContracts + MissionConsoleTypes inversion → Kernel | A | draft | QUEUED |
| P-12 | S6 | OpenBurnBarLogParsers | B | draft | QUEUED |
| P-13 | S7 | OpenBurnBarQuota | C | draft | QUEUED |
| P-14 | S8 | OpenBurnBarVectorKit (now also OpenBurnBarSearchContracts — FIX 4) | D | draft | QUEUED |
| P-15 | S13 | OpenBurnBarLaunchServices | A | draft | MERGED into wave3-base |
| P-15b | S13→S4 | CLILaunchAdapter+CLILaunchError → Kernel (Foundation-pure resolution/env surface, split from P-15's SwitcherCLILAunchService.swift) + P-12 FileManager-Sendable follow-up | A | full | PR_OPEN #1648 (base wave3-base; NEW predecessor to P-13 + P-18; AE-IMPORT Kernel×1 on ParserDiskCache, AE-TESTABLE Kernel×2; Kernel stays UI-purity assert-zero) |
| P-16a…f | S14 | OpenBurnBarUI (K4) — by Views subdirectory (a=Substrate, b=Insights-root+design-system, b2=Verdict, c=MissionControl, d=Cards+Square, e=UI SharedModels, f=Views-root LAST) | A | full | P-16a MERGED (base); P-16b PR #1650 (Insights root 32 + design-system closure 8; Verdict→P-16b2); **P-16c PR #1656** (MissionControl 11, AE-IMPORT Kernel×10, Kernel-closed — no pull-forward, no access-widening, no `SubstrateCatalog` qual, ui-purity 41→30); b2/d/e/f QUEUED |
| P-17 | S16 | OpenBurnBarEngine umbrella (fill) | Integrator | draft | QUEUED |
| P-18 | S17 | daemon/CLI repoint → OpenBurnBarEngine | Integrator | draft | QUEUED |
| P-19 | S18 | Widget repoint | Integrator | draft | QUEUED |
| P-20 | S19 | Keyboard repoint (DEPENDS-ON P-07 **+ P-16 UI/K4** — `KeyboardView.swift` uses `UnifiedDesignSystem`) | Integrator | draft | BLOCKED(compile-closure): undeclared P-16 edge — re-slice to Wave 3 (see card) |
| S-H | — | headless-app-build CI job (precursor to S14) | Integrator | draft | QUEUED |

## Sizing

10–25 files / 2,000–5,000 LOC per packet; hard cap 30 files / 6k LOC / 3 semantic
edits. Whole-directory packets may exceed file count but not the LOC cap. ~88k
movable LOC → ~26 move packets + S0 + S-H + 3 repoints + ~4 ratchet-down PRs + 1
close-out ≈ 35 PRs; ~6–8 per lane; ~5–7 waves.

## Wave-1 learnings (S0-repair, 2026-07-12)

Wave-1 exposed four systemic defects in the S0 scaffold + gates; the follow-up commit
on `core-decomp/s0-scaffold` fixes all four AND resolves the six Codex threads on
PR #1559. Executors of wave-1b must internalize these:

1. **Sibling ceilings were captured at MARKER size (2 files / 10 LOC).** Any packet
   FILLING a decomposition destination failed the membership gate on line one (P-01 →
   SQLiteReader 325 LOC vs a 10-LOC ceiling; P-06 → Pretext, the #1561 named blocker).
   FIX: `budgets/core-target-membership-baseline.json` now seeds an explicit `planned`
   ceiling (~1.25× the architecture end-state) for every decomposition destination
   (Kernel, SQLiteReader, LogParsers, Quota, VectorKit, Insights, Hermes, Pretext,
   TextExpansion, LaunchServices, UI, Engine); `--update` NEVER ratchets a `planned`
   ceiling down (planned wins over measured 1.25×). Non-destination siblings keep the
   measured 1.25× ceiling. Main-target rules unchanged (new file = FAIL, growth = FAIL,
   shrink = non-fatal), PLUS a new **per-file** growth check (a removed big file can no
   longer mask regrowth in another Core file — the aggregate LOC total is not enough).

2. **Moved files need explicit cross-module imports.** Inside the old Core target,
   symbols like `PlatformLogger`/`TraceContext`/`SQLiteConnection` resolved without an
   import; in a leaf target the source must `import <declared-dep>`. Standard edit class
   **AE-IMPORT** now authorizes adding those imports to MOVED files only (never `import
   OpenBurnBarCore` — that inverts layering). Concretely: P-05's HermesAtomNavigator
   needs `import OpenBurnBarKernel` for the Kernel's (already-public) `PlatformLogger`;
   P-12/P-13's SQLite-backed parsers/adapters need `import OpenBurnBarSQLiteReader`.

3. **`@_exported` does not carry INTERNAL symbols to `@testable` tests.** Tests under
   `OpenBurnBarCore/Tests/` that reach an internal member of a moved file fail to
   compile. Standard edit class **AE-TESTABLE** authorizes adding `@testable import
   <NewTarget>` beneath the existing `@testable import OpenBurnBarCore` (tests stay put,
   logic unchanged). Each card lists the anticipated affected tests (grep of the Core
   test tree for the moved files' type names); the actual set is compile-driven.

4. **Dependency closure must be symbol-level, not just import-level.**
   `OpenBurnBarSearchContracts.swift` is `import Foundation`-only but references
   `BurnBarEmbeddingDistanceMetric` + `BurnBarSearchPlan` (VectorKit symbols), so it
   could NOT precede them into the Kernel via P-03. It was re-sliced OUT of P-03 (now 6
   files) INTO P-14/VectorKit (with its definers). P-04a/P-04b passed the same
   symbol-closure re-check (CloudVaultCrypto's only `Pensieve` mentions are doc comments).

5. **Path-pin pre-flights must sweep CI gate scripts + CODEOWNERS, and card
   "expected NONE" claims must be machine-derived, not assumed.** P-04a's card claimed
   the moved SharedModels had ZERO path-pins; a machine sweep (`git grep -n <path> --
   .github scripts packages tools CODEOWNERS .swiftlint.yml project.yml`) proved
   `CloudVaultCrypto.swift`'s exact old path is hard-pinned in FOUR files / 8 sites:
   `.github/CODEOWNERS` (security ownership), `scripts/ci/verify-codeowners-security-trees.sh`
   (`REQUIRED_RULES` does EXACT string equality vs a CODEOWNERS pattern — moves in
   lockstep with the CODEOWNERS line), `scripts/ci/write_burnbar_source_provenance.py`
   (hashed provenance manifest — entry must be a real file), and
   `scripts/privacy/scan-chat-cloud-plaintext.mjs` (5 `assertIncludes(<path>, …)` calls
   that `readFileSync` the path — ENOENT crashes the scanner). The other 11 SharedModels
   had genuinely zero pins — but only a sweep, not an assumption, can tell them apart. A
   path-pin card that says "NONE" without a committed grep is a false-green. Security-owned
   files move their CODEOWNERS line in the SAME PR (ownership follows the file) and flag it
   for Alberto/security review.

6. **Staging-machinery edits must be located by CALL GRAPH, not by the constant's
   location.** P-02's card scoped the daemon Kernel-bundle staging to
   `OpenBurnBarDaemonManager.swift` because the `resourceBundleName` constant lives there —
   but that file only holds the constant + an error string. The REAL staging is a
   name-constant → resolver → copy-loop chain across THREE files:
   `OpenBurnBarDaemonManager.swift` (constant/error),
   `OpenBurnBarDaemonBinaryResolver.resolveResourceBundle(...)` (the six-candidate-dir
   locator), and `OpenBurnBarDaemonManager+Lifecycle.swift` (the actual `copyItem` +
   `fileExists` guard). Staging a SECOND bundle IN ADDITION to the Core bundle (never
   instead of) requires editing all three (new constant, parallel resolver, second copy
   block) — found by following the constant's readers, not by grepping its declaration
   site. Same lesson as FIX-5: derive scope from the code graph, not from where a name
   happens to be defined.

7. **Dependency inversion inside a same-target split needs a symbol-closure re-run
   AFTER the re-slice, not just before.** P-10 (Insights models) and P-08 (Insights
   engine) both land in `OpenBurnBarInsights` with P-10 first, yet two P-10 files
   referenced engine symbols P-08 moves later:
   `AgentInsights/AgentInsightsBundleAssembler.swift` (→ `InsightDataSnapshot`/
   `InsightUsageRow`/`InsightSessionRow` in `InsightDataSource.swift`) and
   `SharedModels/Insights/InsightAnalysis.swift` (→ the `InsightProviderFamily` enum in
   `InsightProviderFamilyCatalog.swift`). Flipping the order fails (P-08 hard-depends on
   ~30 P-10 model types — `InsightDigest`×94, `InsightWidgetData`×58, …). The fix moves
   the assembler P-10→P-08 (its remaining refs land in P-10 first) and extracts the pure
   `InsightProviderFamily`/`Entry` types into a P-10 model file (leaving the engine-coupled
   catalog logic in P-08). Both cards then re-ran the closure grep to ZERO residual
   cross-half refs. A whole-file move could not close `InsightAnalysis.swift` (its
   `InsightConfidence`/`InsightAnalysisResult`/… are referenced by Verdict/Bundle files
   that STAY in P-10), so the minimal cut was a 1-symbol source extraction — proving the
   re-slice must be validated by grep in BOTH directions, per packet, after the change.

8. **Demo/fixture files follow their ENGINE, not their models — and "the engine" is the
   packet that owns the exact symbol they CALL, not the nearest-looking one.** P-10's
   original mv list also carried `Demo/InsightVerdictDemoFixture.swift`, which calls
   `RuleBasedVerdictEngine.hash(of: verdict)` (line ~225). The obvious re-slice (mirror
   FIX-6: send it to P-08, the "Insights engine" packet) is WRONG:
   `RuleBasedVerdictEngine` is defined in `Services/Insights/Verdict/`, a SUBDIRECTORY
   owned by **P-09** — P-08's scope is only the 23 ROOT `Services/Insights/*.swift` files.
   The Verdict subtree lands in P-09, AFTER P-08, so a fixture parked in P-08 would
   reference a still-in-Core engine and break P-08's standalone build — the very failure
   FIX-6 prevents. The fix moves the fixture P-10→**P-09** (FIX-8), where its engine
   `RuleBasedVerdictEngine` AND its ONLY consumer `Verdict/VerdictComposer.swift`
   (`InsightVerdictDemoFixture.sample(...)`) both live — fixture + engine + sole consumer
   move as one unit. Its model refs (`InsightCitation`/`InsightModelTag`/`InsightVerdict`)
   still resolve to P-10 (merges first). The `openBurnBarCoreExcludes` deletion for the
   Demo file moves to P-09 too (the mover owns the exclude). Lesson: to place a
   fixture/demo/sample, grep the actual symbol it invokes and follow THAT symbol's file to
   its owning packet — sub-directory ownership (P-09 vs P-08) matters, and a fixture belongs
   with its engine's packet, never merely with its models' packet.

9. **Resource-loader symbols (`BurnBarCatalogLoader`) are hidden dependency hubs: any
   file with a `bundledCatalog` default-arg or pricing lookup depends on P-02.
   Compile-closure is mandatory before finalizing any slice.** Wave-1e compile-closure
   surfaced a whole cluster of undeclared P-02 edges that grep-by-path missed because the
   dependency is a `BurnBarCatalogLoader.bundledCatalog` reference, not an import.
   `BurnBarCatalogLoader` (`OpenBurnBarCatalogLoader.swift`) is a `Bundle.module`/
   `catalog.json` resource-backed loader that **P-02 (PR #1582)** moves Core→Kernel; until
   P-02 lands, any file referencing `bundledCatalog` fails `cannot find 'BurnBarCatalogLoader'
   in scope` in its destination target (`OpenBurnBarInsights` / `OpenBurnBarKernel`), and
   pulling the loader+resource forward is a forbidden **resource-bundle STOP** (Failure
   Playbook #3). The hub touched THREE slices: (a) P-04a already re-sliced
   `CLIRuntimeModelCatalog.swift`/`WandModelRouter.swift` OUT to a P-02-dependent successor
   (learning 5 / the RE-SLICED-OUT block) — now homed as **P-04c**; (b) three Insights
   adapters carry a `bundledCatalog` pricing lookup —
   `Services/Insights/Adapters/AnthropicInsightAdapter.swift:445`,
   `OpenAIInsightAdapter.swift:377`, `OpenAICompatibleInsightAdapter.swift:187` — giving
   **P-08 AND P-09 an undeclared DEPENDS-ON P-02** (`OpenBurnBarInsights` is a pure target
   depending on Kernel, so after P-02 merges the symbol resolves via Kernel). The lesson
   mirrors 4/5/6: a slice is not dependency-closed until its destination target COMPILES;
   grep-by-import and grep-by-path both miss default-arg/value-level references to a
   resource-loader hub. Run compile-closure (`swift build --target <dest>`) before
   finalizing ANY slice, and treat every `BurnBarCatalogLoader`/`bundledCatalog`/pricing-
   lookup reference as an implicit P-02 edge.

Gate/lane/CI hardening shipped with the repair (Codex PR #1559 threads): the umbrella
regex now matches `@testable import OpenBurnBarCore` (and `@_exported`/`@_spi(...)`
prefixes) so no repoint can hide an umbrella import; `scripts/lane-setup.sh` links the
individual populated Vendor artifacts when `Vendor/` already exists as a tracked dir
(and `lane-teardown.sh` removes those inner symlinks before `git worktree remove`); the
Windows engine lane adds `OpenBurnBarPretext` to its path filter and a `swift build
--target OpenBurnBarEngine` step in both legs (Core does not depend on Engine, so the
Core build never compiled it).

## Wave-2 learnings

10. **A slice can be a partial-file SPLIT, not a whole-file `git mv` — and the split's
    symbol closure can pull a SHARED type DOWN with the extracted half; a `@retroactive`
    SDK-`Sendable` shim belongs at the lowest common-ancestor target, never on a sibling
    leaf a consumer merely re-exports.** P-15b (NEW predecessor to P-13 + P-18, PR #1648)
    carved the Foundation-pure `CLILaunchAdapter` (executable resolution + allowlisted-env
    building) OUT of `OpenBurnBarLaunchServices/SwitcherCLILAunchService.swift` (1803 LOC,
    Apple-only, AppKit-adjacent) into `OpenBurnBarKernel/Platform/CLILaunchAdapter.swift`,
    leaving the launch-coordinator / process-invoker / profile-store-coupled half in place.
    Two consumers need the pure surface WITHOUT the Apple-only target: the daemon repoint
    (P-18) calls `CLILaunchAdapter.buildCLILaunch` UNGUARDED in `OpenBurnBarSwitcherShell`
    (the macOS switcher shell is Linux-excluded via `daemonExcludes`, so it is macOS-only at
    build time, not `#if`-gated), and P-13's `CodexQuotaAdapter`/`OMPQuotaAdapter` call the
    resolution/env methods (each `#if os(macOS)`-gated) but move into `OpenBurnBarQuota`,
    which does not and cannot depend on LaunchServices. Lessons: (a) a file split is a NEW
    destination file + a shrink of the origin, not a `git mv` — Package.swift needs no edit
    when the destination target globs its `Sources/` dir; (b) the extracted half's symbol
    closure (learning 4) can require moving a type the STAYING half also uses — here
    `CLILaunchError`, returned by the adapter's `validate*`/`buildCLILaunch` surface, HAD to
    move to Kernel too, because a type cannot sit ABOVE the Kernel while a Kernel-resident
    type references it; the staying half re-reaches both via LaunchServices' Kernel dep; (c)
    preserve the origin `#if os(macOS)` guard verbatim so the moved type stays byte-identical
    off-Apple (Kernel is cross-platform, but a macOS-guarded public enum in it simply does
    not exist off-Apple — matching every consumer's own `#if os(macOS)` gating); (d) a
    vestigial `import AppKit` a prior `git mv` dragged along is NOT proof of UI taint —
    machine-verify actual symbol usage (`NSHomeDirectory`/`NSTemporaryDirectory` are
    cross-platform Foundation), and the UI-purity gate confirms Kernel stays assert-zero.

    The bundled **P-12 follow-up** is the general form of the shim-placement rule: P-12 moved
    the `FileManager: @retroactive @unchecked Sendable` shim from Core into a LogParsers leaf
    (`ParserDiskCache.swift`), but Core's `ProviderQuotaAdapterContext` (a `Sendable` struct
    with a `FileManager` stored property) then saw the conformance only through Core's
    `@_exported import OpenBurnBarLogParsers` — a split-brain that fails Swift-6 Sendable
    checking in modes that do not propagate a re-exported retroactive conformance, and breaks
    outright once P-13 moves the adapters into `OpenBurnBarQuota` (no LogParsers dep). A
    retroactive SDK-type conformance required by types in multiple targets belongs at the
    LOWEST COMMON ANCESTOR (Kernel), declared ONCE — homing `FileManager: Sendable` in
    `Platform/PlatformSupport.swift` (unguarded; `FileManager` is not `Sendable` on any
    platform, unlike the `#if os(Linux) || os(Windows)` crypto shims beside it) and removing
    it from the leaf (which then inherits it via `import OpenBurnBarKernel`) fixes Core,
    LogParsers, and the future Quota target with a single declaration and no redundant
    conformance. Any executor moving a `@retroactive @unchecked Sendable` shim must ask which
    targets host types that DEPEND on that conformance and home it at their common ancestor,
    not wherever the moved file happened to carry it. AgentLens app-test targets reach
    leaf-target internals through `@testable import OpenBurnBarCore`/`OpenBurnBar` regardless
    of which package target hosts a type, so a whole-file move between package targets needs
    NO AgentLens-test edit (P-15 set the precedent; P-15b confirmed it) — the AE-TESTABLE
    set is the Core-package tests the compiler actually rejects, nothing more.
