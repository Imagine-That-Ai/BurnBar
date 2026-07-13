# Packet S-H: headless-app-build CI job (K4 precursor)
STATE: DONE (recipe proven locally + CI job shipped)
LANE: Integrator          DEPENDS-ON: S0
BASELINE-TOUCHING: none

K4 (S14/P-16) was deferred in the prior program on MISSING headless-app-build CI
validation. This packet adds that CI job so the Views→OpenBurnBarUI move can be proven
without a human at an Xcode GUI.

## Scope (as shipped — no source moves)
- `scripts/ci/headless-app-build.sh` — encodes the known-good headless recipe and
  builds the macOS app HEADLESS (scheme `OpenBurnBar`, `platform=macOS,arch=arm64`,
  code signing off), BUILD-ONLY (no XCTest host launch). Two modes:
  - **in-tree (CI):** a fresh runner checks out OUTSIDE `~/Documents`, so the Xcode-27
    sandbox/TCC blockers that bite a `~/Documents` checkout do not apply; a normal
    in-tree resolve + build works. This is the mode the CI job runs.
  - **local cache-reuse (`~/Documents` dev checkout, auto-detected):** reuse a sibling
    primary checkout's populated `.spm-cache` + Vendor xcframeworks via symlinks +
    `-disableAutomaticPackageResolution` (repo memory "Headless xcodebuild blocked
    (Xcode 27 Beta)" — the out-of-tree/cache-reuse path is the one that WORKS). This is
    the mode used to PROVE the recipe locally for this packet.
- `.github/workflows/headless-app-build.yml` — new merge-blocking-capable lane. Runs
  on `pull_request` to `main` (and `merge_group`) for paths `OpenBurnBarCore/**`,
  `AgentLens/**` (plus `OpenBurnBar.xcodeproj/**`, `project.yml`, the script, and the
  workflow itself — the surfaces a UI extraction can break). Mirrors the setup steps of
  `app-pr-gate.yml`/`daemon-pr-gate.yml` (submodule init, SPM cache, Rust, protobuf) but
  runs `xcodebuild build` only via the script — far lighter than the 120-min
  `app-build-test` test lane.
- `FIREBASE_SOURCE_FIRESTORE=1` is forced inside the script (iOS 27 gRPC/Firestore
  source-build guard on the resolve path).
- This job must be GREEN before any P-16 sub-packet merges (named as a required gate in
  each P-16 PR body). The job is REQUIRED-capable as shipped (it always runs when a
  matching path changes; P-16 PRs touch `OpenBurnBarCore/**`/`AgentLens/**` by
  definition, so it is never path-skipped for them). Flip it to a required status check
  in branch protection at the first P-16 sub-packet.

## Validation (proven, this packet)
- `scripts/ci/headless-app-build.sh` ran end-to-end on this worktree in local
  cache-reuse mode → `** BUILD SUCCEEDED **`, `SCRIPT_EXIT=0`, app binary produced at
  `.derived-data/headless-app-build-scripttest/Build/Products/Debug/OpenBurnBar.app/Contents/MacOS/OpenBurnBar`.
- A direct `xcodebuild build -scheme OpenBurnBar` per the raw recipe also exited 0 with
  an app binary (independent confirmation before the script existed).
- `shellcheck --severity=warning scripts/ci/headless-app-build.sh` — clean.
- `bash -n scripts/ci/headless-app-build.sh` — syntax OK.
- Error path: forced local-reuse with a bogus cache source exits 3 with a clear message.
- Workflow YAML parses; `scripts/ci/verify-github-action-pins.mjs` — all actions pinned.
- The workflow itself must go GREEN on a PR that changes nothing in the app source
  (proving the recipe, not a code change) — verified on THIS PR's CI run.
- Does NOT move any source. `project.yml`/pbxproj untouched (only a script + workflow
  file added). A1–A6 (mv list empty).

Title: "S-H: headless macOS app build CI job (K4 precursor)".
