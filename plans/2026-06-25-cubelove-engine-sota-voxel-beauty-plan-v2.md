# CubeLove Engine — SOTA Voxel Beauty (v2, research-grounded)

> **Status:** **Greenlit (full A–D, incl. macOS)** · supersedes v1 after adversarial audit + June-2026 SOTA research
> **Created:** 2026-06-25
> **Decisions locked:** SceneKit stays the primary pet renderer (voxel-pet = flagged experiment only) · full Milestone A→D arc approved (~6 mo team / 9–12 mo solo)
> **Repos:** [BurnBar](file:///Users/albertonunez/Documents/Developer/BurnBar) + [imaginethat-llc](file:///Users/albertonunez/Documents/Developer/imaginethat-llc)
> **Look target:** hookuru-class voxel city — Voxy LOD horizon + Photon-style colored voxel GI, golden hour, emissive bloom, aerial haze
> **North star:** One **shared Rust + WGSL** voxel engine; web on WebGPU; macOS on the same WGSL via wgpu **plus** Metal 4 / MetalFX where it pays.

---

## What changed since v1 (why this is a rewrite, not an edit)

The v1 plan was directionally right (rip the Canvas2D/SceneKit defaults, go GPU voxel) but rested on three wrong or stale assumptions. June-2026 research corrects them:

| v1 assumption | June-2026 reality | Source |
|---|---|---|
| "WebGPU Safari gaps" is a top risk | **WebGPU is GA in Safari 26 / macOS Tahoe 26 / iOS 26** since fall 2025, compute shaders included. Target OS 26+. | [web.dev](https://web.dev/blog/webgpu-supported-major-browsers), [WebKit](https://webkit.org/blog/16993/) |
| Hand-write MSL denoise + dual WGSL/MSL port | **Metal 4 (WWDC Jun 2025) ships MetalFX Denoising + Frame Interpolation + HW ray tracing on M3+.** Apple demoed Cyberpunk 2077 path tracing on Mac. Don't hand-write the denoiser. | [AppleInsider](https://appleinsider.com/articles/25/06/09/metal-4-game-porting-toolkit-3-boost-frame-rate-ray-tracing-performance), [flatpanelsHD](https://flatpanelshd.com/news.php?id=1749809641&subaction=showfull) |
| "SVT64" + "SVRaster LOD" are the frontier | The real 2026 frontier is **SVDAG/brickmap + Aokana (streaming/LOD) + NAADF (ReSTIR voxel GI, open MIT code)**. SVRaster is *neural radiance-field* rendering, not a game-LOD lighting system — v1 mis-cited it. | below |
| Invent a bespoke `.cvxl` format | **NanoVDB** is the GPU-portable sparse-voxel format (WebGL/HLSL/GLSL/CUDA readers, in-core compression, streaming) already adopted by Arnold/Blender/Houdini/Omniverse. Adopt it; don't reinvent. | [NVIDIA](https://developer.nvidia.com/nanovdb) |

**Net effect:** the platform is far more ready than v1 feared, the macOS denoiser is now free, and the engine should be **one WGSL codebase** with a thin Metal-only post-stage — the opposite of v1's hand-maintained dual port.

---

## The actual June-2026 SOTA (what to build on, not from scratch)

| Technique | What it gives us | Reference |
|---|---|---|
| **SVDAG** (sparse voxel DAG) | The dominant compressed voxel structure; DAG dedup ~4× smaller than SVO | [Avoyd devlog](https://www.enkisoftware.com/devlogpost-20230823-1-Implementing-a-GPU-Voxel-Octree-Path-Tracer) |
| **Pointer-encoded SVDAG** | +10–25% traversal speed, color + live-edit compatible (CGF, Nov 2025) | [Modisett & Billeter, CGF](https://onlinelibrary.wiley.com/doi/10.1111/cgf.70292) |
| **Aokana** (I3D 2025) | Multi-*shallow* SVDAG forest + GPU-driven Hi-Z/visibility-buffer pipeline + **LOD + streaming**: tens of billions of voxels, ~9× less VRAM, 2–4.8× faster than HashDAG, **~5% of scene resident**. This is the *city-to-horizon* answer. | [arXiv 2505.02017](https://arxiv.org/abs/2505.02017) |
| **NAADF** (Eurographics 2026, TU Wien, **MIT licensed**) | Globally-illuminated voxel worlds: nested 4³ voxel→4³ block→4³ chunk bricks + axis-aligned distance fields for empty-space skip (3–5× over DAG) + **ReSTIR-style GI** with 32-frame temporal history + 8×8 spatial resampling + **editing/dynamic entities**. This is the *lighting* answer, and it's open source. | [paper](https://onlinelibrary.wiley.com/doi/10.1111/cgf.70413) · [github cg-tuwien/NAADF](https://github.com/cg-tuwien/NAADF) |
| **NanoVDB** | GPU-portable sparse-volume storage/streaming, 3-level 4096³/128³/8³ tree (8³ leaf ≈ a brickmap brick), in-core compression, random-access decompress | [NVIDIA](https://developer.nvidia.com/nanovdb) |
| **Metal 4 / MetalFX** | HW ray tracing (M3+), **Denoising** (ray-reconstruction analog), **Frame Interpolation** (30→60 perceived), tensors in MSL | [Metal](https://developer.apple.com/metal/) |
| **WebGPU** | GA everywhere incl. Safari 26; WGSL compute; HDR canvas | [Implementation Status](https://github.com/gpuweb/gpuweb/wiki/Implementation-Status) |

**Forkable open code (don't start from a blank file):**
- **shocovox** — [SVO in WGSL + Rust](https://github.com/davids91/shocovox) — closest WebGPU-native starting point.
- **VoxelRT** + [the sparse-64-tree guide](https://dubiousconst282.github.io/2024/10/03/voxel-ray-tracing/) — brickmap/Tree64 traversal, the structure to copy.
- **NAADF** (above) — port the GI pipeline HLSL→WGSL.
- **strahl** — [WebGPU + OpenPBR path tracer](https://github.com/StuckiSimon/strahl) — reference for the WGSL path-trace loop.

> ⚠️ **Sober finding from the VoxelRT author:** state-of-the-art SVO traversal can be *up to 60% slower* than a simpler hierarchical grid / brickmap. **Do not over-engineer the tree.** Start with NanoVDB-leaf brickmap + DDA; add SVDAG dedup only where the bench proves it wins. ([guide](https://dubiousconst282.github.io/2024/10/03/voxel-ray-tracing/))

---

## Corrected architecture: one engine, two backends, one format

v1's mistake was a *hand-maintained* WGSL+MSL split. The corrected design shares everything expensive and splits only the platform-locked post-stage:

```
packages/cubelove-engine  (Rust core, compiles to WASM + native staticlib)
├── world/      NanoVDB load/stream + palette/material/emissive sidecar   ← format
├── build/      brickmap → optional SVDAG dedup (pointer-encoded)         ← Aokana-style
├── stream/     chunk ring + LOD manager (~5% resident)                   ← Aokana-style
├── scene/      camera rigs, petcore behavior bridge, light/sun state
└── render/
    ├── wgsl/    traversal + ReSTIR-lite GI + TAA   ← SINGLE shader source (NAADF port)
    ├── web      wgpu→WebGPU; WGSL spatial-temporal denoiser
    └── macos    wgpu→Metal for traversal/GI; **MetalFX Denoise + Frame-Interp** post
                 optional HW-RT brick intersection on M3+
```

**Key decisions, each resolving a v1 audit question:**

1. **Single-source WGSL traversal + GI** runs on both platforms via `wgpu`. (Resolves v1 Q2 — no dual hand-port.)
2. **macOS post-stage is native Metal.** The noisy radiance + G-buffer (depth/normal/motion) hand off to **MetalFX Denoising + Frame Interpolation** via `wgpu`'s `as_hal` escape hatch. Web uses a WGSL denoiser. This is the *only* justified platform split — and it buys Apple's production denoiser for free. ⚠️ **wgpu↔MetalFX interop is not yet first-class** (requires `as_hal` to extract `MTLTexture`); **Phase 0 spikes this** and picks a fallback if it's too raw. ([wgpu HAL](https://github.com/gfx-rs/wgpu/blob/trunk/CHANGELOG.md))
3. **NanoVDB is the world format** + a thin sidecar (palette RGBA, material flags, emissive mask, baked GI probes). Authoring (MagicaVoxel, Break Room `voxelScene.ts`) exports to it. (Resolves v1 Q5 — no bespoke `.cvxl`.)
4. **HW ray tracing is an M3+ accelerant, not the foundation.** Software brickmap DDA is the baseline everywhere; HW-RT brick intersection is a macOS fast-path added late.
5. **The pet stays on SceneKit.** Metal 4 makes SceneKit better too. Voxel-pet-in-engine ships behind a flag, last, never as the forcing function. (Resolves v1 Q3 — see "What we keep.")

---

## What we keep (corrected from v1's over-aggressive rip list)

v1 wanted to rip `SceneKitPetRenderer.swift`. Audit found it's **1,087 lines** of mature, tested code: GLTFKit2 → `GLTFSCNSceneSource`, per-clip `SCNAnimationPlayer` keyed by petdef clip names, pause/resume, form-swap, camera framing — exercised ~10× in `PetDefinitionTests.swift`, backed by a committed GLTFKit2 SPM dependency.

**Keep, do not rip:**
- **SceneKit pet renderer** — voxelizing skinned GLB pets *destroys* skeletal clip animation and makes the cute mascot blocky. A path-traced menu-bar pet also runs a continuous compute loop = battery regression. Pet-in-engine is a **flagged experiment**, behind `high`-tier gates, AC-only.
- `VOXEL_WORLD_BLUEPRINT.md` motion/FX spec; `packages/petcore` behavior graphs; Break Room `voxelScene.ts` authoring (now a *NanoVDB exporter*, not deleted); the 8 Canvas2D glyph styles (optional foreground); `scripts/sync-imagine-pets.sh` contract.

**Rip (confirmed correct in v1):** Canvas2D `voxelRenderer.ts` (CPU painter, cannot scale), WebGL2 voxel kernels (`createShaderKernel.ts` voxel path), Quarry `voxelKernel.ts`, `model-viewer` neutral-IBL pets — but **only after** the GPU path reaches parity screenshots, keeping one release as fallback.

---

## Honest performance budgets (to be *validated*, not asserted)

v1's budgets were internally contradictory (a Phase-1 exit of "≥1 MRays/s @ 720p" certifies a **~1 fps** renderer while the `high` tier demands ~1 GRays/s). No public FPS-on-Apple-Silicon numbers exist for these techniques, so **Phase 0's bench harness establishes the real envelope before any tier is promised.** Targets below are hypotheses the bench must confirm/correct:

| Tier | Scene | Web (WebGPU, no MetalFX) | macOS (Metal 4 + MetalFX) |
|---|---|---|---|
| `preview` | pet panel 192×208, primary + baked GI | 15 fps, ≤3 ms GPU | 15 fps, ≤3 ms; idle pet = **0 GPU** (kept) |
| `high` | Break Room / 1 city block, 1080p, 1 bounce + soft shadows | ~30 fps native, temporal-accumulate when still | **30 fps native → 60 perceived** via Frame-Interp; Denoise lets us cast fewer rays |
| `ultra` | gallery hero / city, 1080p, ReSTIR GI | 30 fps for moderate scenes; **hero shots use baked GI + accumulation** | 30–60 with Denoise; HW-RT on M3+ |
| `cinematic` | screenshot/video capture, any scene | offline accumulate N frames → reference-quality still | same |

**Two honesty rules baked in:**
- **Screenshot/video parity is allowed to bake and accumulate.** Hero stills don't need live multi-bounce; `cinematic` tier accumulates. This is how hookuru-class *images* are cheap even when live city GI is hard.
- **"City to horizon" ≠ "60 fps everywhere."** City scale leans on Aokana streaming (~5% resident) + LOD impostors + aggressive temporal reuse; the bench sets the real sustained ray budget per platform.

**Phase-1 exit is rewritten** to a meaningful gate: *sustained ≥X MRays/s at 1080p primary on M2 and on an M3, where X is set by the Phase-0 bench to be ≥60-fps-capable for the `high` Break Room scene* — not a fixed number plucked from air.

---

## Timeline — honest scope, real MVP first

v1 promised an 18-week two-repo greenfield engine + ReSTIR + city + macOS + audio. That's **9–12 months solo / ~6 months small team**, not 18 weeks. This plan front-loads a genuine *parity-of-look* MVP and earns the research-grade features after.

### Milestone A — "Parity of look," web-first (≈ weeks 1–8) ← ship this first

Goal: a browser fly-through that *looks* hookuru-class, on real assets, with the cheapest engine that achieves it.

- **A0 (wk 1):** Spec + **bench harness** (Stanford bunny + 64³ room + 1 city block) reporting MRays/s on M2/M3 and a dGPU. **Spike wgpu↔MetalFX interop.** Sets all real budgets.
- **A1 (wk 2–4):** Fork **shocovox/VoxelRT** → WGSL brickmap + DDA traversal over **NanoVDB**-backed bricks. Export Break Room `voxelScene.ts` → NanoVDB. Standalone `cubelove-viewer`.
- **A2 (wk 4–6):** Sun + soft shadows + **baked colored GI** (offline flood-fill into the sidecar; sample at runtime) + emissive bloom + aerial fog + ACES. This alone reproduces the hookuru *look*.
- **A3 (wk 6–8):** One hero Break Room + one authored city block, golden-hour rig, `cinematic` capture. **Side-by-side vs hookuru reference board.** ← parity screenshot/video here.

**Checkpoint after A (not a kill gate — full arc is greenlit):** with real bench numbers in hand, *re-scope* B/C/D — confirm the ReSTIR port budget, the city LOD strategy, and the wgpu↔MetalFX path chosen in A0. Adjust tactics, not the destination.

### Milestone B — Live GI + streaming city (≈ weeks 9–16)

- **B1:** Port **NAADF** GI (HLSL→WGSL): ReSTIR-lite, 32-frame temporal history, AADF empty-space skip. Replace baked GI with live in `ultra`.
- **B2:** **Aokana**-style LOD + chunk streaming (~5% resident) → 4×4 km core + procedural outskirts to horizon, no pop-in (LOD cross-fade < 3 frames).
- **B3:** Optional pointer-encoded SVDAG dedup *iff* the bench shows it beats the brickmap baseline.
- **B4:** City audio bed (ambient + altitude wind + traffic).

### Milestone C — macOS BurnBar (≈ weeks 14–20, overlaps B)

- **C1:** `CubeLoveMetalRenderer` — same WGSL traversal/GI via wgpu→Metal into `CAMetalLayer`.
- **C2:** **MetalFX Denoise + Frame-Interp** post via `as_hal` (or fallback chosen in A0). HW-RT brick intersection on M3+.
- **C3:** Pet in streamed plaza chunk; `.nvdb` sync via `sync-imagine-pets.sh`. **SceneKit stays primary**; CubeLove pet behind feature flag, AC-only, `high` tier.
- **Perf contract preserved:** paused pet = 0 GPU; preview ≤3 ms @ 192×208; Pet World `high` ≤8 ms @ 720p, disabled on battery.

### Milestone D — Frontier polish (post-20, optional)

Transform-aware SVDAG compression; many-light ReSTIR DI for dense city emissives; online voxel fusion (Teardown-class edits/destruction); MetalFX neural upscaling tuning.

---

## Web integration (replaces v1 Phase 4, unchanged in spirit)

- New `createWebGPUKernel()` alongside WebGL; migrate worlds incrementally. Gallery `voxel` world → CubeLove full-screen. Deprecate Quarry `voxelKernel` (1 release fallback, then delete).
- `BreakRoom.tsx` → `<CubeLoveCanvas world="break-room" />` + `world="neo-tokyo"`; delete Canvas2D `voxelRenderer.ts` after parity screenshots.
- `WebNpc3D.tsx` → engine-native voxel rig **only if** A/B prove it looks good; otherwise keep model-viewer for pets and use CubeLove for *worlds*. Glyphs: Canvas2D foreground over GPU background.

---

## Cross-repo contracts

| Artifact | Owner | Consumer |
|---|---|---|
| `packages/cubelove-engine` (Rust core + WGSL) | imaginethat-llc | web (WASM) + BurnBar (staticlib) |
| `.nvdb` + material sidecar on CDN | imaginethat-llc `public/worlds/` | web fetch + macOS bundle |
| `packages/petcore` petdef + optional `voxelRig` | imaginethat-llc | `sync-imagine-pets.sh` → BurnBar |
| Golden PNG CI (perceptual diff ≤1%) | both | regression gate |

---

## Risks (re-grounded)

| Risk | Likelihood | Mitigation |
|---|---|---|
| **wgpu↔MetalFX interop too raw** for Denoise/Frame-Interp | Med | **A0 spike.** Fallbacks: (a) native Metal renderer on macOS accepting one extra MSL GI path, or (b) WGSL denoiser on macOS too (lose MetalFX quality, keep single-source). |
| City-scale live GI misses 60 fps on M-series | Med-High | Tiers + Aokana streaming + temporal accumulation + `cinematic` baked capture for stills; MetalFX Frame-Interp on macOS. |
| Over-engineering the tree (SVO slower than grid) | Med | Brickmap+DDA baseline first; SVDAG only if bench wins. |
| NAADF HLSL→WGSL port cost | Med | It's MIT and the canonical GI reference; budget B1 fully; baked GI (A2) ships the look meanwhile. |
| Solo bandwidth vs scope | High | Milestone A is independently shippable and delivers the visible win; B/C/D are opt-in with a data-driven gate. |
| Older macOS/iOS (< 26) lack WebGPU | Low-Med | Feature-detect; WebGL Quarry fallback 1 release; native Metal path on macOS regardless. |

---

## v1 audit questions — answered with research

1. **Perf budgets achievable on Apple Silicon?** Not as v1 stated, and v1's own Phase-1 gate was ~1 fps. **The bench (A0) sets real budgets**; macOS gets MetalFX Denoise + Frame-Interp to close the gap; city scale relies on streaming + accumulation, not brute 60 fps.
2. **Dual WGSL+MSL vs single shared engine?** **Single-source WGSL via wgpu** for traversal+GI on both platforms; only the MetalFX post-stage is native Metal. v1's hand-maintained dual port is rejected.
3. **Does ripping SceneKit break ship constraints?** **Yes** — GLTFKit2 skinned clips don't survive voxelization and the mascot looks worse blocky. **Keep SceneKit primary**; voxel pet is a flagged experiment.
4. **Is 18 weeks realistic?** No. **Milestone A (≤8 wk)** delivers parity-of-look; the full vision is two more quarters, gated on A's data.
5. **Does `.cvxl` duplicate NanoVDB?** Yes — **adopt NanoVDB** + a thin material sidecar; keep authoring exporters.
6. **Min path to parity in <8 weeks?** **Milestone A:** fork shocovox/VoxelRT → WGSL brickmap over NanoVDB + **baked** colored GI + sun/shadow/bloom/fog + one hero scene + `cinematic` capture. Baking and accumulation are how the *images* get cheap.

---

## Todos

- [ ] **cl-a0** — Spec + bench harness (MRays/s on M2/M3/dGPU) + **wgpu↔MetalFX interop spike** + hookuru reference board + real budget table
- [ ] **cl-a1** — Fork shocovox/VoxelRT → WGSL brickmap/DDA over NanoVDB; Break Room → `.nvdb` exporter; standalone viewer
- [ ] **cl-a2** — Sun + soft shadows + baked colored GI + bloom + aerial fog + ACES (the look)
- [ ] **cl-a3** — Hero Break Room + 1 city block + golden-hour rig + `cinematic` capture; parity board ← **MVP ships here**
- [ ] **cl-b1** — Port NAADF GI (HLSL→WGSL): ReSTIR-lite + 32-frame temporal + AADF empty-space skip
- [ ] **cl-b2** — Aokana LOD + chunk streaming (~5% resident) → city to horizon
- [ ] **cl-b3** — Pointer-encoded SVDAG dedup (only if bench wins) + **cl-b4** city audio
- [ ] **cl-c1** — `CubeLoveMetalRenderer` (wgpu→Metal) in `CAMetalLayer`
- [ ] **cl-c2** — MetalFX Denoise + Frame-Interp post; HW-RT brick intersection (M3+)
- [ ] **cl-c3** — Pet in plaza chunk; `.nvdb` sync; SceneKit stays primary, CubeLove pet behind flag
- [ ] **cl-d** — Frontier polish: transform-aware SVDAG, ReSTIR DI, online voxel fusion

---

## Sources

- WebGPU GA / Safari 26: [web.dev](https://web.dev/blog/webgpu-supported-major-browsers) · [WebKit](https://webkit.org/blog/16993/) · [Implementation Status](https://github.com/gpuweb/gpuweb/wiki/Implementation-Status)
- Metal 4 / MetalFX: [Apple](https://developer.apple.com/metal/) · [AppleInsider](https://appleinsider.com/articles/25/06/09/metal-4-game-porting-toolkit-3-boost-frame-rate-ray-tracing-performance) · [flatpanelsHD](https://flatpanelshd.com/news.php?id=1749809641&subaction=showfull)
- NAADF (EG 2026): [paper](https://onlinelibrary.wiley.com/doi/10.1111/cgf.70413) · [code (MIT)](https://github.com/cg-tuwien/NAADF)
- Aokana (I3D 2025): [arXiv 2505.02017](https://arxiv.org/abs/2505.02017)
- Pointer-encoded SVDAG (CGF Nov 2025): [Wiley](https://onlinelibrary.wiley.com/doi/10.1111/cgf.70292)
- NanoVDB: [NVIDIA](https://developer.nvidia.com/nanovdb)
- Voxel-64-tree guide + VoxelRT: [dubiousconst282](https://dubiousconst282.github.io/2024/10/03/voxel-ray-tracing/)
- shocovox (WGSL SVO): [github](https://github.com/davids91/shocovox) · strahl (WebGPU PT): [github](https://github.com/StuckiSimon/strahl)
- Photon + Voxy (hookuru stack): [Photon](https://github.com/sixthsurge/photon) · [Voxy modpacks](https://www.curseforge.com/minecraft/modpacks/voxy-with-shaders)
- wgpu HAL interop: [CHANGELOG](https://github.com/gfx-rs/wgpu/blob/trunk/CHANGELOG.md)
