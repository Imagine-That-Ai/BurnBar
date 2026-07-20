# Packet P-19 (DRAFT): repoint OpenBurnBarWidget → Kernel + Insights + UI (S18)
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0, S14 (OpenBurnBarUI populated), P-10 (Insights models)
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarWidget/ to zero)

The widget imports the umbrella in 17 files. Repoint them onto the narrow targets it
actually uses: Kernel + Insights + UI.

## Scope
- `project.yml` — the Widget target's package product dependencies change from
  `OpenBurnBarCore` to `OpenBurnBarKernel` + `OpenBurnBarInsights` + `OpenBurnBarUI`.
  This IS a project.yml/pbxproj-affecting change → integrator-only, XcodeGen regen in
  the same PR, `xcodegen-drift` job must pass.
- Per-file `import OpenBurnBarCore` → the narrow import the compiler demands, across the
  17 widget files.
- `budgets/core-umbrella-imports-baseline.json` — `--update` (OpenBurnBarWidget/ → 0).

## Validation
- Widget builds (macOS app + widget extension via xcodebuild, reusing main's .spm-cache
  + -disableAutomaticPackageResolution).
- xcodegen-drift green. Umbrella ratchet shows OpenBurnBarWidget/ = 0.
Title: "P-19: repoint OpenBurnBarWidget onto Kernel+Insights+UI". A1–A6;
BASELINE-TOUCHING core-umbrella-imports. A3 exception: project.yml/pbxproj change is
IN scope for this integrator repoint packet.
