# Packet P-20 (DRAFT): repoint OpenBurnBarKeyboard → TextExpansion + Kernel (S19)
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0, P-07 (OpenBurnBarTextExpansion populated)
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarKeyboard/ to zero)

The keyboard extension imports the umbrella in exactly 2 files. Repoint onto
TextExpansion + Kernel.

## Scope
- `project.yml` — the Keyboard target's package product dependency changes from
  `OpenBurnBarCore` to `OpenBurnBarTextExpansion` + `OpenBurnBarKernel` (integrator-only;
  XcodeGen regen; xcodegen-drift passes).
- The 2 keyboard files' `import OpenBurnBarCore` → `import OpenBurnBarTextExpansion`
  (+ `import OpenBurnBarKernel` if the compiler demands).
- `budgets/core-umbrella-imports-baseline.json` — `--update` (OpenBurnBarKeyboard/ → 0).

## Validation
- Keyboard extension builds. xcodegen-drift green. Umbrella ratchet OpenBurnBarKeyboard/ = 0.
Title: "P-20: repoint OpenBurnBarKeyboard onto TextExpansion+Kernel". A1–A6;
BASELINE-TOUCHING core-umbrella-imports. A3 exception: project.yml/pbxproj IN scope.
