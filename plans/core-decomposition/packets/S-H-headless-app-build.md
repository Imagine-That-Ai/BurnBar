# Packet S-H (DRAFT): headless-app-build CI job (K4 precursor)
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0
BASELINE-TOUCHING: none

K4 (S14/P-16) was deferred in the prior program on MISSING headless-app-build CI
validation. This packet adds that CI job so the Views→OpenBurnBarUI move can be proven
without a human at an Xcode GUI.

## Scope
- New `.github/workflows/` job (or a step in an existing app gate) that builds the
  macOS app HEADLESS using the known-good recipe: out-of-tree worktree + reuse main's
  populated `.spm-cache` + `-disableAutomaticPackageResolution` + symlinked Vendor +
  scheme `OpenBurnBar` (XcodeGen-driven). Reference the working recipe in the BurnBar
  memory notes ("Headless xcodebuild blocked (Xcode 27 Beta)" — the out-of-tree worktree
  path is the one that WORKS).
- FIREBASE_SOURCE_FIRESTORE=1 at resolve+build (iOS 27 gRPC/Firestore requirement) if
  the app scheme includes the iOS target.
- This job must be GREEN before any P-16 sub-packet merges (named as a required gate in
  each P-16 PR body).

## Validation
- The job itself must go green on a PR that changes nothing in the app (proving the
  recipe, not a code change).
- Does NOT move any source. project.yml untouched (only a workflow file added).
Title: "S-H: headless macOS app build CI job (K4 precursor)". A1–A6 (mv list empty;
only a workflow file added).
