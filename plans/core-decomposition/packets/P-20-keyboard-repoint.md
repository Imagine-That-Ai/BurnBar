# Packet P-20 (DRAFT): repoint OpenBurnBarKeyboard → TextExpansion + Kernel (+ UI) (S19)
STATE: BLOCKED(compile-closure) — undeclared DEPENDS-ON P-16 (UI/K4). Re-slice required.
LANE: Integrator          DEPENDS-ON: S0, P-07 (OpenBurnBarTextExpansion populated), **P-16 (OpenBurnBarUI populated — NEW, see Compile-closure blocker)**
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarKeyboard/ to zero)

The keyboard extension imports the umbrella in exactly 2 files. Repoint onto
TextExpansion + Kernel **+ UI** (the narrow set is compiler-driven; see blocker).

## Compile-closure blocker (recorded 2026-07-13, integrator-executor, COMPILE-CLOSURE authority)

The card's premise — "both files use only TextExpansion (+ maybe Kernel) symbols, so
swap `OpenBurnBarCore` → `OpenBurnBarTextExpansion` + `OpenBurnBarKernel`" — is TRUE for
`KeyboardViewController.swift` but **FALSE for `KeyboardView.swift`**, which also
references a UI/K4 symbol. Repointing as carded produces a RED tree (`cannot find
'UnifiedDesignSystem' in scope`). This is the same defect class as program learning 9
(compile-closure surfaces undeclared edges that grep-by-import/grep-by-path miss).

Machine-derived evidence (on `origin/core-decomp/wave3-base`, tip `a3b048f30f`):
- The 2 umbrella-importing files (umbrella baseline `OpenBurnBarKeyboard` count=2):
  - `OpenBurnBarKeyboard/KeyboardViewController.swift:3` — uses ONLY
    `TextExpansionSnippet` / `TextExpansionSnapshotStore` / `TextExpansionUsageStore` /
    `TextExpansionMatcher`. All resolve in `OpenBurnBarTextExpansion`. ✅ repointable.
  - `OpenBurnBarKeyboard/KeyboardView.swift:2` — uses `TextExpansionSnippet` /
    `TextExpansionKeyboardComposer` (✅ TextExpansion) **AND**
    `UnifiedDesignSystem.Colors.{ember,error,textMuted}` at 7 sites
    (lines 379, 398, 433, 490, 601, 623, 640).
- `UnifiedDesignSystem` is a `public enum` that `import SwiftUI` and is defined ONLY in
  `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/UnifiedDesignSystem.swift` — the OLD
  Core (umbrella) target's `Views/` dir, architecturally destined for **`OpenBurnBarUI`
  (K4)** per the end-state map (all `Views/` → UI).
- `OpenBurnBarUI` is **marker-only** (`ModuleMarker.swift`) on EVERY core-decomp branch
  tip — P-16 (S14/UI) has not landed anywhere. So `UnifiedDesignSystem` is nowhere but
  the umbrella target.
- Neither `OpenBurnBarKernel` (a `pureTargets` member — SwiftUI/AppKit forbidden, so
  `UnifiedDesignSystem` categorically cannot live there) nor `OpenBurnBarTextExpansion`
  defines or re-exports `UnifiedDesignSystem`; there is no bridge in any `*Reexport.swift`.
- ∴ dropping `import OpenBurnBarCore` from `KeyboardView.swift` loses the only provider.
  AE-IMPORT forbids `import OpenBurnBarCore` (inverts layering); no other DECLARED/populated
  product supplies the symbol; adding a manifest dep edge or pulling UI forward is out of
  scope for a repoint packet (and `product: OpenBurnBarUI` is EMPTY today anyway).

**Cross-check with QUEUE.md:** it lists P-20 DEPENDS-ON `P-07` only, while the sibling
P-19 Widget repoint DEPENDS-ON `P-16 (UI), P-10`. P-20 should mirror P-19: it too has a
UI/K4 dependency (via `KeyboardView`'s `UnifiedDesignSystem` use). The DAG's `S18 …◄┘`
join back to the S19 line already hints S19 depends on S14 (UI); the card/QUEUE
DEPENDS-ON simply omitted it.

## Re-slice required (architect)
Add **DEPENDS-ON P-16 (UI/K4)** and re-schedule P-20 into **Wave 3 (after P-16 lands)**,
alongside P-19 Widget repoint. Once `OpenBurnBarUI` is populated (`UnifiedDesignSystem`
moved into it), the narrow repoint set becomes:
- `KeyboardViewController.swift` → `import OpenBurnBarTextExpansion` (Kernel only if the
  compiler then demands it — no Kernel symbol is referenced today).
- `KeyboardView.swift` → `import OpenBurnBarTextExpansion` + `import OpenBurnBarUI`
  (+ Kernel only if demanded).
- `project.yml` Keyboard target: package product `OpenBurnBarCore` → the demanded narrow
  products (`OpenBurnBarTextExpansion` + `OpenBurnBarUI`, ± `OpenBurnBarKernel`), regen
  the committed `OpenBurnBar.xcodeproj/project.pbxproj` via
  `xcodegen generate --spec project.yml` (the `xcodegen-drift` job in
  `.github/workflows/pr-native-fast.yml` diff-checks it via
  `scripts/ci/verify-xcodegen-pbxproj-drift.py`), and flag it (first project.yml-touching
  repoint) in the PR body.
- Then `scripts/debt/check-core-umbrella-imports-budget.sh --update` (Keyboard root → 0).

An alternative (NOT recommended, out of program scope) would be to extract only
`UnifiedDesignSystem` early into UI; rejected because P-16 owns the whole `Views/`
extraction and a piecemeal early move fights lane A's serial ui-purity baseline.

## Scope (POST-P-16; unchanged mechanics + the UI product)
- `project.yml` — the Keyboard target's package product dependency changes from
  `OpenBurnBarCore` to the compiler-demanded narrow set (`OpenBurnBarTextExpansion` +
  `OpenBurnBarUI`, ± `OpenBurnBarKernel`) (integrator-only; XcodeGen regen; xcodegen-drift
  passes).
- The 2 keyboard files' `import OpenBurnBarCore` → the demanded narrow imports.
- `budgets/core-umbrella-imports-baseline.json` — `--update` (OpenBurnBarKeyboard/ → 0).

## Validation
- Keyboard extension builds (CI native/mobile compile gate). xcodegen-drift green.
  Umbrella ratchet OpenBurnBarKeyboard/ = 0.
Title: "P-20: repoint OpenBurnBarKeyboard onto TextExpansion+UI(+Kernel)". A1–A6;
BASELINE-TOUCHING core-umbrella-imports. A3 exception: project.yml/pbxproj IN scope.
