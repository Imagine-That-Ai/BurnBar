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
  Math/            SubstrateKit  (TAU/clamp/lerp/frac/smoothstep/shash/breathe/XorShift32/ramps)
  Drawing/         ISubstrateDrawingSession  ── the seam
                   RecordingDrawingSession   ── headless: counts commands + FNV geometry checksum
  Substrates/      PlainDotsSubstrate + StarfireSubstrate ("Stellar Plasma")
  Ffi/             SwarmSubstrateFrameFfi    ── blittable wire structs + Decode()
        │
        ▼  ISubstrateDrawingSession (the ONLY Windows-gated seam)
C#  windows/app/OpenBurnBar.App/Particles/  (Win2D — Windows-only, CI-deferred)
  Win2DSubstrateDrawingSession  ── forwards to CanvasDrawingSession
                                   (CanvasBlend.Add, CanvasRadialGradientBrush,
                                    GaussianBlurEffect, CanvasGeometry strokes)
  GlowSpriteCache               ── bakes radial glow sprites once (Swift SpriteCache analog)
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

Steps the Starfire painter over N particles for M frames against
`RecordingDrawingSession` and reports min/median/p95/p99/max frame time, effective
FPS, draw-command tallies, and the 60fps CPU-budget verdict.

**Measures:** the *CPU* cost of the renderer pass — particle iteration + draw-command
emission (the parity-critical, ARM64-sensitive work that is now C#).
**Does NOT measure:** GPU rasterization / additive-bloom fill-rate / Gaussian blur
— that is Win2D's job on a real device and is **Windows / CI-deferred**. The CPU
budget is *necessary but not sufficient* for the full 60fps gate; the GPU fill-rate
of thousands of overlapping large translucent discs + a full-field blur is the real
ARM64 risk and must be measured live on the dev host (see
`windows/app/DEV_HOST_RUNBOOK.md`).

### Measured on this box (Apple M-series, arm64, .NET 10 runtime, net8 target)

Starfire / "Stellar Plasma", dark canvas, full bloom+cross path, 600 timed frames:

| dots | path | median ms | p95 ms | eff. FPS (median) | draw cmds | 60fps CPU |
|---:|---|---:|---:|---:|---:|:--:|
| 520 | full | 0.109 | 0.158 | ~9,200 | 2,082 | PASS (153x headroom) |
| 1080 | full | 0.125 | 0.161 | ~8,000 | 4,322 | PASS (133x) |
| 2000 | full | 0.110 | 0.146 | ~9,100 | 8,002 | PASS (152x) |
| 1080 | throttled | 0.026 | 0.104 | ~38,000 | 2,160 | PASS |

CPU command-emission is nowhere near the frame budget (~0.1 ms vs 16.67 ms). The
takeaway for W6-DS-SWARM: the renderer's CPU side is a non-issue even at 2000
particles; **budget the spike at the GPU compositor**, which this harness
deliberately does not (and cannot, headless) measure.

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
- ✅ PlainDots + Starfire (Constellation) painters — faithful line-for-line ports (#1202).
- ✅ **Mesh family** (Caustic Pool, Gradient Patch, Iso Contour, Living Grain) +
  **Moiré family** (Fringe Bloom, Lattice Facet, Ruling Grating, Film Bubble) — 8 more
  faithful line-for-line ports under `Substrates/Mesh/` + `Substrates/Moire/`, registered
  in the C# `SubstrateCatalog`. Consumed the existing `ISwarmSubstrate` + `SwarmSubstrateFrame`
  + `RecordingDrawingSession` pattern unchanged.
- ✅ **Drawing seam extended** (the subset of `CanvasDrawingSession` these families use):
  `FillPolygon` (triangular facet lattices), `FillRoundedRectGradient` + `StrokeRoundedRect`
  (Gradient-Patch stained-glass panes via `CanvasLinearGradientBrush`), `StrokeCircle`
  (Film-Bubble rims), `PushRadialMaskLayer` (Ruling-Grating full-field feather via
  `AlphaMaskEffect`), a `GlowProfile` on `DrawGlowSprite` (glow / glass-sphere / spark),
  and a `layerOpacity` on `PushBlurLayer` (Living-Grain haze). Implemented in all three
  sinks: interface + `RecordingDrawingSession` (counts + FNV checksum) + the Windows
  `Win2DSubstrateDrawingSession` / `GlowSpriteCache` forwards.
- ✅ Ported `SubstrateStructureProvider` (the grid-based k-NN / NN-order graph) that the
  Mesh "Caustic Pool" refracted filament net (connected-node lattice) is built from;
  `SwarmSubstrateFrame` now carries a lazily-built `Structure` (injectable so the sim can
  reuse the topology cache across frames).
- ✅ Headless perf harness now benchmarks **all 9 painters × {free-swarm, shape}** and
  `--verify` proves each renders **deterministically** (stable checksum + counts) and is
  **FFI-transparent** in both regimes. Every substrate clears the 60fps CPU budget with
  16×–225× headroom (see numbers above / the harness output); heaviest is Caustic-Pool
  shape mode (median ~0.71 ms, k-NN rebuilt as the topology drifts).
- ✅ Win2D host + adapter kept buildable (Windows-gated): the new seam methods forward to
  `CanvasGeometry.CreatePolygon` / `CreateRoundedRectangle`, `CanvasLinearGradientBrush`,
  `DrawCircle`, `AlphaMaskEffect`, and `OpacityEffect`.
- ⏳ **Windows/CI-deferred:** live render + GPU 60fps @ ARM64 measurement; the Swift
  `obb_swarm_vend_frame` emitter; the remaining families (Flow / Aurora / Volumetric —
  12 bespoke) fan out on this same pattern.
