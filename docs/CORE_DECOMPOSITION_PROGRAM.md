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
| `OpenBurnBarKernel` | yes (exists) | ~39k | root mission contracts (NOT SearchContracts — see wave-1 learnings), TraceContext, pure/crypto SharedModels, MissionGroupContracts + MissionConsoleTypes (post-inversion), catalog loader + PII gate + their resources, Platform/ | FirestoreModels, crypto |
| `OpenBurnBarSQLiteReader` | **no** | 325 | `Services/SQLite/` + the SQLite backend conditional. The K3 fix. | SQLite backend |
| `OpenBurnBarLogParsers` | yes | ~9.3k | `Services/LogParser/` + `Services/LogPath/` + 2 log-discovery SharedModels | Kernel, SQLiteReader |
| `OpenBurnBarQuota` | yes | ~10.4k | `ProviderQuota/` + root `XAISuperGrokPacingLog.swift` | Kernel, SQLiteReader, crypto |
| `OpenBurnBarVectorKit` | yes | ~4.5k | HNSW/Persistent/Signpost vector indexes, VectorIndexDelta, SearchPlanner, **SearchContracts** (re-sliced from Kernel — depends on VectorKit types), Pensieve chunker/cloak | Kernel |
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
| `budgets/core-target-membership-baseline.json` | Never touched by packets (deny-gate; shrink is non-fatal; `plannedCeiling` end-state ceilings seeded once at S0-repair and preserved by `--update`). Integrator lands JSON-only ratchet-down PRs per merged wave. |
| `budgets/core-umbrella-imports-baseline.json` | Shrink-only. Integrator ratchets a root to zero after its repoint packet (daemon S17, widget S18, keyboard S19). |
| Consumer repoints (project.yml/pbxproj) | Integrator-only serial packets, between waves. |
| Canon-bearing moves | None in S1–S13 (canon generator only reads `OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift` + `BurnBarRPCIPCCanon.generated.swift`; the root mission contracts S3 moves are NOT canon sources — verified). |

## Regrowth gates (landed in S0)

1. **`scripts/debt/check-core-target-membership-budget.sh`** + `budgets/core-target-membership-baseline.json`
   — deny-gate: any NEW `.swift` in `Sources/OpenBurnBarCore/` fails CI; main-target
   totals may only shrink. Non-decomposition siblings have a measured 1.25× {files, LOC}
   ceiling; decomposition DESTINATIONS carry an explicit `plannedCeiling` (~1.25× their
   end-state) that the gate enforces and `--update` preserves, so a packet FILLING a
   destination is allowed up to its planned end-state (wave-1 learning — see § Wave-1
   learnings). Shrink is non-fatal (`Improved: … run --update`, exit 0).
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

## Wave-1 learnings (S0 repair — read before running any move packet)

Wave-1 executors correctly BLOCKED on four SYSTEMIC defects in the S0 scaffold/cards (not
bad moves). All four were fixed ONCE on the scaffold branch (PR #1559 follow-up) so every
packet re-runs from a corrected card. Later waves inherit these policies.

**Defect 1 — membership-gate sibling ceilings captured at marker size.** S0 generated
`budgets/core-target-membership-baseline.json` while each decomposition sibling held only
`ModuleMarker.swift`, giving a ~2-file/10-line ceiling. Any packet FILLING a sibling (its
whole purpose) blew that ceiling; the sibling-ceiling check fires BEFORE the non-fatal-shrink
branch, so it hard-FAILed CI. **Fix:** each decomposition destination now carries an explicit
`plannedCeiling` (seeded at ~1.25× its architecture end-state) that the gate enforces and
`--update` preserves verbatim — a partial fill can never ratchet a destination's ceiling below
its end-state. Non-decomposition siblings keep the measured 1.25× ceiling. Planned ceilings:
SQLiteReader 3/450, LogParsers 35/11700, Quota 55/13000, VectorKit 12/5800 (incl.
SearchContracts), Insights 100/20000, Hermes 10/1800, Pretext 5/850, TextExpansion 8/1100,
LaunchServices 12/6100, UI 160/40000, Engine 3/60, and Kernel 166/49000 (Kernel is the largest
destination — wave-1 alone pushes it to ~131 files/38.1k LOC, over its S0 measured 35955-line
ceiling; sized to its ~39.3k end-state). Negative-tested three ways (fill-within-ceiling PASS;
exceed-planned-ceiling FAIL; new-Core-file FAIL). Main-target rules unchanged (new file = FAIL,
growth = FAIL, shrink = non-fatal `run --update`).

**Defect 2 — cross-module imports on moved files (EDIT-CLASS 1).** A file moved out of the
monolith into a standalone target needs explicit `import <Dep>` for symbols that were
same-module before (e.g. `HermesAtomNavigator.swift` uses `PlatformLogger` from Kernel; the
Insights model files use `AgentProvider`/`BurnBarWidgetError`/etc. from Kernel). This is
mechanical, not judgment. **Fix:** every move card now authorizes adding `import <Dep>` to
MOVED files ONLY, where `<Dep>` is a DECLARED dependency of the destination target, exactly as
the compiler demands; each added line is enumerated in the PR body. Adding `import
OpenBurnBarCore` to a moved file is FORBIDDEN (it would invert the layering — destinations sit
below Core). `PlatformLogger` is already `public` in Kernel (both `#if canImport(OSLog)`
branches), so P-05 needs only the import, no access-level change.

**Defect 3 — `@testable` internal access across the new module boundary (EDIT-CLASS 2).**
`OpenBurnBarCoreTests` reaches `internal` members of moved files via `@testable import
OpenBurnBarCore`; the `@_exported` shim carries PUBLIC symbols across modules but NOT internal
ones under `@testable`. So moving a file whose test reaches its internals breaks the test
build (P-02 → `MemorySecretPIIGateTests` internal `_evaluate`/`LoadedCorpus`; P-07 →
`TextExpansionTests` internal `usKeyboardCharacter`). **Fix:** every move card now authorizes
adding `@testable import <NewTarget>` beneath the existing `@testable import OpenBurnBarCore`
in the failing `OpenBurnBarCoreTests` file (no test-logic/assertion changes, no test-file
moves), with a pre-flight grep of the test dir for the moved basenames/type names to
anticipate which test files need it, enumerated per card.

**Defect 4 — dependency-closure re-slices.** `OpenBurnBarSearchContracts.swift` references
`BurnBarEmbeddingDistanceMetric` + `BurnBarSearchPlan` (both VectorKit-bound), so it CANNOT
precede them into the leaf Kernel target. **Fix:** removed from P-03 (now 6 files, verified
closed) and moved to **P-14 (VectorKit)** with SearchPlanner + the vector index files (the
daemon reaches it via the Engine umbrella, so Kernel-residency is unnecessary). A symbol-level
closure re-check of P-04a surfaced two more forward-refs into Core-staying UI types:
`SubstrateFamily.swift` (uses `RGBA`, 12 calls) and `SubscriptionTopic.swift` (binds the Apple
`Views/Cards/CardEnvelope`) — both **relocated to P-16 (UI)** where `RGBA`/`CardEnvelope` land
(P-04a is now 10 files). Off-Apple safety confirmed (no off-Apple code consumes either type;
all real consumers are Apple). P-04b, the other P-03 files, and the remaining P-04a files are
dependency-closed. Cross-packet ordering note: P-04a's `CLIRuntimeModelCatalog.swift` calls
`BurnBarCatalogLoader` (moved to Kernel by P-02), so P-02 must merge before P-04a (both target
Kernel; the ref then resolves cross-module in Kernel).

## Packet status

Every packet ends as `MERGED`, `CLOSED`, or `OPEN_WITH_NAMED_BLOCKER`. Full cards
(exact enumerated `git mv` lists) exist for wave-1 (P-01…P-10); draft cards (scope +
`TO-ENUMERATE-AT-WAVE`) exist for later slices. Cards live in
`plans/core-decomposition/packets/`; the lane-ordered pull queue is
`plans/core-decomposition/QUEUE.md`.

Wave-1 packets are re-queued for wave-1b after the S0 repair (gate ceilings +
import/@testable card policies + P-03 re-slice — see § Wave-1 learnings). P-06 and P-00
already have open PRs.

| Packet | Slice | Target | Lane | Card | STATE |
|---|---|---|---|---|---|
| P-00 | — | mission-splitbrain baseline RAISE (unblocks wave) | Integrator | n/a | PR_OPEN #1560 |
| P-01 | S1 | OpenBurnBarSQLiteReader | B | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-02 | S2 | Kernel resources (catalog+PII+ops staging) | Integrator | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-03 | S3 | root contracts → Kernel (6 files; SearchContracts re-sliced to P-14) | D | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-04a | S4 | SharedModels pure → Kernel (10 files; SubstrateFamily+SubscriptionTopic re-sliced to P-16) | D | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-04b | S4 | SharedModels crypto chains → Kernel | D | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-05 | S9 | OpenBurnBarHermes | D | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-06 | S10 | OpenBurnBarPretext (+resources manifest edit) | D | full | PR_OPEN #1561 (unblocked by S0 gate repair) |
| P-07 | S11 | OpenBurnBarTextExpansion | A | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-08 | S12 | Insights — Services core engine | C | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-09 | S12 | Insights — Services remainder | C | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-10 | S12 | Insights — SharedModels + AgentInsights models | C | full | QUEUED (wave-1b re-run pending S0 repair) |
| P-11 | S5 | MissionGroupContracts + MissionConsoleTypes inversion → Kernel | A | draft | QUEUED |
| P-12 | S6 | OpenBurnBarLogParsers | B | draft | QUEUED |
| P-13 | S7 | OpenBurnBarQuota | C | draft | QUEUED |
| P-14 | S8 | OpenBurnBarVectorKit (+SearchContracts re-sliced from P-03) | D | draft | QUEUED |
| P-15 | S13 | OpenBurnBarLaunchServices | A | draft | QUEUED |
| P-16a…f | S14 | OpenBurnBarUI (K4) — by Views subdirectory | A | draft | QUEUED |
| P-17 | S16 | OpenBurnBarEngine umbrella (fill) | Integrator | draft | QUEUED |
| P-18 | S17 | daemon/CLI repoint → OpenBurnBarEngine | Integrator | draft | QUEUED |
| P-19 | S18 | Widget repoint | Integrator | draft | QUEUED |
| P-20 | S19 | Keyboard repoint | Integrator | draft | QUEUED |
| S-H | — | headless-app-build CI job (precursor to S14) | Integrator | draft | QUEUED |

## Sizing

10–25 files / 2,000–5,000 LOC per packet; hard cap 30 files / 6k LOC / 3 semantic
edits. Whole-directory packets may exceed file count but not the LOC cap. ~88k
movable LOC → ~26 move packets + S0 + S-H + 3 repoints + ~4 ratchet-down PRs + 1
close-out ≈ 35 PRs; ~6–8 per lane; ~5–7 waves.
