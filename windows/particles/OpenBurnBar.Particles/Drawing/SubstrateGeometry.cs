using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Drawing;

/// <summary>
/// A canvas-space point — the C# analog of SwiftUI <c>CGPoint</c> / Win2D
/// <c>System.Numerics.Vector2</c>. Used by the polygon / polyline geometry
/// primitives so a bespoke painter can hand the seam a filled facet or a stroked
/// crystal edge without allocating (the small fixed-size vertex spans are
/// <c>stackalloc</c>'d by the caller).
/// </summary>
public readonly struct Vec2
{
    public readonly double X;
    public readonly double Y;

    public Vec2(double x, double y)
    {
        X = x;
        Y = y;
    }
}

/// <summary>
/// One stop of a linear-gradient fill — the C# analog of SwiftUI
/// <c>Gradient.Stop</c> / Win2D <c>CanvasGradientStop</c>. <see cref="Location"/> is
/// the 0…1 position along the gradient axis; <see cref="Color"/> is the resolved
/// channel value (opacity folded in).
/// </summary>
public readonly struct GradientStop
{
    public readonly double Location;
    public readonly Rgba Color;

    public GradientStop(double location, in Rgba color)
    {
        Location = location;
        Color = color;
    }
}
