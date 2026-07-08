# Core Engine Extraction Plan — unbundling UI from `OpenBurnBarCore`

> Status: **PLAN** (follow-up to the 2026-07-08 diligence review, improvement #6).
> Owner: TBD. Effort: **L/XL, incremental**. This is a refactor, not a rewrite — no behavior change.

## Problem

`OpenBurnBarCore` has become a 106K-LOC kitchen-sink library that fuses three concerns that
should be separable:

| Measured (audit/full-snapshot-20260708) | Value |
|---|---|
| `OpenBurnBarCore/Sources/OpenBurnBarCore` LOC | 106,292 |
| SwiftUI `View` files **inside the shared core** | 109 |
| `import AppKit` files inside core | 14 |
| Untyped `[String: Any]` Firebase-boundary sites (Apple apps) | 1,204 |

Because the **daemon** (`OpenBurnBarDaemon`) and **privileged-input** binaries transitively link
`OpenBurnBarCore`, they pull in SwiftUI/AppKit and the full UI surface. Consequences:

1. **Trusted Computing Base bloat** — privileged binaries link UI code they never execute,
   enlarging the attack/rebuild surface.
2. **Rebuild blast radius** — any change in the UI half of core forces a rebuild of the daemon
   and every consumer.
3. **Portability tax** — Linux/Windows already need a UI-free subset, currently maintained by
   `#if os(...)` exclude lists in `Package.swift` (see "head start" below).

## Head start (do not ignore)

`OpenBurnBarCore/Package.swift` **already** carves an "Engine subset" of Core for Linux/Windows via
documented `#if os(...)` exclude lists (≈ lines 351–483). That exclude list is, in effect, a
hand-maintained inventory of *what is not UI/Apple-only*. **This is the seed of the extraction** —
we promote that implicit subset into a first-class target instead of inventing the boundary from
scratch.

## Target module graph

```
OpenBurnBarKernel      (NEW) — pure engine: parsing, quota, budget, hermes, memory, crypto,
   ▲   ▲                        data models, services. NO SwiftUI, NO AppKit/UIKit. Links on
   │   │                        every platform. This is what the daemon + privileged binaries link.
   │   └── OpenBurnBarDaemon, privileged-input, Linux/Windows engine  ── link Kernel ONLY
   │
OpenBurnBarUI          (NEW) — SwiftUI/AppKit views, view-models, backdrop/GL glue.
   ▲                           Depends on Kernel. Apple apps link UI (+ Kernel).
   └── AgentLens (macOS), OpenBurnBarMobile (iOS), Widget, Keyboard
```

`OpenBurnBarCore` remains temporarily as an umbrella re-exporting `Kernel + UI` so no consumer
breaks during migration, then is retired.

## Phases (each independently shippable, each green before the next)

**Phase 0 — Fence the boundary (S).**
- Add a build/lint gate that FAILS if any file in the (future) Kernel source set contains
  `import SwiftUI` / `import AppKit` / `import UIKit`. Seed its file list from the existing
  Linux `#if os` exclude list. This makes the boundary a ratchet before we move anything.

**Phase 1 — Extract `OpenBurnBarKernel` (L).**
- Create the target. Move the non-UI domain folders that are already Linux-safe
  (`Services/LogParser/`, `ProviderQuota/`, `Budget/`, `Hermes/`, `Memory/`, `Entitlements/`,
  `Engine/`, `SharedModels/`, data/crypto) into it, guided by the exclude list.
- Keep `OpenBurnBarCore` compiling by having it depend on and re-export `Kernel`.
- Repoint **daemon + privileged binaries** to link `OpenBurnBarKernel` directly. Verify they no
  longer transitively import SwiftUI (grep the linked module graph).

**Phase 2 — Extract `OpenBurnBarUI` (L).**
- Move the 109 View files + 14 AppKit files into `OpenBurnBarUI` depending on `Kernel`.
- Point Apple apps at `UI`. `OpenBurnBarCore` umbrella now = `Kernel + UI`.

**Phase 3 — Retire the umbrella (M).**
- Migrate remaining `import OpenBurnBarCore` sites to `Kernel` or `UI` as appropriate; delete the
  umbrella. (Can be mechanical + codemod-assisted.)

**Phase 4 — Collapse the split-brain (separate, coordinated — see report §8.2).**
- With a clean `Kernel`, the GUI-app mission engine (`AgentLens/Services/OpenBurnBarOperating/`,
  12 files) and the daemon engine (`.../MissionControl/`, 17 files) can converge onto one
  Kernel-hosted trust/approval authority. Security-sensitive — do under its own review.

## Validation per phase
- Full build of every product (Apple + Linux + Windows engine) green.
- Daemon/privileged binary module graph contains **zero** SwiftUI/AppKit (grep `swiftc -emit` deps
  or the linked frameworks).
- Existing test suites pass unchanged (no behavior change is the whole point).
- Binary size of daemon drops (record before/after as evidence).

## Risks & mitigations
- **Hidden UI→engine coupling** surfaces as build breaks when the fence goes up → that is the
  point; fix by moving the offending type to Kernel or inverting the dependency.
- **Merge churn** against a fast-moving tree (700+ commits/wk) → do phases as small, fast PRs;
  land Phase 0 fence first so regressions can't reopen the boundary mid-migration.
- **`Package.swift` cycles** — the file already documents one previously-fixed cycle (≈ lines
  496–518); keep the Kernel dependency-free of UI to avoid reintroducing one.

## Definition of done
Daemon and privileged binaries link `OpenBurnBarKernel` only; no SwiftUI/AppKit in their graph; a
CI fence keeps it that way; `OpenBurnBarCore` umbrella retired; all suites green; daemon binary
smaller.
