# OpenBurnBarCore decomposition program

**Status:** ✅ **PROGRAM COMPLETE — Core floored to shims-only** — whole-program
composition proven on `core-decomp/wave4-final` (all packets folded, then P-21 + P-22
homed the last two residuals: `LinuxLocalPeerDiscovery` → Kernel and the 4 `OBBCAbi*`
C-ABI files → `OpenBurnBarCoreCAbi`). The Core main target is now **11 files / 127 LOC =
the 11 `@_exported` re-export shims ONLY**, down from 353 files / 95,667 LOC (**−99.9%
LOC**). The final composition proof, per-target numbers, and close-out learnings are in
**§ FINAL close-out (wave4-final)** at the bottom of this doc. The historical
planning/status sections below are preserved as-authored (S0-era snapshot).
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

The current shipped Kernel is 46,301 LOC after the Elder/Pareto hardening wave.
Until the next decomposition packets move that code back toward the ~37k
end-state, the regrowth gate carries a temporary 46,500-LOC ceiling. The
integrator must ratchet the ceiling down after those moves; this is not feature
headroom.

| Target | Product | Approx LOC (end) | Contents | Deps |
|---|---|---|---|---|
| `OpenBurnBarKernel` | yes (exists) | ~37k | root mission contracts (NOT `OpenBurnBarSearchContracts.swift` — VectorKit-bound, see P-03 re-slice), TraceContext, pure/crypto SharedModels, catalog-model SharedModels (`CLIRuntimeModelCatalog`/`WandModelRouter` — via P-04c, after P-02 lands the loader), MissionGroupContracts + MissionConsoleTypes (post-inversion), catalog loader + PII gate + their resources, Platform/ | FirestoreModels, crypto |
| `OpenBurnBarSQLiteReader` | **no** | 325 | `Services/SQLite/` + the SQLite backend conditional. The K3 fix. | SQLite backend |
| `OpenBurnBarLogParsers` | yes | ~9.3k | `Services/LogParser/` + `Services/LogPath/` + 2 log-discovery SharedModels | Kernel, SQLiteReader, ParserSupport |
| `OpenBurnBarParserSupport` | **no** | ~400 | parser resource governor, file-discovery checkpoint identities, and path-free pass telemetry | Kernel |
| `OpenBurnBarAssistantModels` | yes | ~2.1k | assistant identity, manifest, persona, runtime selection, prompt/navigation state, approval policy, and model I/O capability contracts | PlatformSupport |
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

**M4 contract budget note (2026-07-22):** M4 adds the server-signed
`trustedFanOutCap` field and backward-compatible decoding to the root mission
authorization contract in `OpenBurnBarKernel` (33 lines). The planned Kernel
ceiling is therefore explicitly adjusted from 46,250 to 46,300 lines for this
single wire-contract addition; the deny-gate remains in force for any further
Kernel growth.

**Memory Pro contracts (2026-09-02).** `BurnBarMemoryEgressPolicy` (a section of
`BurnBarProviderConfigurationSnapshot`) and the `daemon.memory.model_policy`
request/response types (`BurnBarMemoryModelPolicyContracts.swift`) are wire
contracts shared by the daemon, the signed CLI, the app, and the Python memory
engine; they belong in the Kernel with the other RPC contracts. The Kernel
ceiling is adjusted from 191 files / 54,000 LOC to 192 files / 54,100 LOC for
this single contract addition; the deny-gate remains in force for any further
Kernel growth.

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
| P-14 | S8 | OpenBurnBarVectorKit (now also OpenBurnBarSearchContracts — FIX 4) | D | full | PR_OPEN (base wave2-base; AE-IMPORT Kernel×6 for Locked/PlatformCrypto, AE-TESTABLE×1, Pensieve off-Apple excludes removed — cross-platform via Kernel PlatformCrypto) |
| P-15 | S13 | OpenBurnBarLaunchServices | A | draft | QUEUED |
| P-16a…f | S14 | OpenBurnBarUI (K4) — by Views subdirectory (ENUMERATED: a=Substrate+RGBA.swift, b=Insights, c=MissionControl, d=Cards+Square, e=UI SharedModels, f=Views root LAST) | A | full | P-16a PR_OPEN (Substrate 35f + pulled-forward `SharedModels/RGBA.swift`; AE-IMPORT Kernel×32, RGBA color-math internal→public, AE-TESTABLE×2 + `SubstrateCatalog` module-qualified for the Kernel off-Apple-stub shadow); b–f QUEUED |
| P-17 | S16 | OpenBurnBarEngine umbrella (fill) | Integrator | draft | QUEUED |
| P-18 | S17 | daemon/CLI repoint → OpenBurnBarEngine | Integrator | draft | QUEUED |
| P-19 | S18 | Widget repoint | Integrator | draft | QUEUED |
| P-20 | S19 | Keyboard repoint | Integrator | draft | QUEUED |
| S-H | — | headless-app-build CI job (precursor to S14) | Integrator | full | PR_OPEN (recipe PROVEN locally: `scripts/ci/headless-app-build.sh` → BUILD SUCCEEDED, exit 0; new `.github/workflows/headless-app-build.yml` gates P-16 on paths `OpenBurnBarCore/**`+`AgentLens/**`) |

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

10. **Retroactive-extension members on a moved-away type are a hidden hub; and a
    moved-out extension consumed by files that STAY (via `@_exported`) must be `public`,
    not module-`internal`. Cross-module type-name shadows from a re-exported sibling stub
    need module qualification.** (P-16a, S14 UI.) `Views/Substrate/` looked Kernel-only,
    but compile-closure (`swift build --target OpenBurnBarUI`) proved it hard-depends on
    `SharedModels/RGBA.swift`'s extension members — `RGBA.color`/`.mix`/`.bucketKey`/
    `.darkened` (×185/72/5/4) — which live in Core's SwiftUI-carrying `RGBA.swift`, NOT in
    the Kernel's `RGBA` struct. grep-by-import and grep-by-path both miss extension-member
    hubs (an `extension RGBA { … }` in another file adds members with no import at the use
    site). Fix: pull the ONE file forward (Core→UI, minimal), and — because Core files that
    stay above UI (`SwarmColorDriver`, `SwarmCanvasView+*`) reach those members across the
    module boundary through Core's `@_exported import OpenBurnBarUI` — bump the moved
    members from module-`internal` to `public` (access widening only; single definition
    graph-wide, so no ambiguity; behavior unchanged). Separately, the Kernel's off-Apple
    `SubstrateCatalog` stub (`LinuxSubstrateSupport.swift`, unguarded, compiled on Apple too)
    stopped being masked by same-module resolution once the REAL `SubstrateCatalog` moved to
    UI and Core re-exported it: Apple now sees two `SubstrateCatalog` (Kernel stub + UI real)
    → `ambiguous use`. Since only tests referenced it unqualified (the whole-Core build stayed
    green), the fix is test-local module qualification (`OpenBurnBarUI.SubstrateCatalog`) +
    `@testable import OpenBurnBarUI` for the moved internals — NOT a privileged-Kernel edit.
    Lesson for P-16b–f: run compile-closure per sub-packet; treat every retroactive
    `extension <MovedType>` as a hub; make moved members reachable by re-exporting Core
    consumers `public`; qualify any `SubstrateCatalog` (and any Kernel-off-Apple-stub name)
    used unqualified on Apple.

Gate/lane/CI hardening shipped with the repair (Codex PR #1559 threads): the umbrella
regex now matches `@testable import OpenBurnBarCore` (and `@_exported`/`@_spi(...)`
prefixes) so no repoint can hide an umbrella import; `scripts/lane-setup.sh` links the
individual populated Vendor artifacts when `Vendor/` already exists as a tracked dir
(and `lane-teardown.sh` removes those inner symlinks before `git worktree remove`); the
Windows engine lane adds `OpenBurnBarPretext` to its path filter and a `swift build
--target OpenBurnBarEngine` step in both legs (Core does not depend on Engine, so the
Core build never compiled it).

---

## FINAL close-out (wave4-final)

The decomposition is **done, and the Core main target is now floored to shims-only.**
Every move packet, repoint, and umbrella fill shipped as a PR; `core-decomp/wave4-base`
merged the last 11 open packets onto `core-decomp/wave3-base` (in order:
P-15b → P-13 → P-18 → P-16a…f → P-19 → P-20). `core-decomp/wave4-final` then
fast-forwards two more packets on top — **P-21** (`LinuxLocalPeerDiscovery` → Kernel) and
**P-22 / S15** (the 4 `OBBCAbi*` C-ABI files → `OpenBurnBarCoreCAbi`) — dissolving the last
two non-shim residuals. The Core main target is now **exactly the 11 `@_exported`
re-export shims (11 files / 127 LOC)**. The p-16*→p-19→p-20 chain is a linear stack, so
those merges fast-forward; P-15b, P-13, P-18, and now P-21→P-22 are linear too. Zero
source conflicts, zero leaked conflict markers.

**This close-out (wave4-final) supersedes the earlier close-out PR #1723** (based on the
stale `wave4-base`, i.e. before P-21/P-22): same base (`core-decomp/s0-scaffold`), but the
new floor is 11 files / 127 LOC instead of 16 / 1,610.

### FINAL packet status (every packet → PR → state)

| Packet | Slice | Target | PR | State |
|---|---|---|---|---|
| P-01 | S1 | OpenBurnBarSQLiteReader | #1573 | MERGED (→ wave2-base) |
| P-02 | S2 | Kernel resources (catalog+PII+ops staging) | #1582 | MERGED (→ wave2-base) |
| P-03 | S3 | root contracts → Kernel | #1576 | MERGED (→ wave2-base) |
| P-04a | S4 | SharedModels pure → Kernel | #1586 | MERGED (→ wave2-base) |
| P-04b | S4 | SharedModels crypto chains → Kernel | #1587 | MERGED (→ wave2-base) |
| P-04c | S4 | catalog-model SharedModels → Kernel | #1625 | MERGED (→ wave2-base) |
| P-05 | S9 | OpenBurnBarHermes | #1580 | MERGED (→ wave2-base) |
| P-06 | S10 | OpenBurnBarPretext | #1561 | MERGED (→ scaffold) |
| P-07 | S11 | OpenBurnBarTextExpansion | #1579 | MERGED (→ wave2-base) |
| P-08 | S12 | Insights core engine | #1630 | MERGED (→ wave2-base) |
| P-09 | S12 | Insights remainder | #1631 | MERGED (→ wave2-base) |
| P-10 | S12 | Insights SharedModels + AgentInsights | #1583 | MERGED (→ wave2-base) |
| P-11 | S5 | MissionGroup/ConsoleTypes inversion → Kernel | #1626 | MERGED (→ wave2-base) |
| P-12 | S6 | OpenBurnBarLogParsers | #1627 | MERGED (→ wave2-base) |
| P-13 | S7 | OpenBurnBarQuota (K3 Quota redo) | #1652 | OPEN → folded into wave4-base |
| P-14 | S8 | OpenBurnBarVectorKit (+SearchContracts) | #1624 | MERGED (→ wave2-base) |
| P-15 | S13 | OpenBurnBarLaunchServices | #1633 | MERGED (→ wave2-base) |
| P-15b | S13 | CLILaunchAdapter Foundation surface → Kernel | #1648 | OPEN → folded into wave4-base |
| P-16a | S14 | UI: Views/Substrate (+RGBA.swift) | #1644 | MERGED (→ wave3-base equiv) |
| P-16b | S14 | UI: Views/Insights root + design-system | #1650 | OPEN → folded into wave4-base |
| P-16c | S14 | UI: Views/MissionControl | #1656 | OPEN → folded into wave4-base |
| P-16d | S14 | UI: Cards/Square + LiveActivity/PixelClock | #1666 | OPEN → folded into wave4-base |
| P-16e | S14 | UI: Swarm* + Verdict + ShareCardRenderer | #1675 | OPEN → folded into wave4-base |
| P-16f | S14 | UI: Views root (delete "Views" exclude, K4 done) | #1678 | OPEN → folded into wave4-base |
| P-17 | S16 | OpenBurnBarEngine umbrella (UI-free) | #1641 | MERGED (→ wave3-base) |
| P-18 | S17 | daemon/CLI repoint → OpenBurnBarEngine | #1664 | OPEN → folded into wave4-base |
| P-19 | S18 | Widget repoint → Kernel+Insights+UI | #1719 | OPEN → folded into wave4-base |
| P-20 | S19 | Keyboard repoint → TextExpansion+UI | #1720 | OPEN → folded into wave4-base |
| S-H | — | headless-app-build CI job | #1628 | MERGED (→ wave2-base) |
| P-21 | — | LinuxLocalPeerDiscovery → Kernel | #1724 | OPEN → folded into wave4-final |
| P-22 | S15 | OBBCAbi C-ABI surface → OpenBurnBarCoreCAbi | #1725 | OPEN → folded into wave4-final |
| S0 | — | scaffold (11 targets + gates + queue) | #1559 | OPEN (train root, base=main) |
| — | — | Close-out (wave4-base): composition proof + ratchet floor (16/1610) | #1723 | SUPERSEDED by wave4-final |
| — | — | **Close-out (final): Core = 11 @_exported shims only (11/127)** | (this PR) | wave4-final → s0-scaffold |

The whole train sits on the **PR #1559 (S0) stacked branches** awaiting factory
review/merge to `main`. Merge order to `main` is the stack order: S0 → wave2 packets
→ wave3 (P-17) → wave4 (P-13/P-15b/P-18/P-16b-f/P-19/P-20) → this close-out.

### FINAL numbers

**Core main target (`OpenBurnBarCore/Sources/OpenBurnBarCore/`):**

| | Program start | wave4-base | wave4-final (end) | Δ (start → final) |
|---|---|---|---|---|
| `.swift` files | 353 | 16 | **11** | −342 (−96.9%) |
| `.swift` LOC | 95,667 | 1,610 | **127** | −95,540 (**−99.9%**) |

wave4-final removes the last two non-shim residuals: P-21 moved `LinuxLocalPeerDiscovery.swift`
(632 LOC) to Kernel, and P-22 moved the 4 `Engine/OBBCAbi*.swift` C-ABI files (851 LOC) to
`OpenBurnBarCoreCAbi`. The residual is now **exactly the 11 `@_exported` re-export shims** —
nothing else:

| File | LOC | Why it stays |
|---|---|---|
| `KernelReexport.swift` | 11 | `@_exported import OpenBurnBarKernel` — keeps `import OpenBurnBarCore` working for apps |
| `OpenBurnBarHermesReexport.swift` | 10 | `@_exported` shim (Hermes) |
| `OpenBurnBarInsightsReexport.swift` | 14 | `@_exported` shim (Insights, Apple-only pruned off-Apple) |
| `OpenBurnBarLaunchServicesReexport.swift` | 14 | `@_exported` shim (LaunchServices, Apple-only) |
| `OpenBurnBarLogParsersReexport.swift` | 10 | `@_exported` shim (LogParsers) |
| `OpenBurnBarPretextReexport.swift` | 10 | `@_exported` shim (Pretext) |
| `OpenBurnBarQuotaReexport.swift` | 10 | `@_exported` shim (Quota) |
| `OpenBurnBarSQLiteReaderReexport.swift` | 10 | `@_exported` shim (SQLiteReader) |
| `OpenBurnBarTextExpansionReexport.swift` | 14 | `@_exported` shim (TextExpansion, Apple-only) |
| `OpenBurnBarUIReexport.swift` | 14 | `@_exported` shim (UI, Apple-only) |
| `OpenBurnBarVectorKitReexport.swift` | 10 | `@_exported` shim (VectorKit) |

= **11 `@_exported *Reexport.swift` shims = 11 files / 127 LOC**, and nothing else. This is
the irreducible floor: every shim exists solely so `import OpenBurnBarCore` keeps resolving
against the extracted sibling targets. (Three non-`.swift` resources also remain:
`Resources/MiningPickIcon*.svg` ×3 — pre-existing asset bundle, not part of the LOC metric.)

**Per-target files + LOC (the decomposition targets, wave4-final):**

| Target | Files | LOC | Product | Notes |
|---|---|---|---|---|
| `OpenBurnBarKernel` | 144 | 43,065 | yes (exists) | root contracts, pure/crypto SharedModels, catalog loader, Platform/ (+ `LinuxLocalPeerDiscovery` P-21), CLILaunchAdapter (P-15b) |
| `OpenBurnBarSQLiteReader` | 2 | 325 | no | the K3 fix (SQLite reader extracted first) |
| `OpenBurnBarQuota` | 42 | 10,401 | yes | ProviderQuota + XAISuperGrokPacingLog (K3 redo, P-13) |
| `OpenBurnBarLogParsers` | 27 | 9,673 | yes | Services/LogParser + LogPath |
| `OpenBurnBarPretext` | 2 | 650 | yes | Pretext + its Resources bundle |
| `OpenBurnBarHermes` | 7 | 1,389 | yes | Hermes (Foundation-only) |
| `OpenBurnBarVectorKit` | 9 | 4,299 | yes | HNSW/vector indexes + SearchContracts + Pensieve |
| `OpenBurnBarInsights` | 83 | 16,528 | yes (Apple-only) | Services/Insights + Insights SharedModels + Demo fixture |
| `OpenBurnBarLaunchServices` | 7 | 2,879 | yes (Apple-only) | Switcher/Browser/CLI launch + discovery |
| `OpenBurnBarTextExpansion` | 5 | 826 | yes (Apple-only) | TextExpansion |
| `OpenBurnBarEngine` | 1 | 44 | yes | `@_exported` {Kernel, LogParsers, Quota, VectorKit, Hermes, Pretext} — the UI-free daemon/CLI link surface |
| `OpenBurnBarUI` | 130 | 33,710 | yes (Apple-only) | all Views/, theme/RGBA/design-token SharedModels, PixelClock, ShareCardRenderer, LiveActivity (K4) |
| `OpenBurnBarCoreCAbi` | 5 | 878 | yes (dynamic) | the C-ABI `@_cdecl` export surface (Windows/Linux FFI): `OBBCAbi*` (P-22) + the pre-existing dylib wrapper |
| **13 targets total** | **464** | **123,667** | | (exceeds the 95.6k start because SQLiteReader/Quota carry their own scaffolding and Kernel absorbed cross-cutting utilities; the metric that matters is the Core main-target shrink above) |

**Operation 9 parser-safety ceiling adjustment (2026-07-18):** scanner-wide exact
file-identity tracking, byte/file/memory admission limits, and bounded-pass telemetry
initially raised `OpenBurnBarLogParsers` beyond its 35-file / 11,800-LOC planned ceiling.
The reusable resource, checkpoint-identity, and telemetry primitives now live in the
package-internal `OpenBurnBarParserSupport` leaf (2 files / 397 LOC), which depends only
on Kernel; LogParsers retains source-compatible public aliases and depends on the leaf.
ParserSupport has an explicit 5-file / 1,000-LOC planned ceiling. This keeps the existing
LogParsers ceiling intact instead of resetting it to fit the implementation.

**Assistant-model follow-up (2026-07-20):** post-close-out feature growth pushed
`OpenBurnBarKernel` beyond its 46,250-LOC ceiling. The Foundation-only assistant
identity and interaction cluster moved byte-for-byte into
`OpenBurnBarAssistantModels` (12 files / 2,274 LOC, including its one-line platform
support re-export). Kernel re-exports the new leaf and now contains 46,108 LOC, so
existing `import OpenBurnBarKernel` consumers keep the same API while the target is
back under its original ceiling. The new leaf is capped at 15 files / 2,700 LOC.

**Linux parity ceiling follow-up (2026-07-21):** the completed Linux source
wave added daemon-owned cloud-sync, privacy, trusted-device, and Mercury media
authority contracts to `OpenBurnBarKernel`, and added the remaining bounded
local-parser implementations to `OpenBurnBarLogParsers`. Those are legitimate
target responsibilities rather than a new generic service layer: the current
sizes are 46,447 and 12,592 LOC respectively, with file counts still at 153
and 32. The planned ceilings are therefore raised narrowly to 47,000 and
13,000 LOC (still below the next-monolith threshold), while the existing
file-count and main-target shrink gates remain unchanged. Future decomposition
work should move stable shared primitives out of these targets before adding
another domain cluster. The canonical baseline refresh also records the
measured 1.25x ceilings for the non-destination targets that received the same
Linux source wave; it does not raise any main-target or file-count budget.

**Usage-memory PR3 Kernel ceiling (2026-08-16):** Stage-0 candidate gate + SimHash + curation policy land next to existing `OpenBurnBarKernel/Memory` types (3 files / 430 LOC). Kernel measures 47,898 LOC against the prior 47,650 planned ceiling. Those files stay in Kernel because the app, tests, and offline harness share one pure `Sendable` implementation (`MemorySourceKind` already lives here). Ceiling raised narrowly to 48,000 LOC (102 lines of bounded headroom); file ceiling unchanged. Follow-up decompose is a sibling usage-memory leaf, not a same-PR target split.

**Linux-parity integration ceiling adjustment (2026-07-24):** merging the
parity integration atop the ParserSupport module-move (#1928) and the
execution-source additions measures `OpenBurnBarParserSupport` at 1,123 LOC
(the read-gate cluster moved INTO it from `OpenBurnBarLogParsers`, net-zero
across the pair) and `OpenBurnBarLogParsers` at 13,064 LOC. Ceilings move to
1,200 and 13,200 respectively (77/136 LOC of bounded headroom); file ceilings
unchanged. The shrink-only ratchet reclaims surplus automatically.

**Operation 10 execution-source ceiling adjustment (2026-07-21):** generalized
execution-source attribution adds the cross-platform usage/wire contract to
`OpenBurnBarKernel` and evidence-backed Codex history/cache attribution to
`OpenBurnBarLogParsers`. These responsibilities belong in the existing owning modules;
splitting them into dependency-only leaf targets would obscure the usage contract and
parser state boundaries. No source files were added to either target. Their planned LOC
ceilings move from 46,250 to 46,600 and from 11,800 to 12,200 respectively, covering the
measured 272/302-LOC growth with less than 160 LOC of bounded headroom per target. File
ceilings remain unchanged.

**Signal v4 Gateway runtime ceiling adjustment (2026-08-04):** the v4 Gateway and
CloudVault runtime wiring (#2180) grew `OBBSignalSessionCipherTransport.swift` with the
sealed-sender session establishment and envelope-binding verification paths, measuring
`OpenBurnBarSignalSessionTransport` at 641 LOC (2 files) against its 540-LOC measured
ceiling. Session transport is that target's sole responsibility, so the ceiling moves to
802 LOC (the standard measured 1.25x for non-destination siblings); the 3-file ceiling is
unchanged. The same change had landed the type-erased `OBBSignalGatewayEnvelopeProvider`
protocol in the dissolving main target; as a Foundation-only contract it now lives in
`OpenBurnBarKernel/Contracts` (compiled in every manifest configuration and re-exported
through the umbrella, so `import OpenBurnBarCore` consumers keep resolving it), keeping
the main target at its 11-file / 127-line shim-only baseline.

**Prime Agent + Muse parser landing ceiling adjustment (2026-08-08):** landing first-class
`PrimeAgentParser` / `MuseParser` providers (#2192) grew `OpenBurnBarLogParsers` to 13,915 LOC
(34 files) and pulled shared provider/session identity into `OpenBurnBarKernel` at 47,029 LOC
(154 files). Both clusters belong in the existing owning modules — new leaf targets would only
duplicate parser/provider boundaries. Planned ceilings move narrowly to 47,250 and 14,100 LOC
(~221/185 LOC of bounded headroom); file-count ceilings and the main-target shim baseline stay
unchanged.

**Idle usage/quota parse mining ceiling adjustment (2026-08-14):** the graphics/GRDB/quota
mining work (#2244) adds mtime+size parser caches, OpenCode JSON-only `part` reads, and
Kernel ISO-8601 / quota-refresh helpers in the existing owning modules. Measured sizes are
`OpenBurnBarLogParsers` 16,472 LOC (35 files, at the file ceiling) and `OpenBurnBarKernel`
47,446 LOC (154 files). Quota stays under its 13,000-LOC planned ceiling (12,501). New leaf
targets would only duplicate parser/quota cache boundaries already covered by
`ParserDiskCacheStore`. Planned ceilings move narrowly to 16,700 and 47,650 LOC (~228/204 LOC
of bounded headroom); file-count ceilings, Quota's ceiling, and the main-target shim baseline
stay unchanged. The deny-gate is otherwise unmodified.

**Usage-memory v61 ceiling adjustment (2026-08-16):** PR #2259 adds the byte-identical `OpenBurnBarDatabase+UsageMemoryMigrations.swift` sibling to `OpenBurnBarData` (21 files / 4,573 LOC). File ceiling moves 20 → 21; LOC ceiling stays 4,920.

### Whole-program composition proof (verbatim results)

Run on macOS (Apple Swift 6.4, Xcode 27.0 beta, arch arm64) from the isolated
`wave4-final` worktree, with the full Signal graph materialized (Vendor xcframeworks +
`libsignal` submodule) — the CI-equivalent product/test path:

| Check | Result |
|---|---|
| `cd OpenBurnBarCore && swift build` (Core product) | **Build complete!** — exit 0 |
| `swift build --target OpenBurnBarEngine` | **Build complete!** — exit 0 |
| `swift build --target OpenBurnBarUI` | **Build complete!** — exit 0 |
| `swift build --target OpenBurnBarCoreCAbi` | **Build complete!** — exit 0 (P-22: the OBBCAbi surface now lives here) |
| `swift build --build-tests` | **Build complete! (44.58 sec)** — exit 0 (`OpenBurnBarCoreTests` links; the repointed `OBBCAbiUsageScanExportTests` compiles against `import OpenBurnBarCoreCAbi`; Signal-FFI tests also link) |
| `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build` (Core) | **Build complete! (43.37 sec)** — exit 0 (Apple-free Linux-boundary manifest compiles; `LinuxLocalPeerDiscovery` builds in Kernel off-Apple) |
| `cd OpenBurnBarDaemon && swift build` | **Build complete! (3.29 sec)** — exit 0 (Engine repoint composes; daemon links Engine+Core, not CoreCAbi) |
| `scripts/debt/check-engine-closure-ui-purity.sh` | **OK: Engine closure = 9 targets, zero SwiftUI/AppKit, no UI target reachable** |
| `grep -rn 'import OpenBurnBarCore' OpenBurnBarDaemon/Sources OpenBurnBarWidget OpenBurnBarKeyboard` | **0** (umbrella fully removed from the daemon/widget/keyboard closures) |
| `check-core-ui-purity-budget.sh` | OK (baselined=0, live=0) |
| `check-core-target-membership-budget.sh` | **OK (main=11 files/127 lines = shims only, no sibling over ceiling)** |
| `check-core-umbrella-imports-budget.sh` | OK (AgentLens=522, Mobile=374 intentional; daemon/widget/keyboard=0) |
| `check-mission-splitbrain-budget.sh` | OK (11 files/3694 lines, unchanged) |
| `check-swift-file-size-budget.sh` | OK (0 oversized) |
| `check-no-suppressions.sh` | OK (no unjustified suppressions) |
| `node tools/ipc/generate-burnbarrpc-canon.mjs --check` | exit 0 (RPC wire canon byte-identical — no drift) |

**CI-covered (not runnable in the sandboxed worktree, identical on wave3-base/main,
untouched by any wave4 packet):**

- **Core `swift test` full run** — the `OpenBurnBarSignalCoreTests`,
  `OpenBurnBarSignalSessionTransportTests`, and `OpenBurnBarLinuxCoreFoundationTests`
  targets link the native `libsignal_ffi` from a **from-source Rust `nightly-2026-03-23`
  cargo build** (`Vendor/libsignal/swift/Package.swift` hard-codes `-L../target/debug/`).
  The `pr-native-fast.yml` CI job installs the Rust toolchain + protobuf and runs
  `scripts/test-openburnbar-swift.sh` to provide it. The Core **product** build is green;
  every decomposition target compiles; only these Signal-FFI-linked test *executables*
  need the native lib. This is orthogonal to the god-module decomposition (Signal targets
  were never touched by a move packet).
- **`OpenBurnBarDaemonTests` main bundle** — its `sqliteStrings()` verification helper
  opens a **SQLCipher-encrypted** DB with plain system `sqlite3_open_v2`, which returns
  **SQLITE_NOTADB (error 26)** in a worktree that links SQLCipher — the exact
  encrypted-DB / plain-SQLite mismatch documented in repo memory ("SQLite error 26 =
  NOT corruption"). The bundle **compiles** (composition proven); the failure is a
  test-harness encryption artifact, environment-specific, present identically on the
  merge base. CI runs it with the production SQLCipher/keychain wiring.
- **Headless macOS app build** (`scripts/ci/headless-app-build.sh`, scheme `OpenBurnBar`)
  — attempted locally in the worktree (local cache-reuse mode against the primary
  checkout's `.spm-cache` + Vendor); it drives the full gRPC/Firestore/app graph and is
  gated per-P-16 sub-packet by `.github/workflows/headless-app-build.yml` on
  `pull_request` for `OpenBurnBarCore/**` + `AgentLens/**`.

### Invariants held (zero-behavior-change contract)

1. **Zero behavior change** — every packet is a `git mv` + import/access-widening edit;
   apps keep `import OpenBurnBarCore` working via the 11 `@_exported` shims.
2. **Byte-identical RPC canon** — `generate-burnbarrpc-canon.mjs --check` is green; no
   wire-name drift across the whole train.
3. **Daemon is UI-free** — the Engine transitive closure is 9 pure targets with zero
   SwiftUI/AppKit; the daemon/CLI/Widget/Keyboard closures import **zero**
   `OpenBurnBarCore` (the security payoff: a daemon-reachable path can never pull UI).
4. **No regrowth** — the membership deny-gate is floored to **11 files / 127 LOC (the 11
   `@_exported` shims)**; a new `.swift` file in the Core main target now fails CI on line
   one, and any regrowth in an existing shim fails the per-file line-count check.
5. **Core ⊥ Engine, Core ⊥ CoreCAbi** — Core does not depend on Engine and Engine does not
   depend on Core (both sit above the six leaf targets; a Core↔Engine edge would be
   circular). `OpenBurnBarCoreCAbi` depends one-way on the Core umbrella (P-22); Core does
   not depend on CoreCAbi, so that edge is acyclic too.

### Rollback story

The close-out ratchet is JSON-only (`budgets/core-target-membership-baseline.json`) plus
docs — reverting it re-widens the ceiling, nothing else. Each packet is an independent
squash-mergeable PR on the stack; a single packet can be dropped by not merging its PR
(the ones above it rebase). P-21 (#1724) and P-22 (#1725) are the two additional
single-file/single-target `git mv` packets on top of `wave4-base`; each reverts cleanly on
its own (P-21 re-homes one Foundation-only file in Core; P-22 re-homes 4 files in Core and
repoints one test back). `wave4-base`/`wave4-final` are merge branches — abandoning either
loses no packet work (every packet is its own PR). The whole train is gated behind PR #1559;
nothing reaches `main` until the factory merges the stack in order.

## FINAL learnings (wave4-base integration)

11. **A completed integration base may already exist in a sibling worktree — adopt the
    committed merge, don't re-merge.** `core-decomp/wave4-base` was already built (all 11
    packets merged in order, zero conflict markers) and committed — but unpushed, in an
    idle sibling worktree with drifting build artifacts (`Package.resolved`, `.spm-cache`,
    a stale membership baseline). Re-running the 11 merges on a fresh branch would fork
    history for no benefit and confuse the factory. The integrator's job is the capstone
    (proof + numbers + ratchet floor + PR), so base the close-out on the existing committed
    merge HEAD and push a clean fast-forward superset. (Repo memory: "clean git status ≠
    lost work"; sibling agents may already hold your result.)

12. **The p-16*→p-19→p-20 chain is a linear stack; only P-15b/P-13/P-18 are real merges.**
    `git merge-base --is-ancestor` proves p-20-final contains all of p-16a…f and p-19, so
    merging in packet order fast-forwards the tail and the three standalone branches
    (each 1–3 commits on wave3-base) are the only non-trivial merges. Predict merge shape
    with ancestry checks before touching the tree; it turns "11 merges" into "3 merges + a
    fast-forward tail".

13. **`swift build` ≠ `swift test` for the Core package — the delta is native Rust
    libsignal, not the decomposition.** The product library builds fully; three
    Signal-FFI test targets fail at *link* because `Vendor/libsignal/swift/Package.swift`
    hard-codes `-L../target/debug/` (a from-source `nightly-2026-03-23` cargo artifact CI
    provisions). Copying the prebuilt `OpenBurnBarSignalFfiMac.xcframework` `.dylib` fixes
    the *product* link but not these *test* executables (different linker flag). `--skip`
    does not help — SwiftPM builds every test target before running. Diagnose by reading
    the failing link command's `-L` path, then classify as CI-covered native, not a
    composition break.

14. **SQLite error 26 in a daemon test = SQLCipher-encrypted-DB vs plain-`sqlite3_open_v2`,
    not corruption and not the decomposition.** `BurnBarProjectCodeMemoryStoreTests`'
    `XCTAssertEqual(sqlite3_prepare_v2(...), SQLITE_OK)` returns 26 (`SQLITE_NOTADB`)
    because the verification helper reads an encrypted DB with the *system* SQLite. The
    only wave4 change to that test was `import OpenBurnBarCore` → `import OpenBurnBarEngine`
    (one line) — imports cannot change runtime row counts. Confirm mechanical-only with a
    `git diff` of the touched test/impl against the merge base before suspecting a
    regression. (Repo memory: "SQLite error 26; NOT corruption".)

15. **A worktree needs its Vendor natives materialized before Swift build/test.** A fresh
    isolated worktree gets the tracked tree but not the gitignored Vendor xcframeworks
    (`OpenBurnBarSignalFfiMac/IOS.xcframework`) or an initialized `libsignal` submodule.
    `git submodule update --init Vendor/libsignal` + copying the two SignalFfi xcframeworks
    from the primary checkout unblocks the product build (they are gitignored, so they never
    pollute `git status`). The `SQLCipher.framework` also needs copying into
    `.build/.../PackageFrameworks/` for daemon test *loading* (an Xcode-27 SwiftPM
    framework-copy quirk), though that only affects runtime, not compilation.

16. **The wave4-base residual (16/1,610) was shims + C-ABI + one orphan — and the C-ABI +
    orphan were both movable.** The 11 `@_exported` shims are irreducible (they ARE the
    "keep `import OpenBurnBarCore` working" contract). But the 4 `OBBCAbi*` C-ABI files and
    `LinuxLocalPeerDiscovery.swift` were *not* — they were residual only because no packet
    had claimed them, not because they were Core-bound. P-21 + P-22 (this close-out) proved
    both moves are trivially safe, flooring Core to the true irreducible: 11 shims / 127 LOC.

17. **A `@_exported import` in a sibling makes the umbrella's whole surface visible
    module-wide — so relocating a `@_cdecl` C-ABI surface into that sibling needs ZERO
    import edits.** `OpenBurnBarCoreCAbi` already depended on the Core umbrella and its
    existing file did `@_exported import OpenBurnBarCore`. Moving the 4 `OBBCAbi*` files in
    (they reference Kernel/LogParsers types) compiled with no `import` added and no manifest
    edge added — the `@_exported` re-export already exposed Kernel+LogParsers inside the
    module. Prove this the cheap way: `git mv` then `swift build --target <dest>` BEFORE
    reasoning about which imports/edges the mission card *suggested* — the empirical build
    is authoritative, and here it made the suggested "add Engine+Insights deps" redundant.
    Corollary: the only real work was the ONE test that consumed the moved public types
    (`@testable import OpenBurnBarCore` → `import OpenBurnBarCoreCAbi` + a test-target dep),
    plus raising the destination sibling's S0-marker-era membership ceiling.

## REMAINING WORK (post-program follow-ups)

These are **deliberate, out-of-scope-for-this-program** follow-ups, not incomplete work.
The decomposition's contract (Core main-target floored, daemon UI-free, zero behavior
change) is fully met.

- **(a) ✅ DONE — `LinuxLocalPeerDiscovery.swift` (632 LOC) homed in Kernel (P-21, #1724).**
  Foundation-only, zero UI, zero Core-main symbol references; a pure `git mv` into
  `OpenBurnBarKernel/Platform/` with no import/manifest/test edit (the moved public types
  flow through Core's existing `@_exported import OpenBurnBarKernel`). Folded into
  `wave4-final`. Dropped the residual 16 → 15 files.
- **(b) ✅ DONE — S15: the 4 `OBBCAbi*` C-ABI files moved to `OpenBurnBarCoreCAbi`
  (P-22, #1725).** `OpenBurnBarCoreCAbi` already depended on the Core umbrella and
  `@_exported import`ed it, so the move was layering-safe/acyclic with no manifest dep added
  and no `import OpenBurnBarCore` in the moved files. The one test consuming the moved public
  types was repointed (`import OpenBurnBarCoreCAbi` + a test-target dep). Folded into
  `wave4-final`. This dropped the residual 15 → **11 files (shims only)** — the Core
  main-target floor is now the irreducible minimum.
- **(c) S20 app-side umbrella narrowing is ratchet-only BY DESIGN.** `AgentLens` (522) and
  `OpenBurnBarMobile` (374) intentionally keep `import OpenBurnBarCore` — they are the
  top-level app targets that legitimately consume the full surface. The umbrella-imports
  gate holds them at their current counts (no *new* umbrella imports) rather than forcing a
  mechanical fan-out to per-leaf imports across ~900 files. Narrowing them further is a
  separate, low-value ergonomics pass, not a decomposition requirement.
- **(d) M3–M5 mission-authority split-brain is a SEPARATE program.** The GUI
  mission-authority cluster (11 files / 3,694 lines, held flat by
  `check-mission-splitbrain-budget.sh`) belongs to
  `docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md` (K-series), not this Core
  decomposition. This program held that budget flat; it did not shrink it.
- **(e) The whole train awaits factory review/merge to `main`.** Every packet is a stacked
  PR behind **PR #1559** (S0, base=`main`). The factory merges the stack in order
  (S0 → wave2 → wave3/P-17 → wave4 → this close-out). Nothing here has reached `main`; the
  merge to `main` is the factory's job, gated by Codex review + branch protection.

**Signal v4 Gateway ceiling follow-up (2026-08-05):** the official Signal v4
Gateway wiring (#2180) added the sealing surface to `OpenBurnBarSignalSessionTransport`,
taking it to 641 LOC against a 540-LOC ceiling, and parked the shared
`OBBSignalGatewayEnvelopeProvider` protocol as a NEW file in the dissolving
`OpenBurnBarCore` main target, which the deny-gate forbids outright.

Two different remedies, because the two problems are not alike:

- The protocol is 13 Foundation-only lines with no Signal dependency. It moved to
  `OpenBurnBarKernel/Contracts/`, which every consumer already reaches through
  Core's re-export. `OpenBurnBarCore` is back to its exact baseline (11 files /
  127 lines), so the main target resumes shrinking rather than growing.
- The transport's own 101-line overshoot is NOT decomposed here. Splitting its
  value types into a sibling was attempted and rejected: they depend on
  `LibSignalClient` (`ProtocolAddress`, `PreKeyBundle`), so a Foundation-only
  leaf cannot hold them, and a Signal-linked leaf would need its own
  `hasLibSignalSwiftPackage` fallback plumbing — restructuring a crypto module
  as a side effect of an unrelated feature branch. The ceiling is therefore
  explicitly adjusted from 540 to 650 lines for the Gateway surface, exactly as
  the M4 contract note did for Kernel. The deny-gate remains in force: any
  further transport growth fails again, and decomposing it properly stays open
  as Signal-owned follow-up work.
