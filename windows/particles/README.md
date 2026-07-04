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
                   SubstrateStructure  ── NN-walk + kNN provider (grid, O(n)); cached by topology
  Drawing/         ISubstrateDrawingSession  ── the seam (circles, glow sprites, blur layers,
                                                 + polygons, gradient polygons, polylines)
                   RecordingDrawingSession   ── headless: counts commands + FNV geometry checksum
  Substrates/      PlainDots + Constellation/Starfire
                   Flow/    PlanktonWake · GlassRibbon · SilkStreamline · PetalDrift
                   Aurora/  Wisp · IcePrism · AuroraFilament · DriftMotes
                   Families/ + SubstrateCatalog  ── the registry (mirrors SubstrateCatalog.swift)
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

### Flow + Aurora families — measured on this box (Apple M-series, arm64, .NET 10)

All 9 bespoke painters (Constellation·Starfire + the full Flow + Aurora families),
dark canvas, full path, formed hold, 400 timed frames. Every scenario clears the
60fps **and** 120fps CPU budget with large headroom; worst cases below.

| substrate | family | worst median ms (@2000) | 60fps CPU | draw cmds |
|---|---|---:|:--:|---:|
| Plankton Wake | Flow | 0.232 | PASS (72x) | 14,217 (glow+blur) |
| Glass Ribbon | Flow | 0.560 | PASS (30x) | 10,840 (gradient quads + rail strokes) |
| Silk Streamline | Flow | 0.075 | PASS (223x) | 970 (a handful of fat ribbons) |
| Petal Drift | Flow | 0.612 | PASS (27x) | 6,001 (tessellated teardrops) |
| Wisp Plasma | Aurora | 0.243 | PASS (69x) | 8,204 (glow+blur) |
| Polar Ice Prism | Aurora | 0.170 | PASS (98x) | 11,504 (facet polys + wedges) |
| Aurora Filament | Aurora | 0.095 | PASS (176x) | 7 (one broken wire, stacked strokes) |
| Drift Motes | Aurora | 0.055 | PASS (301x) | 3,602 (motes capped at 900) |

The three streamline substrates (Glass Ribbon / Silk Streamline / Aurora Filament)
consume the cached NN-walk/kNN `SubstrateStructure`; its one-time cold build —
paid on a **reform**, not per frame — is 0.27 ms @520, 0.58 ms @1080, 1.00 ms
@2000 dots, so even a fresh topology stays comfortably within a single frame.

`--verify` proves, for every painter, deterministic checksums + FFI-transparent
command shape across both canvas polarities and the throttled path, plus catalog
integrity (6 plain + 9 bespoke = 15 registered).

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
**Wave-4 integration (`windows/integration-w4`)** consolidates the three parallel
substrate-family lanes into one catalog + one drawing seam + one headless harness:

- ✅ PlainDots + Starfire (Constellation) painters — faithful line-for-line ports (#1202).
- ✅ **Flow family (4)** — Plankton Wake · Glass Ribbon · Silk Streamline · Petal Drift (#1212).
- ✅ **Aurora family (4)** — Wisp · Ice Prism · Aurora Filament · Drift Motes (#1212).
- ✅ **Mesh family (4)** — Caustic Pool · Gradient Patch · Iso Contour · Living Grain (#1214).
- ✅ **Moiré family (4)** — Fringe Bloom · Lattice Facet · Ruling Grating · Film Bubble (#1214).
- ✅ **Volumetric family + remaining Constellation** — Sunshaft · Smoked Glass · Dust Motes
  · Silk Filament · Star Sapphire · Stellarium · Rimefrost (#1213).
- ✅ Every family's bespoke painters live under `Substrates/<Family>/`, and each family's
  registry (`Substrates/Families/<Family>Family.cs`) is aggregated by the single
  `SubstrateCatalog` (mirrors Swift `SubstrateCatalog.swift`). Each family adds only its own
  registry array; the catalog file is the one documented merge point.
- ✅ `SubstrateStructure` (grid-based NN-walk + k-NN neighbor graph) ported once, shared by
  the streamline substrates (Glass Ribbon, Silk Streamline, Aurora Filament) and the Mesh
  "Caustic Pool" refracted filament net (connected-node lattice). `SwarmSubstrateFrame`
  carries a lazily-built, injectable `Structure` so the sim can reuse the topology cache.
- ✅ **Drawing seam** — the union of every family's `CanvasDrawingSession` subset:
  circles, glow sprites (with a `GlowProfile`: glow / glass-sphere / spark), stroked
  circles (Film-Bubble rims), filled/gradient/rotated-rounded-rect polygons + polylines
  (facet lattices, stained-glass panes, silk ribbons, aurora filaments), batched line
  strokes, blur layers (with a `layerOpacity` haze multiply) and a radial alpha-mask layer
  (Ruling-Grating full-field feather). Implemented in all three sinks: the interface,
  `RecordingDrawingSession` (command tallies + order-sensitive FNV checksum), and the
  Windows `Win2DSubstrateDrawingSession` / sprite caches.
- ✅ Headless perf harness is **catalog-driven** — it benchmarks every registered bespoke
  painter and `--verify` proves each renders **deterministically** (stable checksum +
  command counts on a repeat render) and is **FFI-transparent** (the decoded frame yields
  the same command shape), plus a derived catalog-integrity invariant. Real numbers above.
- ✅ Win2D host + adapter authored (CanvasAnimatedControl, CanvasBlend.Add,
  GaussianBlurEffect, CanvasRadialGradientBrush, CanvasGeometry polygons +
  CanvasLinearGradientBrush + CustomDashStyle, AlphaMaskEffect, OpacityEffect).
- ⏳ **Windows/CI-deferred:** live GPU render + 60fps @ ARM64 measurement on a real device
  (the `CanvasAnimatedControl` host is Windows-gated, not compiled/rendered on macOS CI);
  the Swift `obb_swarm_vend_frame` emitter.
