using System;
using System.Runtime.InteropServices;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Ffi;

// =============================================================================
//  FFI VEND CONTRACT — Swift Core → C# Win2D renderer (per-frame snapshot)
// =============================================================================
//
//  ARCHITECTURE (per docs/windows-port/PHASE3_UI_PARITY_PLAN.md, W6-DS-SWARM):
//
//    The parity-critical SIMULATION math — murmuration (Reynolds/curl-noise),
//    shape/glyph target sampling, and per-particle color resolution
//    (driver / palette / scheme) — stays in Swift Core `SwarmSimulation`, which
//    already compiles on Windows (Phase 1). On each display tick the Swift side
//    resolves the field to an IMMUTABLE snapshot and vends it over a flat C ABI;
//    the C#/Win2D renderer is a pure consumer that only decides how the resolved
//    dots are painted. NOTHING re-derives simulation state on the C# side.
//
//    This mirrors, byte-for-byte, the Swift `SwarmSimulation.makeSubstrateFrame`
//    (OpenBurnBarCore/.../Views/SwarmCanvasView+Substrate.swift), which builds a
//    `SwarmSubstrateFrame` from the live particle field once per frame. The FFI
//    is that same struct, flattened for marshalling.
//
//  WIRE FORMAT (little-endian; the only two supported arches are win-x64 and
//  win-arm64, both LE, so no byte-swap is needed):
//
//    struct FrameHeader {          // 1 fixed-size blittable header, see below
//        …scalars… ; uint32 dotCount ;
//    }
//    FrameDot dots[dotCount];      // one contiguous array immediately following
//
//    The Swift side hands back TWO pointers (header, dots) + dotCount, or one
//    pointer to a combined buffer. Channels are float32 on the wire (bandwidth:
//    ~40 bytes/dot × 1080 dots × 60 fps ≈ 2.6 MB/s — trivial; float32 keeps
//    sub-pixel canvas precision to ~7 significant digits) and widen to double in
//    the managed model, which is what the painters compute in.
//
//  SWIFT-SIDE API TO ADD (Phase-3 W6-DS-SWARM, not yet written — this file is the
//  contract the Swift emitter must satisfy):
//
//    // In OpenBurnBarCore, gated to Windows, alongside makeSubstrateFrame:
//    @_cdecl("obb_swarm_frame_header_size")
//    public func obb_swarm_frame_header_size() -> Int32   // == Marshal.SizeOf<FrameHeader>
//
//    @_cdecl("obb_swarm_frame_dot_size")
//    public func obb_swarm_frame_dot_size() -> Int32       // == Marshal.SizeOf<FrameDot>
//
//    // Fills caller-owned buffers from the live simulation for one frame.
//    // Returns the dot count actually written (<= dotCapacity), or -1 on error.
//    @_cdecl("obb_swarm_vend_frame")
//    public func obb_swarm_vend_frame(
//        _ sim: UnsafeMutableRawPointer,        // opaque SwarmSimulation handle
//        _ width: Double, _ height: Double,
//        _ batteryThrottled: Bool, _ uiMode: Int32,
//        _ headerOut: UnsafeMutableRawPointer,  // >= header_size bytes
//        _ dotsOut: UnsafeMutableRawPointer,    // >= dot_size * dotCapacity bytes
//        _ dotCapacity: Int32) -> Int32
//
//    The Swift body is a thin re-pack of the EXISTING makeSubstrateFrame loop:
//    same dot filter (`!p.isGlyph`), same radius `max(0.4, size*(inShape?1.2:0.85))`,
//    same `resolvedRGBA`, same centroid/cloudRadius/sizePx, same stage derivation.
//    The C# `Decode` below is the exact inverse.
//
//  PARITY: RecordingDrawingSession.Checksum lets a Mac render and a Windows render
//  of the SAME decoded frame be compared command-for-command (W11 layout-parity
//  test), so this seam is golden-testable end to end without pixels.
// =============================================================================

/// <summary>
/// Blittable wire layout of one vended dot. Field order and meaning match Swift
/// <c>SwarmSubstrateDot</c> exactly; channels are float32 on the wire.
/// <c>InShape</c> is a byte (0/1) with 3 pad bytes so the struct stays naturally
/// aligned and blittable on both x64 and ARM64.
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct SwarmSubstrateDotFfi
{
    public float X;
    public float Y;
    public float Vx;
    public float Vy;
    public float Radius;
    public float BaseSize;
    public float R;
    public float G;
    public float B;
    public float A;
    public float Opacity;
    public float ColorIndex;
    public float FlowProgress;
    public byte InShape;
    public byte Pad0;
    public byte Pad1;
    public byte Pad2;

    public readonly SwarmSubstrateDot ToModel() => new(
        X, Y, Vx, Vy, Radius, BaseSize,
        new Rgba(R, G, B, A), Opacity, InShape != 0, ColorIndex, FlowProgress);
}

/// <summary>
/// Bit flags packed into the header <c>Flags</c> field (matches the Swift scalar
/// booleans on <c>SwarmSubstrateFrame</c>).
/// </summary>
[Flags]
public enum SwarmFrameFlags : uint
{
    None = 0,
    Dark = 1 << 0,
    Reduced = 1 << 1,
    BatteryThrottled = 1 << 2,
    IsShapeMode = 1 << 3,
    Formed = 1 << 4,
    HasBackdrop = 1 << 5,
}

/// <summary>
/// Blittable wire layout of the per-frame scalar header. Immediately followed on
/// the wire by <c>SwarmSubstrateDotFfi[DotCount]</c>.
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct SwarmSubstrateFrameHeaderFfi
{
    public float Width;
    public float Height;
    public float SettleProgress;
    public float T;
    public float Dt;

    // Stage: accent, accent2, ink (RGBA each).
    public float AccentR, AccentG, AccentB, AccentA;
    public float Accent2R, Accent2G, Accent2B, Accent2A;
    public float InkR, InkG, InkB, InkA;

    // Backdrop (valid only when Flags has HasBackdrop).
    public float BackdropR, BackdropG, BackdropB, BackdropA;

    // Derived cloud anchors.
    public float Cx, Cy, CloudRadius, SizePx;

    public uint Flags;    // SwarmFrameFlags
    public int UiMode;    // 0 == Standard, 1 == Cooking
    public uint DotCount;
}

/// <summary>
/// Decodes a vended header + dot buffer into the managed
/// <see cref="SwarmSubstrateFrame"/> the painters consume. The exact inverse of
/// the Swift <c>obb_swarm_vend_frame</c> emitter described at the top of this file.
/// </summary>
public static class SwarmSubstrateFrameFfi
{
    /// <summary>
    /// Decode from a header value + a span of blittable dots (already copied out of
    /// native memory, or a <c>Span&lt;T&gt;</c> over the pinned native buffer).
    /// </summary>
    public static SwarmSubstrateFrame Decode(in SwarmSubstrateFrameHeaderFfi header, ReadOnlySpan<SwarmSubstrateDotFfi> dots)
    {
        var flags = (SwarmFrameFlags)header.Flags;
        var modelDots = new SwarmSubstrateDot[dots.Length];
        for (int i = 0; i < dots.Length; i++) modelDots[i] = dots[i].ToModel();

        var stage = new SubstrateStage(
            new Rgba(header.AccentR, header.AccentG, header.AccentB, header.AccentA),
            new Rgba(header.Accent2R, header.Accent2G, header.Accent2B, header.Accent2A),
            new Rgba(header.InkR, header.InkG, header.InkB, header.InkA),
            flags.HasFlag(SwarmFrameFlags.Dark));

        Rgba? backdrop = flags.HasFlag(SwarmFrameFlags.HasBackdrop)
            ? new Rgba(header.BackdropR, header.BackdropG, header.BackdropB, header.BackdropA)
            : null;

        return new SwarmSubstrateFrame(
            header.Width, header.Height,
            flags.HasFlag(SwarmFrameFlags.Dark),
            flags.HasFlag(SwarmFrameFlags.Reduced),
            flags.HasFlag(SwarmFrameFlags.BatteryThrottled),
            header.UiMode == 1 ? UIMode.Cooking : UIMode.Standard,
            flags.HasFlag(SwarmFrameFlags.IsShapeMode),
            flags.HasFlag(SwarmFrameFlags.Formed),
            header.SettleProgress,
            header.T, header.Dt, stage, backdrop, modelDots,
            header.Cx, header.Cy, header.CloudRadius, header.SizePx);
    }

    /// <summary>
    /// Decode straight from raw native pointers (the shape <c>obb_swarm_vend_frame</c>
    /// hands back). Copies out of native memory into a managed frame.
    /// </summary>
    public static unsafe SwarmSubstrateFrame Decode(SwarmSubstrateFrameHeaderFfi* header, SwarmSubstrateDotFfi* dots)
    {
        int n = (int)header->DotCount;
        var span = new ReadOnlySpan<SwarmSubstrateDotFfi>(dots, n);
        return Decode(in *header, span);
    }

    /// <summary>
    /// REFERENCE ENCODER — the exact inverse of <see cref="Decode(in SwarmSubstrateFrameHeaderFfi, ReadOnlySpan{SwarmSubstrateDotFfi})"/>,
    /// and the canonical byte-layout spec the Swift <c>obb_swarm_vend_frame</c>
    /// emitter must reproduce. Not used in production (Swift Core is the real
    /// producer); it exists so the FFI round-trip is unit-testable on either
    /// platform and so the Swift author has an executable reference.
    /// </summary>
    public static (SwarmSubstrateFrameHeaderFfi Header, SwarmSubstrateDotFfi[] Dots) Encode(SwarmSubstrateFrame frame)
    {
        SwarmFrameFlags flags = SwarmFrameFlags.None;
        if (frame.Dark) flags |= SwarmFrameFlags.Dark;
        if (frame.Reduced) flags |= SwarmFrameFlags.Reduced;
        if (frame.BatteryThrottled) flags |= SwarmFrameFlags.BatteryThrottled;
        if (frame.IsShapeMode) flags |= SwarmFrameFlags.IsShapeMode;
        if (frame.Formed) flags |= SwarmFrameFlags.Formed;
        if (frame.Backdrop.HasValue) flags |= SwarmFrameFlags.HasBackdrop;

        Rgba bd = frame.Backdrop ?? default;
        var header = new SwarmSubstrateFrameHeaderFfi
        {
            Width = (float)frame.Width,
            Height = (float)frame.Height,
            SettleProgress = (float)frame.SettleProgress,
            T = (float)frame.T,
            Dt = (float)frame.Dt,
            AccentR = (float)frame.Stage.Accent.R,
            AccentG = (float)frame.Stage.Accent.G,
            AccentB = (float)frame.Stage.Accent.B,
            AccentA = (float)frame.Stage.Accent.A,
            Accent2R = (float)frame.Stage.Accent2.R,
            Accent2G = (float)frame.Stage.Accent2.G,
            Accent2B = (float)frame.Stage.Accent2.B,
            Accent2A = (float)frame.Stage.Accent2.A,
            InkR = (float)frame.Stage.Ink.R,
            InkG = (float)frame.Stage.Ink.G,
            InkB = (float)frame.Stage.Ink.B,
            InkA = (float)frame.Stage.Ink.A,
            BackdropR = (float)bd.R,
            BackdropG = (float)bd.G,
            BackdropB = (float)bd.B,
            BackdropA = (float)bd.A,
            Cx = (float)frame.Cx,
            Cy = (float)frame.Cy,
            CloudRadius = (float)frame.CloudRadius,
            SizePx = (float)frame.SizePx,
            Flags = (uint)flags,
            UiMode = frame.UiMode == UIMode.Cooking ? 1 : 0,
            DotCount = (uint)frame.Dots.Length,
        };

        var dots = new SwarmSubstrateDotFfi[frame.Dots.Length];
        for (int i = 0; i < dots.Length; i++)
        {
            SwarmSubstrateDot d = frame.Dots[i];
            dots[i] = new SwarmSubstrateDotFfi
            {
                X = (float)d.X,
                Y = (float)d.Y,
                Vx = (float)d.Vx,
                Vy = (float)d.Vy,
                Radius = (float)d.Radius,
                BaseSize = (float)d.BaseSize,
                R = (float)d.Rgba.R,
                G = (float)d.Rgba.G,
                B = (float)d.Rgba.B,
                A = (float)d.Rgba.A,
                Opacity = (float)d.Opacity,
                ColorIndex = (float)d.ColorIndex,
                FlowProgress = (float)d.FlowProgress,
                InShape = (byte)(d.InShape ? 1 : 0),
            };
        }

        return (header, dots);
    }
}
