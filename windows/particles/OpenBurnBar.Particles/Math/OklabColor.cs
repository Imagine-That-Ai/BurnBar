using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Math;

/// <summary>
/// Perceptual OKLab straight-line color mix — C# port of the identical bake-time
/// helper the Swift volumetric substrates share (Sunshaft / Silk Filament
/// altitude ramps). Used ONLY at ramp-bake time (never per dot per frame), so the
/// cube-roots are cheap, and the cool→warm altitude gradient reads perceptually
/// even (a straight sRGB lerp would muddy the mid-tones). The matrices are the
/// canonical Björn Ottosson OKLab constants — byte-for-byte with the Swift port so
/// a baked ramp step resolves to the same color on macOS and Windows.
/// </summary>
public static class OklabColor
{
    private static double SrgbToLin(double c) =>
        c <= 0.04045 ? c / 12.92 : System.Math.Pow((c + 0.055) / 1.055, 2.4);

    private static double LinToSrgb(double x)
    {
        double v = x <= 0.0031308 ? x * 12.92 : 1.055 * System.Math.Pow(x, 1.0 / 2.4) - 0.055;
        return v < 0 ? 0 : (v > 1 ? 1 : v);
    }

    private static (double L, double A, double B) RgbToOklab(in Rgba c)
    {
        double r = SrgbToLin(c.R), g = SrgbToLin(c.G), b = SrgbToLin(c.B);
        double l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
        double m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
        double s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
        double l_ = System.Math.Cbrt(l), m_ = System.Math.Cbrt(m), s_ = System.Math.Cbrt(s);
        return (
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_);
    }

    private static Rgba OklabToRgb(double L, double A, double B)
    {
        double l_ = L + 0.3963377774 * A + 0.2158037573 * B;
        double m_ = L - 0.1055613458 * A - 0.0638541728 * B;
        double s_ = L - 0.0894841775 * A - 1.2914855480 * B;
        double l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
        return new Rgba(
            LinToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            LinToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            LinToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            1.0);
    }

    /// <summary>Perceptual OKLab straight-line mix of two sRGB colors at 0…1 (alpha forced to 1; ramps fold opacity at draw).</summary>
    public static Rgba Mix(in Rgba a, in Rgba b, double t)
    {
        (double la, double aa, double ba) = RgbToOklab(a);
        (double lb, double ab, double bb) = RgbToOklab(b);
        return OklabToRgb(la + (lb - la) * t, aa + (ab - aa) * t, ba + (bb - ba) * t);
    }
}
