using OpenBurnBar.Particles.Math;

namespace OpenBurnBar.Particles.Model;

/// <summary>App-wide visual persona — port of Swift Core <c>UIMode</c>.</summary>
public enum UIMode
{
    Standard,
    Cooking,
}

/// <summary>
/// One non-glyph particle handed to a substrate painter — C# port of Swift
/// <c>SwarmSubstrateDot</c> (<c>Views/Substrate/SwarmSubstrate.swift</c>). Its
/// color is already resolved by the engine through
/// <c>SwarmSimulation.resolvedRGBA(for:at:…)</c>, so painters read numeric
/// channels off <see cref="Rgba"/> with zero string parsing.
/// </summary>
/// <remarks>
/// Field order + semantics are the FFI contract (see
/// <c>Ffi/SwarmSubstrateFrameFfi.cs</c>). A struct so the per-frame dot array is
/// one contiguous block that marshals 1:1 from the Swift snapshot.
/// </remarks>
public readonly struct SwarmSubstrateDot
{
    /// <summary>Canvas-space position X.</summary>
    public readonly double X;

    /// <summary>Canvas-space position Y.</summary>
    public readonly double Y;

    /// <summary>Velocity X (sim space) — useful for flow-direction idioms.</summary>
    public readonly double Vx;

    /// <summary>Velocity Y (sim space).</summary>
    public readonly double Vy;

    /// <summary>Draw radius the plain DOTS path would use: <c>max(0.4, size*(inShape ?1.2:0.85))</c>.</summary>
    public readonly double Radius;

    /// <summary>Base unscaled size seed (<c>0.8…2.3</c>).</summary>
    public readonly double BaseSize;

    /// <summary>Engine-resolved color (driver / palette / scheme + opacity in <see cref="Rgba.A"/>).</summary>
    public readonly Rgba Rgba;

    /// <summary>Live particle opacity (<c>p.opacity</c>), separate from <see cref="Rgba.A"/>.</summary>
    public readonly double Opacity;

    /// <summary>True when the field is forming a shape and this dot has a target.</summary>
    public readonly bool InShape;

    /// <summary>Stable 0…1 per-particle seed (palette position) — good for per-point phase.</summary>
    public readonly double ColorIndex;

    /// <summary>0…1 bezier travel parameter (router-flow); 0 for most modes.</summary>
    public readonly double FlowProgress;

    public SwarmSubstrateDot(double x, double y, double vx, double vy, double radius,
        double baseSize, in Rgba rgba, double opacity, bool inShape,
        double colorIndex, double flowProgress)
    {
        X = x;
        Y = y;
        Vx = vx;
        Vy = vy;
        Radius = radius;
        BaseSize = baseSize;
        Rgba = rgba;
        Opacity = opacity;
        InShape = inShape;
        ColorIndex = colorIndex;
        FlowProgress = flowProgress;
    }
}

/// <summary>
/// Theme palette + polarity — port of Swift <c>SubstrateStage</c> (the native
/// analog of the source <c>StageColors</c>). <c>Accent2</c>/<c>Ink</c> are derived
/// from <c>Accent</c> + scheme on the Swift side and vended as resolved channels.
/// </summary>
public readonly struct SubstrateStage
{
    public readonly Rgba Accent;
    public readonly Rgba Accent2;
    public readonly Rgba Ink;

    /// <summary>True when the canvas behind is dark (additive bloom reads with <c>Add</c> blend).</summary>
    public readonly bool Dark;

    public SubstrateStage(in Rgba accent, in Rgba accent2, in Rgba ink, bool dark)
    {
        Accent = accent;
        Accent2 = accent2;
        Ink = ink;
        Dark = dark;
    }
}

/// <summary>
/// The per-frame draw context handed to a substrate painter — C# port of Swift
/// <c>SwarmSubstrateFrame</c>. Host-transformed dot positions live in
/// <see cref="Dots"/>; <see cref="Cx"/>/<see cref="Cy"/>/<see cref="CloudRadius"/>/
/// <see cref="SizePx"/> are computed once by the engine; <see cref="T"/>/
/// <see cref="Dt"/> drive animation; <see cref="Formed"/>/<see cref="SettleProgress"/>
/// gate assembly.
/// </summary>
/// <remarks>
/// The parity-critical simulation math (murmuration, shape/glyph sampling, color
/// resolve) stays in Swift Core; this frame is the immutable snapshot vended over
/// FFI once per frame. The C# renderer is a pure consumer — it never mutates or
/// re-derives simulation state. See <c>Ffi/SwarmSubstrateFrameFfi.cs</c> for the
/// exact marshalled layout.
/// </remarks>
public sealed class SwarmSubstrateFrame
{
    public double Width { get; }
    public double Height { get; }

    /// <summary><c>renderScheme == .dark</c>.</summary>
    public bool Dark { get; }

    /// <summary><c>accessibilityReduceMotion</c> (threaded in) — freezes twinkle to a poised still.</summary>
    public bool Reduced { get; }

    /// <summary>Drops the heavy bloom + cross passes when the device is on battery-saver.</summary>
    public bool BatteryThrottled { get; }

    public UIMode UiMode { get; }

    /// <summary>True whenever the field is forming a glyph/shape (mode != swarm).</summary>
    public bool IsShapeMode { get; }

    /// <summary>True once the active shape has settled.</summary>
    public bool Formed { get; }

    /// <summary>Continuous 0…1 "how formed" — the close-fraction of targeted particles.</summary>
    public double SettleProgress { get; }

    /// <summary><c>flowTime</c> — the always-advancing clock (seconds).</summary>
    public double T { get; }

    /// <summary>Normalized so <c>1 ≈ 60fps</c>.</summary>
    public double Dt { get; }

    public SubstrateStage Stage { get; }

    /// <summary>Backdrop plate for blend choices; null when none.</summary>
    public Rgba? Backdrop { get; }

    /// <summary>Non-glyph particles, color-resolved. One contiguous frame snapshot.</summary>
    public SwarmSubstrateDot[] Dots { get; }

    /// <summary>Cloud centroid X (computed once per frame from <see cref="Dots"/>).</summary>
    public double Cx { get; }

    /// <summary>Cloud centroid Y.</summary>
    public double Cy { get; }

    /// <summary>Representative cloud radius (mean distance from centroid).</summary>
    public double CloudRadius { get; }

    /// <summary>Suggested base point px (median dot radius).</summary>
    public double SizePx { get; }

    /// <summary>
    /// Lazily-built, cached NN order + k-NN neighbor lists for the Mesh
    /// connected-node lattice idioms (the "Caustic Pool" refracted filament net).
    /// Owned per-frame; the simulation may inject a persistent one so the topology
    /// cache survives across frames (mirrors the Swift <c>frame.structure</c>).
    /// Styles that ignore it pay nothing.
    /// </summary>
    public SubstrateStructure Structure { get; }

    public SwarmSubstrateFrame(
        double width, double height, bool dark, bool reduced, bool batteryThrottled,
        UIMode uiMode, bool isShapeMode, bool formed, double settleProgress,
        double t, double dt, in SubstrateStage stage, Rgba? backdrop,
        SwarmSubstrateDot[] dots, double cx, double cy, double cloudRadius, double sizePx,
        SubstrateStructure? structure = null)
    {
        Width = width;
        Height = height;
        Dark = dark;
        Reduced = reduced;
        BatteryThrottled = batteryThrottled;
        UiMode = uiMode;
        IsShapeMode = isShapeMode;
        Formed = formed;
        SettleProgress = settleProgress;
        T = t;
        Dt = dt;
        Stage = stage;
        Backdrop = backdrop;
        Dots = dots;
        Cx = cx;
        Cy = cy;
        CloudRadius = cloudRadius;
        SizePx = sizePx;
        Structure = structure ?? new SubstrateStructure();
    }
}
