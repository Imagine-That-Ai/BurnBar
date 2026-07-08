namespace OpenBurnBar.Particles.Model;

/// <summary>
/// Straight C# port of the Swift Core <c>RGBA</c> primitive
/// (<c>OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/RGBA.swift</c>).
/// Components are in <c>[0, 1]</c>. A value type (readonly struct) so per-frame
/// color math never allocates.
/// </summary>
/// <remarks>
/// This is the numeric color channel the substrate painters read directly — no
/// string parsing, exactly like the Swift <c>SwarmSubstrateDot.rgba</c>. The
/// engine (Swift Core) resolves driver / palette / scheme + opacity into these
/// four channels before vending the frame over FFI, so the C# renderer never
/// re-derives brand color.
/// </remarks>
public readonly struct Rgba
{
    public readonly double R;
    public readonly double G;
    public readonly double B;
    public readonly double A;

    public Rgba(double r, double g, double b, double a = 1.0)
    {
        R = r;
        G = g;
        B = b;
        A = a;
    }

    public static Rgba White { get; } = new(1, 1, 1, 1);

    private static double Clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

    /// <summary>Linear channel-wise interpolation (mirrors <c>RGBA.mix(with:amount:)</c>).</summary>
    public Rgba Mix(in Rgba other, double amount)
    {
        double t = Clamp01(amount);
        return new Rgba(
            Clamp01(R * (1 - t) + other.R * t),
            Clamp01(G * (1 - t) + other.G * t),
            Clamp01(B * (1 - t) + other.B * t),
            Clamp01(A * (1 - t) + other.A * t));
    }

    /// <summary>Replace alpha, keep RGB (mirrors <c>RGBA.withOpacity</c>).</summary>
    public Rgba WithOpacity(double o) => new(R, G, B, Clamp01(o));

    /// <summary>Push toward white by <paramref name="amount"/>, keep alpha (the "hot core" move, mirrors <c>RGBA.toWhite</c>).</summary>
    public Rgba ToWhite(double amount) => Mix(new Rgba(1, 1, 1, A), amount);

    /// <summary>Push toward black by <paramref name="amount"/>, keep alpha (mirrors <c>RGBA.darkened(by:)</c>).</summary>
    public Rgba Darkened(double amount) => Mix(new Rgba(0, 0, 0, A), amount);

    /// <summary>
    /// Quantized 8-bit-per-channel bucket key — byte-identical to Swift
    /// <c>RGBA.bucketKey</c>. Used to batch fills by color so draw counts stay
    /// bounded even when the color driver wiggles intensities continuously.
    /// </summary>
    public uint BucketKey
    {
        get
        {
            uint r8 = (uint)System.Math.Round(Clamp01(R) * 255.0) & 0xFF;
            uint g8 = (uint)System.Math.Round(Clamp01(G) * 255.0) & 0xFF;
            uint b8 = (uint)System.Math.Round(Clamp01(B) * 255.0) & 0xFF;
            uint a8 = (uint)System.Math.Round(Clamp01(A) * 255.0) & 0xFF;
            return (r8 << 24) | (g8 << 16) | (b8 << 8) | a8;
        }
    }
}
