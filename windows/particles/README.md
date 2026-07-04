# Particle engine → Win2D / Composition (Phase 3 · W6-DS-SWARM)

Windows port of the macOS **Swarm substrate** particle-render system
(`OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Substrate/` + `SwarmCanvasView.swift`):
30 substrates across 6 families (Constellation / Flow / Aurora / Mesh / Moire /
Volumetric), the additive-bloom renderer, and 4 backdrops.

## SOTA architecture — split the math from the paint

Per `docs/windows-port/PHASE3_UI_PARITY_PLAN.md` (W6-DS-SWARM): the parity-critical
**simulation math** stays in Swift Core and is vended per frame; the **renderer +
painters** are reimplemented in C# / Win2D.

```
Swift Core (already compiles on Windows, Phase 1)
  SwarmSimulation  ── murmuration (Reynolds/curl-noise), shape/glyph sampling,
                      per-particle color resolve (driver/palette/scheme)
        │  makeSubstrateFrame(...)  → immutable per-frame snapshot
        ▼
  [ FFI: obb_swarm_vend_frame ]  ── flat C ABI, float32 wire  (contract below)
        │
        ▼
C#  OpenBurnBar.Particles  (net8.0, PLATFORM-AGNOSTIC — builds + runs on macOS)
  Model/           SwarmSubstrateFrame + SwarmSubstrateDot + SubstrateStage  (1:1 Swift port)
  Math/            SubstrateKit  (TAU/clamp/lerp/frac/smooth+smootherstep/shash/breathe/XorShift32/ramps)
                   OklabColor    (perceptual OKLab ramp mix, bake-time only)
  Drawing/         ISubstrateDrawingSession  ── the seam (fill/glow/line-batch/blur + polygon/
                   rounded-quad/ring/rect/linear-gradient/oriented-shaft/dashed-batch)
                   RecordingDrawingSession   ── headless: counts commands + FNV geometry checksum
                   SubstrateGeometry         ── Vec2 + GradientStop value types
  Substrates/      PlainDots + Constellation{Starfire, StarSapphire, Stellarium, Rimefrost}
                   + Volumetric{Sunshaft, SmokedGlass, SilkFilament, DustMotes}
                   SubstrateStructure        ── O(n) kNN order/neighbors/breaks (Silk + Stellarium)
                   Catalog/                  ── SubstrateDescriptor + family registries + SubstrateCatalog
  Ffi/             SwarmSubstrateFrameFfi    ── blittable wire structs + Decode()
        │
        ▼  ISubstrateDrawingSession (the ONLY Windows-gated seam)
C#  windows/app/OpenBurnBar.App/Particles/  (Win2D — Windows-only, CI-deferred)
  Win2DSubstrateDrawingSession  ── forwards to CanvasDrawingSession
                                   (CanvasBlend.Add, CanvasRadialGradientBrush,
                                    GaussianBlurEffect, CanvasGeometry fill/stroke,
                                    FillRoundedRectangle, CanvasLinearGradientBrush,
                                    transformed shaft DrawImage, dashed stroke style)
  GlowSpriteCache               ── bakes radial glow sprites once (Swift SpriteCache analog)
  ShaftSpriteCache              ── bakes the anisotropic god-ray mask (Swift bakeShaft analog)
  SwarmCanvasHost               ── CanvasAnimatedControl draw loop (SwarmCanvasView analog)
```

Why this split wins: the painters — the bulk of the code and the *visual*-parity
surface — are compiled, unit-testable, perf-measured, and golden-testable on
macOS CI with **no GPU**. Only the thin `ISubstrateDrawingSession` → Win2D forward
is Windows-gated. `RecordingDrawingSession.Checksum` lets a Mac render and a
Windows render of the **same decoded frame** be compared command-for-command
(the W11 layout-parity gate) without pixels.

## What builds where

| Project | TFM | macOS `dotnet build` | Runs on macOS |
|---|---|---|---|
| `OpenBurnBar.Particles` | `net8.0` | ✅ green | n/a (lib) |
| `OpenBurnBar.Particles.PerfHarness` | `net8.0` | ✅ green | ✅ (`dotnet run`) |
| `windows/app/.../Particles/*` (Win2D host) | `net8.0-windows10` | ❌ Win2D is Windows-only | Windows / CI only |

## Perf harness — the ARM64 / 60fps sub-spike

`dotnet run -c Release --project OpenBurnBar.Particles.PerfHarness`
(`--dots 520,1080,2000 --frames 600 --warmup 120`)

Steps **every registered bespoke painter** over N particles for M frames against
`RecordingDrawingSession` and reports min/median/p95/p99/max frame time, effective
FPS, draw-command tallies, and the 60fps CPU-budget verdict. `--verify` runs the
parity self-check instead (FFI round-trip + per-substrate non-empty / cross-instance
determinism / warm-cache stability / reduced-motion determinism goldens).

**Measures:** the *CPU* cost of the renderer pass — particle iteration + draw-command
emission (the parity-critical, ARM64-sensitive work that is now C#).
**Does NOT measure:** GPU rasterization / additive-bloom fill-rate / Gaussian blur
— that is Win2D's job on a real device and is **Windows / CI-deferred**. The CPU
budget is *necessary but not sufficient* for the full 60fps gate; the GPU fill-rate
of thousands of overlapping large translucent discs + a full-field blur is the real
ARM64 risk and must be measured live on the dev host (see
`windows/app/DEV_HOST_RUNBOOK.md`).

### Measured on this box (Apple M-series, arm64, .NET 10 runtime, net8 target)

All bespoke painters, dark canvas, full path, **2000 dots**, 600 timed frames
(worst-case row per substrate; every dot-count × throttle scenario also PASSes):

| substrate | median ms | p95 ms | eff. FPS (median) | 60fps CPU |
|---|---:|---:|---:|:--:|
| `constellation.starfire`     | 0.140 | 0.169 | ~7,160 | PASS (~119x) |
| `constellation.starsapphire` | 0.377 | 0.470 | ~2,650 | PASS (~44x) |
| `constellation.stellarium`   | 0.093 | 0.108 | ~10,800 | PASS (~180x) |
| `constellation.rimefrost`    | 0.686 | 0.733 | ~1,460 | PASS (~24x) |
| `volumetric.sunshaft`        | 0.064 | 0.119 | ~15,700 | PASS (~262x) |
| `volumetric.smoked-glass`    | 0.118 | 0.151 | ~8,490 | PASS (~141x) |
| `volumetric.silk-filament`   | 1.158 | 1.415 | ~865 | PASS (~14x) |
| `volumetric.dust-motes`      | 0.192 | 0.276 | ~5,200 | PASS (~87x) |

CPU command-emission is nowhere near the frame budget — the heaviest painter (Silk
Filament, a single kNN-threaded strand with bucketed multi-pass strokes) sits at
~1.2 ms vs the 16.67 ms budget (~14x headroom). The takeaway for W6-DS-SWARM: the
renderer's CPU side is a non-issue even at 2000 particles; **budget the spike at the
GPU compositor**, which this harness deliberately does not (and cannot, headless)
measure.

## FFI vend contract (Swift → C#)

Precisely specified in `OpenBurnBar.Particles/Ffi/SwarmSubstrateFrameFfi.cs`:
the blittable `SwarmSubstrateFrameHeaderFfi` + `SwarmSubstrateDotFfi[]` wire layout
(float32, little-endian), the `SwarmFrameFlags` bitfield, `Decode(...)`, and the
exact `@_cdecl` Swift emitter functions to add in Phase 3
(`obb_swarm_vend_frame` / `obb_swarm_frame_header_size` / `obb_swarm_frame_dot_size`).
The Swift emitter is a thin re-pack of the existing `makeSubstrateFrame` loop
(`SwarmCanvasView+Substrate.swift`) — same dot filter, radius, `resolvedRGBA`,
centroid/cloudRadius/sizePx, and stage derivation.

## Status / next

- ✅ Renderer core + math kit + drawing seam + FFI contract — built green on macOS.
- ✅ **8 of 24 bespoke painters** — PlainDots + the full **Constellation** family
  (Starfire, StarSapphire, Stellarium, Rimefrost) + the full **Volumetric** family
  (Sunshaft, SmokedGlass, SilkFilament, DustMotes) — faithful line-for-line ports,
  plus the shared kNN `SubstrateStructure`, `OklabColor`, and the C# `SubstrateCatalog`.
- ✅ Extended drawing seam — polygon/rounded-quad/ring/rect/linear-gradient/oriented-
  shaft/dashed-batch primitives added to `ISubstrateDrawingSession` +
  `RecordingDrawingSession` (macOS-verified) + `Win2DSubstrateDrawingSession`
  (Windows-gated).
- ✅ Headless perf + parity harness — real numbers above; `--verify` green for all 8.
- ✅ Win2D host + adapter kept in sync (CanvasGeometry fill/stroke, FillRoundedRectangle,
  CanvasLinearGradientBrush, transformed shaft mask, dashed stroke) — Windows/CI-deferred
  compile+render (not build-verifiable on macOS).
- ⏳ **Windows/CI-deferred:** live render + GPU 60fps @ ARM64 measurement; the Swift
  `obb_swarm_vend_frame` emitter; the remaining **16 bespoke painters** (Flow / Aurora
  / Mesh / Moire — fanning out in sibling lanes, appending to `SubstrateCatalog`).
