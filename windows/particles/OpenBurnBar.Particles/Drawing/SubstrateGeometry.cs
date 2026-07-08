namespace OpenBurnBar.Particles.Drawing;

/// <summary>
/// A canvas-space point (doubles). The tiny value type the polygon / gradient-quad
/// primitives pass so the Mesh (Delaunay-ish facet lattices) and Moiré
/// (interference line fields) painters can hand vertex geometry across the
/// <see cref="ISubstrateDrawingSession"/> seam without allocating. On Win2D each
/// becomes a <c>System.Numerics.Vector2</c> fed to a <c>CanvasPathBuilder</c>.
/// </summary>
public readonly struct PointD
{
    public readonly double X;
    public readonly double Y;

    public PointD(double x, double y)
    {
        X = x;
        Y = y;
    }
}

/// <summary>
/// Which baked radial-sprite profile <see cref="ISubstrateDrawingSession.DrawGlowSprite"/>
/// draws — the C# analog of picking a Swift <c>SpriteCache.radial(stops:)</c> ramp.
/// The Win2D <c>GlowSpriteCache</c> bakes one <c>CanvasRenderTarget</c> per
/// (profile, tint) bucket; headless it only folds into the checksum.
/// </summary>
public enum GlowProfile
{
    /// <summary>Soft additive glow: opaque core → clear rim (Swift <c>whiteGlow</c>). The default.</summary>
    Glow,

    /// <summary>Hollow glass sphere: near-clear core → bright ring at ~0.92 → clear (Film Bubble sphere).</summary>
    Sphere,

    /// <summary>Hot specular spark: hot opaque center falling fast to clear (catchlights / caustic sparks).</summary>
    Spark,
}
