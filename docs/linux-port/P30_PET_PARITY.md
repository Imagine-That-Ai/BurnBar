# P-30 Linux pet companion capability slice

**Status:** implementation slice landed; Tier A parity remains blocked pending a
real compositor/window proof and a native companion window contract.

## Difference

macOS presents the PetCompanion as an ambient animated desktop companion in a
non-activating transparent panel. It can remain visible above other windows,
accept interaction, and be summoned without turning the dashboard into the
companion itself. The Linux shell currently has a route-contained GLB preview.
It does not yet have a canonical Linux window, summon shortcut, selection/chat,
or file-drop contract.

The old Linux route inferred overlay support from `XDG_SESSION_TYPE` and
`XDG_CURRENT_DESKTOP`, which could label KDE/Sway/other Wayland sessions as
pass-through even though those variables do not prove compositor behavior.

## Why it matters

An optimistic click-through claim can steal focus, intercept pointer input, or
leave an always-on-top window covering other applications. It also makes the
Linux UI look complete while the core macOS workflow is absent. Users need a
clear distinction between a local preview, a contained fallback, and a proven
desktop overlay.

## Recommended solution

1. Keep the route-contained GLB preview as the safe fallback.
2. Consume the typed `runtime_capabilities` manifest for `pet.overlay`; never
   use environment variables as packaged UI proof.
3. Require both an available manifest entry and a canonical companion-window
   native contract before enabling overlay/input-pass-through rows. A manifest
   entry by itself only describes compositor potential; it does not prove that
   this shell has wired a transparent window or pointer policy.
4. `degraded`, `unavailable`, missing, or failed probes render the contained
   draggable fallback and explain the substitute.
5. Show explicit unavailable rows for summon and selection/chat/file-drop until
   canonical native commands and a permission/focus contract exist.
6. Add a dedicated native companion window only after the implementation has a
   compositor-specific probe, lifecycle/restart handling, multi-monitor policy,
   reduced-motion/GPU budget, and an installed-environment evidence harness.

## Priority

**High.** This slice removes a correctness and trust failure, but it does not
claim to close the full macOS feature gap.

## Implementation notes

- `probePetCapability()` is the single UI decision point. It returns the tier,
  state, source, compositor label, substitute, and action-level reasons.
- A missing manifest fails closed to a contained preview. The preview may still
  render the bundled asset and local wave highlight; it must not imply desktop
  input behavior.
- X11 remains an evidence-only environment hint in
  `detectPetTierFromEnv()` for the existing matrix harness. The packaged route
  does not call it.
- No daemon RPC, global shortcut, window creation, or OS-level input injection
  is invented in this slice.
- Tier A remains blocked until evidence exists on GNOME/KDE/Sway Wayland and
  X11 for focus, topmost, click-through, drag, scaling, reduced motion,
  multi-monitor placement, restart, and GPU fallback.

## QA verification

Automated checks for this slice:

- `npx vitest run src/petCompanion.test.ts src/surfaces/PetSurface.test.tsx src/surfaces/SurfaceRouter.test.tsx --reporter=dot`
- `npx tsc --noEmit`
- `npm run build`
- `node scripts/verify-linux-bundle.mjs`
- `cargo test --manifest-path src-tauri/Cargo.toml`
- `cargo fmt --manifest-path src-tauri/Cargo.toml -- --check`
- `node scripts/check-linux-macos-diff.mjs`

Installed-app checks still required before promotion:

1. Start the packaged app with no runtime manifest and confirm the route says
   preview-only, is draggable, and reports overlay/input/summon/selection as
   unavailable.
2. Feed a manifest with `pet.overlay=degraded` and confirm no
   `data-input-passthrough="true"` appears.
3. Feed a manifest with `pet.overlay=available` and confirm the route still
   stays contained until an explicit native companion-window contract is
   supplied; no overlay/input-pass-through claim appears.
4. Verify that stale `XDG_*` values cannot switch a degraded manifest back to
   overlay mode.
5. On each supported desktop/compositor, record real focus, pointer,
   click-through, topmost, scaling, reduced-motion, multi-monitor, restart,
   and failure evidence. Do not promote this slice on synthetic environment
   variables alone.
