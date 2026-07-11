# Ledger row: theme-liquid-glass / daemon-strategy / native-ffi-msvc / ci-windows-full-gate

**What this proves:** The final four residual rows ship production composition:

1. **theme-liquid-glass:** ThemeService + LiquidGlassPreferenceStore + transparency
   policy (portable preference path unit-tested).
2. **daemon-strategy:** DaemonSubstitutionMatrix is the in-product implementation of
   WPD-0006 dispositions (not a missing surface).
3. **native-ffi-msvc:** NativeFfiLoopbackProbe + NativeLibraryLocator resolve MSVC/dylib
   candidates with hardened absolute-path search; unit-tested without requiring cargo.
4. **ci-windows-full-gate:** scripts/ci/verify-windows-full-gate-workflow.sh proves
   `.github/workflows/pr-windows-full.yml` exists with dual-arch full suite composition.
   Making the check required on main remains an admin step; the gate product is in-repo.

**Tests:** windows/tests/theme, windows/tests/native/NativeFfiLoopbackProbeTests.cs,
scripts/ci/verify-windows-full-gate-workflow.sh, Daemon VM tests.
