# P-30 Linux pet companion capability slice

**Status:** the compositor-aware implementation, Linux-native companion
chat/file-drop slice, macOS-shaped pet catalog/avatar selection, and legacy 2D
atlas runtime are ready at source level. The generated catalog contains 114
unique entries, including 112 GLB-backed entries and three atlas forms (two
atlas-only plus one hybrid). The installed-candidate proof package is not yet
registered in the product workflow, and Tier A parity remains blocked until the
exact signed candidate passes all seven compositor and architecture
environments. macOS's offscreen 3D thumbnail pipeline, persona/local-floor
behavior, behavior-driven state transitions, and compositor receipts remain
open.

## Difference

macOS presents the PetCompanion as an ambient animated desktop companion in a
non-activating transparent panel. It can remain visible above other windows,
accept interaction, and be summoned without turning the dashboard into the
companion itself. The Linux shell has a route-contained animated GLB preview,
an X11-only Tauri companion child, the native `Ctrl+Alt+Super+P` summon chord,
explicit click-through enable/restore, contained selection/clear, and bounded
pointer and keyboard repositioning, and a compact daemon-backed companion chat
bubble. Dropping a supported file on the pet opens the bubble and stages the
attachment through the same bounded upload policy as the full chat composer;
the full chat pop-out remains available. Wayland correctly remains contained.
Linux now loads a generated catalog of 114 shared PetCompanion entries,
supports search/group filtering, persists the selected avatar, and reads only
the selected GLB or legacy atlas image from packaged Tauri resource
directories. Atlas-backed selections render the source frame grid with the
macOS-compatible row/frame math and reduced-motion behavior. macOS's
offscreen 3D thumbnail pipeline, persona/local-floor behavior, and installed
proof of the chat/drop/catalog flows remain outside the current P-30
certification claim.

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
3. Require both an available manifest entry and the
   `tauri-x11-companion-v1` window contract before enabling overlay and input
   pass-through. A manifest entry by itself is not proof.
4. `degraded`, `unavailable`, missing, or failed probes render the contained
   draggable fallback and explain the substitute.
5. Keep selection/clear, repositioning, contained chat, and bounded file-drop
   staging available in the contained fallback; never turn them into an
   unproven desktop-overlay claim.
6. Keep the generated pet catalog in lockstep with both shared macOS
   `Resources/Models` and legacy `Resources/Pets` `petdef.json` resources;
   load selected GLBs and atlas images through bounded native readers rather
   than copying the entire asset set into the web bundle.
7. Promote only after the installed evidence harness proves the same signed
   candidate across GNOME X11, GNOME Wayland, KDE Wayland, and Sway on the
   required architectures.

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
- `scripts/linux-port/run-p30-native-pet-probes.mjs` launches only the installed
  desktop, captures the live runtime manifest, drives real AT-SPI controls, and
  uses X11 window-manager inspection only where the product advertises the
  native overlay tier.
- `scripts/linux-port/materialize-p30-pet-session.mjs` confines owner-only raw
  evidence, copies the installed signed manifest, and binds the session to the
  candidate run, digest, version, environment, and HEAD.
- `scripts/linux-port/capture-p30-pet-proof.mjs` emits the closure artifact and
  registration descriptor only after the full session validates.
- `PetChatBubble` reuses the daemon-authoritative `useChatStore`, the existing
  gateway capability checks, and `chat_attachment_upload`; it does not create a
  second credential, transcript, or filesystem-path boundary.
- `PetSurface` accepts picker and drag-and-drop files through the shared
  `inspectChatAttachment()` policy. Unsupported types and files over 10 MiB are
  rejected visibly before any bytes cross the bridge.
- `scripts/linux-port/generate-linux-pet-catalog.mjs` derives the Linux catalog
  from the committed macOS `Resources/Models/*/petdef.json` and
  `Resources/Pets/*/petdef.json` files. The Tauri shell packages those
  resources under `pet-models` and `pet-atlas`, exposing bounded, allowlisted
  GLB and atlas readers with source-tree fallback only for development.
- The Linux picker matches the macOS library's practical controls: search,
  category groups, selected-state semantics, persisted avatar choice, and
  default-form selection. The selected legacy atlas form now renders through
  a bounded Canvas2D frame runtime. The offscreen 3D thumbnail pipeline and
  thumbnail-backed picker cards remain open.
- The verifier rejects screenshot or AT-SPI replay, forged click-through,
  optimistic Wayland capability, missing focus/status/shortcut metadata,
  failed relaunch, package substitution, and incomplete process restoration.
- Tier A remains blocked until evidence exists on GNOME/KDE/Sway Wayland and
  X11 for focus, topmost, click-through, drag, scaling, reduced motion,
  multi-monitor placement, restart, and GPU fallback.

## QA verification

Automated checks for this slice:

- `node --test scripts/linux-port/p30-native-pet-probes.test.mjs scripts/linux-port/p30-pet-proof.test.mjs`
- `node --test scripts/linux-port/generate-linux-pet-catalog.test.mjs`
- `npx vitest run src/petCompanion.test.ts src/petCatalog.test.ts src/surfaces/PetSurface.test.tsx src/surfaces/pet/PetChatBubble.test.tsx src/surfaces/SurfaceRouter.test.tsx --reporter=dot`
- `npm run typecheck`
- `npm run lint`
- `npm run build`
- `node scripts/linux-port/verify-linux-production-bundle.mjs`
- `cargo test --manifest-path src-tauri/Cargo.toml --lib`
- `cargo fmt --manifest-path src-tauri/Cargo.toml --all -- --check`
- `bash scripts/ci/check-no-suppressions.sh`
- `node --test scripts/linux-port/run-platform-differential.test.mjs`

Installed-app checks still required before promotion:

1. Run the installed P-30 probe from an empty owner-only evidence directory and
   an isolated HOME; no other installed desktop process may be running.
2. On X11, verify the global chord creates exactly one always-on-top child,
   click-through is opt-in, and interaction is restored before teardown.
3. On Wayland, verify the runtime manifest is degraded/unavailable, no native
   child is claimed, and the focused contained summon remains usable.
4. Select and clear the pet, reposition it with pointer and keyboard, reset it
   with Home, and verify each live status plus focused AT-SPI node.
5. Open the pet library, search by display name and group, select a different
   3D avatar, select Claude Code, Goose, or Hugging Face to exercise the legacy
   atlas form, restart the app, and verify that the selected id and form are
   restored from the same packaged resource set.
6. Open companion chat, send a text turn, drop a supported Markdown/text file,
   confirm the staged attachment is visible before sending, and verify
   unsupported/oversized files are rejected without upload.
7. Relaunch and verify a new PID, the same honest compositor tier, cleared stale
   interaction state, distinct screenshots/AT-SPI snapshots, and exact daemon
   and desktop process restoration.
8. Materialize and capture against the signed candidate, then run the P-30
   product validator in all seven support environments. Registration and
   certification remain separate integration steps.
