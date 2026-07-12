# Packet P-07: move TextExpansion/ → OpenBurnBarTextExpansion
STATE: QUEUED
LANE: A (serial-within-lane; owns core-ui-purity-baseline.json)          DEPENDS-ON: S0
BASELINE-TOUCHING: core-ui-purity

`TextExpansion/` is 5 files (826 LOC). It is Apple-only (pruned off-Apple via
`buildApplePrunedDecompositionTargets`) and has ZERO in-package fan-in (consumers are
AgentLens + OpenBurnBarKeyboard only). `TextExpansionKeyEventCharacters.swift` imports
AppKit and is in `core-ui-purity-baseline.json`, so moving it OUT of Core requires a
`--update` of that baseline in THIS SAME PR (the purity ratchet fails on file removal
too). This is why P-07 is in lane A — the only lane that regenerates the purity
baseline, kept internally sequential so no two open PRs regen it.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansion.swift OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/TextExpansion.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionInbox.swift OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/TextExpansionInbox.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionKeyEventCharacters.swift OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/TextExpansionKeyEventCharacters.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionSnapshotStore.swift OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/TextExpansionSnapshotStore.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TextExpansion/TextExpansionUsageStore.swift OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/TextExpansionUsageStore.swift
```
Then `git rm OpenBurnBarCore/Sources/OpenBurnBarTextExpansion/ModuleMarker.swift`.
Remove the now-empty `TextExpansion/` source dir.

### Allowed edit files (exhaustive)
- `OpenBurnBarCore/Package.swift` — DELETE `"TextExpansion"` from `openBurnBarCoreExcludes`
  (the whole directory was excluded off-Apple; now the whole directory is gone from
  Core). The target `OpenBurnBarTextExpansion` is already Apple-pruned, so no new
  off-Apple exclude is needed. Delete the exclude entry's explanatory comment too.
- `budgets/core-ui-purity-baseline.json` — regenerate via `--update` (see validation).
  This is the ONLY packet-time write to this baseline besides P-11/P-15/P-16.

## Shim
None. `@_exported import OpenBurnBarTextExpansion` (Apple-guarded) already exists in
`OpenBurnBarTextExpansionReexport.swift` (S0). Do NOT edit it.

## Forbidden actions
Standard. This packet may write `core-ui-purity-baseline.json` (BASELINE-TOUCHING);
no OTHER baseline may be `--update`d here.

## Enumerated semantic edits
None expected (consumed by AgentLens/Keyboard → already `public`).

## Pre-flight checks
1. Path-pin grep of each basename + `TextExpansion/` over the automation roots →
   expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `"TextExpansion"` MUST be in `openBurnBarCoreExcludes` and be
   deleted. `TextExpansionKeyEventCharacters.swift` imports AppKit → after the move,
   `check-core-ui-purity-budget.sh` will report it "left the UI-import set"; the
   `--update` handles that.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarTextExpansion` · V2 Core build · V3 (OMIT the PURE
check — this target is NOT in pureTargets; it legitimately carries AppKit) · V4 test ·
V5 daemon build ·
V6: `./scripts/debt/check-core-ui-purity-budget.sh --update && ./scripts/debt/check-core-ui-purity-budget.sh`
  (first regenerates dropping TextExpansionKeyEventCharacters; second must pass) ·
V7 mission-splitbrain (pre-existing single failure only) · V8 file-size · V9/V9b
membership + umbrella ratchets (membership shrink) · V11 scope (5 R100, 1 D marker,
1 M Package.swift, 1 M core-ui-purity-baseline.json).

## PR body / Acceptance
Title: "P-07: move TextExpansion/ into OpenBurnBarTextExpansion". Invariants: Apple-only
target (pruned off-Apple), ui-purity baseline ratcheted DOWN by one file, zero call-site
changes. A1–A6; A3 exception: `openBurnBarCoreExcludes` deletion + `core-ui-purity-baseline.json`
`--update` are IN scope (BASELINE-TOUCHING). A4 waived (target carries AppKit by design).
