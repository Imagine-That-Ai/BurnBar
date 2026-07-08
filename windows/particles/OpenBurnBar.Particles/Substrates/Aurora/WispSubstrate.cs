using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Aurora;

/// <summary>
/// Wisp Plasma — C# port of Swift <c>Views/Substrate/Aurora/WispSubstrate.swift</c>
/// (itself a port of imaginethat <c>aurora/wisp.ts</c>). Every silhouette point is a
/// soft will-o-the-wisp orb — an outer aurora bloom + a colored mid halo wrapped
/// around a near-white hot core. The dense lattice of pin-sharp cores holds the mark
/// pixel-locked while only the halos drift on a slow 2-octave flow field.
/// </summary>
/// <remarks>
/// A screen-centred bloom vignette (dark only, additive, drawn first), a true
/// Gaussian plasma bed, three stacked layers per orb (white bloom sprite, colored
/// halo, whitened core), candle-flicker on core size/brightness, and a travelling
/// "gust" crest swept L→R. <c>reduced</c> → a poised still lantern field;
/// <c>batteryThrottled</c> drops the vignette, plasma bed, outer bloom, and gust
/// (an accent-tinted glow stands in per orb).
/// </remarks>
public sealed class WispSubstrate : ISwarmSubstrate
{
    private static double Flow(double x, double y, double t)
    {
        double a = System.Math.Sin(x * 0.013 + t * 0.9) + System.Math.Cos(y * 0.017 - t * 0.6);
        double b = System.Math.Sin((x + y) * 0.021 - t * 0.5) * 0.5;
        return a + b;
    }

    private static (double bx, double by, double k) Orb(
        SwarmSubstrateDot[] dots, int i, bool reduced, double amp, double t, double f)
    {
        double hx = dots[i].X, hy = dots[i].Y;
        double seed = Shash(i * 1.37 + 0.5);
        double bx = hx, by = hy;
        if (!reduced)
        {
            double fv = Flow(hx, hy, t);
            bx = hx + System.Math.Sin(fv + seed * Tau) * amp;
            by = hy + System.Math.Cos(fv * 0.7 + seed * 4.3) * amp * 0.45;
        }
        double flick = reduced
            ? 0.5 + 0.5 * System.Math.Sin(seed * 19)
            : System.Math.Sin(t * 1.7 + seed * Tau) * 0.5 + 0.5;
        double k = 0.85 + 0.15 * (flick * 2 - 1);
        if (!reduced)
        {
            double s = System.Math.Sin(t * (0.8 + seed) + seed * 11.0);
            if (s > 0.95) k += (s - 0.95) / 0.05 * 0.55;
        }
        return (bx, by, ClampD(k, 0.45, 1.7) * f);
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return false;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        double sizePx = System.Math.Max(0.8, frame.SizePx);
        double t = frame.T;

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.45 + 0.55;
        double amp = reduced ? 0.0 : ClampD(frame.CloudRadius * 0.018, 1.4, 4.2);

        Rgba accentMix = frame.Stage.Accent.Mix(frame.Stage.Accent2, 0.5);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        if (dark)
        {
            // global bloom vignette — a screen-centred fake of camera glow.
            if (!throttled)
            {
                double breath = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * 0.55);
                double vigR = System.Math.Max(frame.Width, frame.Height) * 0.5;
                session.DrawGlowSprite(frame.Width * 0.5, frame.Height * 0.5, vigR,
                    accentMix, (0.06 + 0.04 * breath) * f);
            }

            // LAYER 1 · Gaussian plasma bed.
            if (!throttled)
            {
                using (session.PushBlurLayer(sizePx * 2.4, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < count; i++)
                    {
                        (double bx, double by, double k) o = Orb(dots, i, reduced, amp, t, f);
                        Rgba glowCol = dots[i].Rgba.Mix(accentMix, 0.34);
                        double r = sizePx * 1.85;
                        session.FillCircle(o.bx, o.by, r, glowCol.WithOpacity(ClampD(0.46 * o.k, 0, 0.85)));
                    }
                }
                session.Blend = SubstrateBlend.Add;
            }

            // LAYER 2..4 · per-orb bright bloom → saturated halo → hot core.
            for (int i = 0; i < count; i++)
            {
                (double bx, double by, double k) o = Orb(dots, i, reduced, amp, t, f);
                Rgba col = dots[i].Rgba;

                if (throttled)
                {
                    session.DrawGlowSprite(o.bx, o.by, sizePx * 2.6, accentMix, ClampD(0.30 * o.k, 0, 0.62));
                }
                else
                {
                    double bloomR = sizePx * (2.8 + 0.9 * (o.k - 0.5)) + 3;
                    session.DrawGlowSprite(o.bx, o.by, bloomR, Rgba.White, ClampD(0.24 * o.k, 0, 0.5));
                }

                double hr = sizePx * 1.5;
                session.FillCircle(o.bx, o.by, hr, col.Mix(accentMix, 0.18)
                    .WithOpacity(ClampD((throttled ? 0.40 : 0.34) * o.k, 0, 0.7)));

                double hx = dots[i].X, hy = dots[i].Y;
                double cr = System.Math.Max(1.0, sizePx * (0.64 + 0.12 * (o.k - 0.85)));
                session.FillCircle(hx, hy, cr, col.ToWhite(0.7).WithOpacity(ClampD(0.98 * o.k, 0, 1)));
            }

            // gust crest: a slow brightness band sweeping the curtain L→R.
            if (!reduced && !throttled)
            {
                double radius = frame.CloudRadius;
                double span = radius * 2.6;
                double crestX = frame.Cx - radius * 1.3 + Mod(t * (span / 9), span);
                double band = radius * 0.32;
                if (band > 0)
                {
                    for (int i = 0; i < count; i++)
                    {
                        double d = dots[i].X - crestX;
                        if (d < -band || d > band) continue;
                        double wv = 1 - System.Math.Abs(d) / band;
                        double r = sizePx * (2.2 + 2.6 * wv);
                        session.DrawGlowSprite(dots[i].X, dots[i].Y, r, Rgba.White, 0.12 * wv * wv * f);
                    }
                }
            }
        }
        else
        {
            // LIGHT canvas: soft gas haze + crisp legible cores.
            if (!throttled)
            {
                using (session.PushBlurLayer(sizePx * 1.8, SubstrateBlend.Normal))
                {
                    session.Blend = SubstrateBlend.Normal;
                    for (int i = 0; i < count; i++)
                    {
                        (double bx, double by, double k) o = Orb(dots, i, reduced, amp, t, f);
                        double r = sizePx * 1.8;
                        session.FillCircle(o.bx, o.by, r, dots[i].Rgba.WithOpacity(ClampD(0.22 * o.k, 0, 0.4)));
                    }
                }
                session.Blend = SubstrateBlend.Normal;
            }

            for (int i = 0; i < count; i++)
            {
                (double bx, double by, double k) o = Orb(dots, i, reduced, amp, t, f);
                Rgba col = dots[i].Rgba;
                double r2 = sizePx * (throttled ? 1.7 : 1.25);
                session.FillCircle(o.bx, o.by, r2, col.WithOpacity(ClampD((throttled ? 0.26 : 0.22) * o.k, 0, 0.42)));

                double hx = dots[i].X, hy = dots[i].Y;
                double cr = System.Math.Max(0.9, sizePx * 0.7);
                session.FillCircle(hx, hy, cr, col.Mix(frame.Stage.Ink, 0.12).WithOpacity(ClampD(0.96 * f, 0, 1)));
            }
        }

        return true;
    }

    /// <summary>Positive modulo (Swift <c>truncatingRemainder</c> on a non-negative operand).</summary>
    private static double Mod(double a, double m)
    {
        double r = a % m;
        return r < 0 ? r + m : r;
    }
}
