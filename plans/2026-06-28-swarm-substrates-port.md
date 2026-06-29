# Native Swarm Substrates — porting the imaginethat-llc glyph styles into BurnBar

**Date:** 2026-06-28
**Status:** in progress
**Owner:** Alberto (via Claude / ultracode orchestration)

## Goal

Let users select the **substrate** — the visual *material* that composes the provider-glyph
swarm — exactly like the imaginethat-llc lab gallery (Image #3). Port the source's foreground
glyph-style draw idioms (Stellar Plasma, Glass Ribbon, Caustic Pool, Crepuscular Shafts, …)
into BurnBar's **native** SwiftUI `Canvas` swarm renderer, and wire a per-theme picker.

## What already exists vs. what's missing

- **Already there:** the 30 WebGL **backdrop kernels** (Constellation, Flow Field, Aurora,
  Iridescent Mesh, Moiré, Volumetric, …) ship as a hosted bundle in
  `AgentLens/Views/Dashboard/Components/KernelBackdropView.swift` (`KernelCatalog.all`) with a
  picker (`KernelBackdropSettingsRow`). This is the "themes are already there."
- **Missing:** the foreground **substrate** layer. The native provider-glyph swarm
  (`SwarmSimulation` / `SwarmCanvasView` in `OpenBurnBarCore`, shared by the mac dashboard,
  desktop wallpaper, and iOS) draws **every particle as the same plain twinkling dot**. None of
  the source's per-style `StyleModule.drawBody` idioms exist natively.

## Decisions (confirmed with Alberto)

1. **Scope:** the 6 Image #3 families × ~5 styles = **30 substrates** (24 bespoke + a shared plain).
2. **Coupling:** **per-theme**, mirroring the source — the picker shows, for the active backdrop
   kernel, that kernel's family substyles. `SubstrateFamily.forKernel(kernelID)` is the single
   coupling authority (ports the source `FAMILY_BY_WORLD` + `guessFamily`).
3. **Fidelity:** **faithful + perf-tuned** — match each source idiom (additive bloom, hot cores,
   ribbons, facets, godrays) using cached sprites + cheap math to hold 60fps with ~520–1080 dots.

## Architecture

Substrate = a **full-field painter** that draws over the existing particle cloud for one frame.
It does **not** touch the simulation (positions/velocities/colors/morphs all unchanged).

- `SwarmSubstrate` — `@MainActor protocol … : AnyObject` (reference type; ports cache
  sprites/kNN graphs). `func paint(_ frame:, into ctx:) -> Bool` (return `true` = fully handled,
  engine skips its dot/twinkle loops). `var suppressesGlyphs: Bool` (default false).
- `SwarmSubstrateFrame` — the native `rc`: `size, dark, reduced, batteryThrottled, uiMode, mode,
  formed, settleProgress, t, dt, stage(accent/accent2/ink/dark), backdrop, dots[], cx/cy/R/sizePx,
  structure`.
- `SwarmSubstrateDot` — one color-resolved non-glyph particle: `x,y,radius,rgba,opacity,inShape,
  role,slotIndex,colorIndex,flowProgress`.
- `SubstrateFamily` — `enum {constellation,flow,aurora,mesh,moire,volumetric}` mirroring `AppSkin`/
  `DashboardLayout` (storageKey, `.current`, displayName, symbolName) + `forKernel(_:)` coupling.
- `SubstrateCatalog` / `SubstrateDescriptor` — 30-entry registry; `styles(forKernel:)`,
  `resolved(forKernel:selectedID:)` (falls back to family plain when the pick's family ≠ active).
- `SubstrateKit` — shared math/RNG (`TAU,clamp,lerp,smoothstep,hash,XorShift32,breathe`), shapes
  (`drawShape`), `SpriteCache` (cached radial glow / frost / spark / ember CGImages), the
  `SubstrateStructureProvider` (NN walk + kNN, cached by topology signature), and OKLab/iris ramps.
- `PlainDotsSubstrate` — the shared plain: `paint` returns `false` so the engine's existing
  dot+twinkle+glyph render runs **unchanged** (pixel-parity default).

### Persistence (shared, mirrors `KernelBackdropPreferences`)

- `SwarmSubstratePreferences.substrateKey = "swarmSubstrate"` (default `"plain"`).
- `SwarmSubstratePreferences.enabledKey = "swarmSubstrateEnabled"` (default off).
- One global selected id; resolved per active kernel family at render time. Read identically by
  the core renderer, the macOS wallpaper host, and iOS (shared `UserDefaults.standard`).

## Coupling table (kernel id → family)

Exact for the 6 image kernels; the other 24 fall through ported `FAMILY_BY_WORLD` then a name
heuristic then `.constellation`. (`fluid-aurora`→aurora is the default kernel.) Full table lives in
`SubstrateFamily.forKernel`.

## Build order

1. **Foundation (one coherent compiling unit):** `SubstrateFamily`, `SwarmSubstrate`,
   `SubstrateKit`, `PlainDotsSubstrate`, `SubstrateCatalog` + 6 family registries, 24 **stub**
   substrates (each `paint`→`false`), `SwarmSubstrateResolver`, `SwarmSubstratePicker`. Wire
   `SwarmCanvasView` (thread `reduceMotion`+`accent`, draw hook, `makeSubstrateFrame`, extract
   `drawGlyphParticles`). **Build core green** — zero visual change (all stubs defer to engine).
2. **Fan-out (24 agents, one file each):** fill each bespoke `paint` from its source `.ts`
   `drawBody`, conforming to the frozen kit. No cross-coordination (separate files).
3. **Picker** in `AppearanceCorkboardSection` (`SwarmSubstrateSettingsRow` under the kernel row).
4. **Tests + adversarial review + build/test green** + CHANGELOG.

## The 30 substrates

| family | id | label | hint | source |
|---|---|---|---|---|
| constellation | plain | Plain | dots | `_family/defaults.ts` |
| constellation | starfire | Stellar Plasma | twinkle | `constellation/starfire.ts` |
| constellation | starsapphire | Cut Star Sapphire | facets | `constellation/starsapphire.ts` |
| constellation | stellarium | Drawn Constellation | lines | `constellation/stellarium.ts` |
| constellation | rimefrost | Dendritic Frost | frost | `constellation/rimefrost.ts` |
| flow | plankton-wake | Plankton Wake | bioluminescence | `flow/plankton-wake.ts` |
| flow | glass-ribbon | Glass Ribbon | ribbon | `flow/glass-ribbon.ts` |
| flow | silk-streamline | Silk Streamline | streamline | `flow/silk-streamline.ts` |
| flow | petal-drift | Petal Drift | petals | `flow/petal-drift.ts` |
| aurora | wisp | Wisp Plasma | will-o-wisp | `aurora/wisp.ts` |
| aurora | ice-prism | Polar Ice Prism | glacier-facets | `aurora/ice-prism.ts` |
| aurora | filament | Aurora Filament | filament | `aurora/filament.ts` |
| aurora | drift-motes | Drift Motes | spores | `aurora/drift-motes.ts` |
| mesh | mesh-caustic | Caustic Pool | caustics | `mesh/mesh-caustic.ts` |
| mesh | mesh-patch | Gradient Patch | patches | `mesh/mesh-patch.ts` |
| mesh | mesh-isoline | Iso Contour | contours | `mesh/mesh-isoline.ts` |
| mesh | mesh-grain | Living Grain | grain | `mesh/mesh-grain.ts` |
| moire | fringe-bloom | Fringe Bloom | fringes | `moire/fringe-bloom.ts` |
| moire | lattice-facet | Lattice Facet | crystal | `moire/lattice-facet.ts` |
| moire | ruling-grating | Ruling Grating | gratings | `moire/ruling-grating.ts` |
| moire | film-bubble | Film Bubble | bubbles | `moire/film-bubble.ts` |
| volumetric | sunshaft | Crepuscular Shafts | godrays | `volumetric/sunshaft.ts` |
| volumetric | smoked-glass | Smoked Glass Slab | glass | `volumetric/smoked-glass.ts` |
| volumetric | silk-filament | Silk Filament | filament | `volumetric/silk-filament.ts` |
| volumetric | dust-motes | Dust Motes | motes | `volumetric/dust-motes.ts` |

(Plus a `plain` descriptor per family — all six reuse the one `PlainDotsSubstrate`.)

## Risks & mitigations

- **Perf** (~520–1080 dots × bloom): sprite-heavy families use `SpriteCache` resolved images
  (never per-point gradients); stroke families batch one `Path` per pass; `structure` rebuilds only
  on topology change.
- **Blast radius** (wallpaper + iOS share the renderer): default `plain` ⇒ identical to today; a
  `substrate` param defaulting to `nil` keeps all 11 `SwarmCanvasView` call sites source-compatible.
- **Additive blend:** the engine sets no blend mode; substrates set `ctx.blendMode = dark ?
  .plusLighter : .normal` on a local copy. `.drawingGroup(colorMode:.nonLinear)` already gives a
  Metal layer.
- **Reduced motion:** newly threaded into `draw()`; each substrate renders its "poised still" frame.
- **Light/dark:** every port honors `frame.dark` for compositing + core/halo balance.

## Source of truth

- Design: workflow `wf_945f5691-613` (extracted to `/tmp/substrate-design/`).
- Native renderer map: `SwarmCanvasView.swift:267-287` (Particle), `:690-813` (draw),
  insertion at `:693`; `accent` `:26` and `reduceMotion` `:48` are the two threads.
- Source kit contract: `imaginethat-llc/src/glyph/stage/styles/kit-*.ts`, `_family/defaults.ts`.
