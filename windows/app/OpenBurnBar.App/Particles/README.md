# Particles — Win2D renderer host (Windows-only, CI-deferred)

The GPU binding for the particle-engine substrate layer (Phase 3 · W6-DS-SWARM).
This is the **only Windows-gated** piece of the renderer; the parity-critical
renderer logic (model + painters + drawing seam + FFI decode) lives in the
platform-agnostic `windows/particles/OpenBurnBar.Particles` lib, which builds and
is perf-measured on macOS. See `windows/particles/README.md` for the full
architecture, the FFI vend contract, and the measured perf numbers.

## Files

- `Win2DSubstrateDrawingSession.cs` — implements
  `OpenBurnBar.Particles.Drawing.ISubstrateDrawingSession` against a Win2D
  `CanvasDrawingSession`: `CanvasBlend.Add` additive bloom, cached radial-gradient
  glow sprites (`DrawImage`), batched `CanvasGeometry` strokes, and
  `GaussianBlurEffect` blur layers (via `CanvasCommandList`).
- `GlowSpriteCache.cs` — Win2D analog of the Swift `SpriteCache`; bakes the 64px
  radial glow once per tint into a `CanvasRenderTarget`.
- `SwarmCanvasHost.cs` — owns a `CanvasAnimatedControl` (vsync-driven, retained,
  hardware-accelerated — the WinUI 3 analog of the SwiftUI `TimelineView`+`Canvas`
  loop in macOS `SwarmCanvasView`). Each frame it pulls the decoded
  `SwarmSubstrateFrame` from `FrameProvider` (the FFI vend), wraps the drawing
  session, and calls the active `ISwarmSubstrate`.

## Why it does not build on macOS

`Microsoft.Graphics.Win2D` + the WinUI 3 XAML/`CanvasAnimatedControl` types are
Windows-only; the whole `OpenBurnBar.App` project is already
`net8.0-windows10.0.19041.0` and cannot compile to completion on macOS (per its
csproj header: "authored; build unproven until WINUI-017"). These files inherit
that posture. The live-render check — the actual ARM64 @60fps GPU pass — runs on
the dev host / Windows CI per `windows/app/DEV_HOST_RUNBOOK.md`.

## Wiring into a view (Windows)

```csharp
var host = new SwarmCanvasHost { Substrate = new StarfireSubstrate() };
host.FrameProvider = (size, elapsed) =>
{
    // Production: obb_swarm_vend_frame(...) → SwarmSubstrateFrameFfi.Decode(...)
    // Returns the immutable per-frame snapshot from Swift Core SwarmSimulation.
    return VendCurrentFrame(size, elapsed);
};
someGrid.Children.Add(host.Control);
```
