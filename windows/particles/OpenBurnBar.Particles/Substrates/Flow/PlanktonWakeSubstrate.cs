using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Flow;

/// <summary>
/// Plankton Wake — C# port of Swift <c>Views/Substrate/Flow/PlanktonWakeSubstrate.swift</c>
/// (itself a port of imaginethat <c>flow/plankton-wake.ts</c>). Each silhouette point
/// is a bioluminescent ember on an analytic curl-noise current: a true Gaussian bloom
/// underlayer (dark), a saturated cyan→aqua ember body with a 2-ghost motion comet,
/// and a hot teal-lit core with a white sparkle pop at the curl-shear flare.
/// </summary>
/// <remarks>
/// Motion is the divergence-free curl of a sum-of-sines stream function, advecting
/// each ember in a hard-capped ≤2px orbit (the core never migrates), plus a per-ember
/// ~0.4 Hz breathe and a curl-shear-gated sparkle — all on <c>frame.T</c> + a per-point
/// seed. The fixed cyan/aqua ember hue is theme-independent (mapped to a tinted glow
/// sprite); the per-point color tints body + core + wash. <c>reduced</c> freezes to a
/// poised still ember-field; <c>batteryThrottled</c> drops the heaviest blurred pass.
/// Constants match the Swift original line-for-line.
/// </remarks>
public sealed class PlanktonWakeSubstrate : ISwarmSubstrate
{
    // The cached cyan→aquamarine ember halo hue (the Swift 96px sprite's dominant
    // stop band). The Win2D glow-sprite cache tints its soft radial ramp by this.
    private static readonly Rgba Ember = new(90.0 / 255, 224.0 / 255, 238.0 / 255);

    // Per-instance scratch reused across frames (grown on count change) so the
    // bloom + crisp passes share one drift/brightness solve with zero per-frame GC.
    private double[] _px = Array.Empty<double>();
    private double[] _py = Array.Empty<double>();
    private double[] _kk = Array.Empty<double>();
    private double[] _adx = Array.Empty<double>();
    private double[] _ady = Array.Empty<double>();

    private static double CurlX(double x, double y, double t) =>
        System.Math.Cos(x * 0.018 + t * 0.22) * System.Math.Cos(y * 0.021 - t * 0.17) * 0.021
        - System.Math.Sin(x * 0.011 - t * 0.13) * System.Math.Sin(y * 0.014 + t * 0.19) * 0.014
        + System.Math.Cos(y * 0.033 + t * 0.31) * 0.033 * 0.6;

    private static double CurlY(double x, double y, double t) =>
        -(System.Math.Sin(x * 0.018 + t * 0.22) * System.Math.Sin(y * 0.021 - t * 0.17) * -0.018
          + System.Math.Cos(x * 0.011 - t * 0.13) * System.Math.Cos(y * 0.014 + t * 0.19) * 0.011
          + System.Math.Sin(x * 0.027 - t * 0.27) * 0.027 * 0.6);

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;

        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.4 + 0.6;

        Grow(count);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // Precompute drift + brightness ONCE (no double trig across passes).
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double tx = d.X, ty = d.Y;
            double seed = Shash(i * 1.37 + 0.5);
            double phase = seed * Tau;

            double dx = 0, dy = 0, speed = 0;
            if (!reduced)
            {
                double vx = CurlX(tx, ty, t);
                double vy = CurlY(tx, ty, t);
                speed = System.Math.Sqrt(vx * vx + vy * vy);
                double wob = t * (0.55 + seed * 0.5) + phase;
                dx = vx * 64 + System.Math.Cos(wob) * 0.9;
                dy = vy * 64 + System.Math.Sin(wob) * 0.9;
                double dmag = System.Math.Sqrt(dx * dx + dy * dy);
                if (dmag > 2) { dx = dx / dmag * 2; dy = dy / dmag * 2; }
            }

            double breatheArg = reduced ? phase * 13.0 : t * 2.5 + phase;
            double br = 0.5 + 0.5 * System.Math.Sin(breatheArg);
            double k = 0.46 + 0.34 * br;

            if (!reduced)
            {
                double s = System.Math.Sin(t * (1.0 + seed * 1.3) + phase * 5.0 + speed * 220.0);
                if (s > 0.9) k += (s - 0.9) / 0.1 * (0.55 + speed * 26);
            }

            k = ClampD(k, 0.18, 2.4) * form;
            _px[i] = tx + dx; _py[i] = ty + dy; _kk[i] = k; _adx[i] = dx; _ady[i] = dy;
        }

        if (dark)
        {
            // PASS 1 (heaviest, dropped on throttle): TRUE GAUSSIAN BLOOM UNDERLAYER.
            if (!lite)
            {
                using (session.PushBlurLayer(System.Math.Max(3.4, sizePx * 3.0), SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < count; i++)
                    {
                        double k = _kk[i];
                        double x = _px[i], y = _py[i];
                        double wide = sizePx * (3.6 + 2.8 * k);
                        session.DrawGlowSprite(x, y, wide, Ember, ClampD(0.15 * k, 0, 0.62));
                        Rgba c = dots[i].Rgba;
                        double bodyR = System.Math.Max(1.0, sizePx * 1.7);
                        session.FillCircle(x, y, bodyR, c.WithOpacity(ClampD(0.23 * k, 0, 0.62)));
                    }
                }
                session.Blend = SubstrateBlend.Add;
            }

            // PASS 2: saturated body + hot core per point (crisp, on top of the bloom).
            for (int i = 0; i < count; i++)
            {
                double k = _kk[i];
                double x = _px[i], y = _py[i];
                Rgba col = dots[i].Rgba;

                if (!lite && !reduced)
                {
                    double trailAng = System.Math.Atan2(_ady[i], _adx[i]);
                    double trailLen = sizePx * (0.9 + 1.4 * k);
                    double tcos = System.Math.Cos(trailAng), tsin = System.Math.Sin(trailAng);
                    double tr = sizePx * (2.0 + 0.6 * k);
                    for (int s = 1; s <= 2; s++)
                    {
                        double a = 0.06 * k * (1 - s * 0.4);
                        if (a <= 0) continue;
                        double gx = x - tcos * trailLen * s;
                        double gy = y - tsin * trailLen * s;
                        session.DrawGlowSprite(gx, gy, tr, Ember, a);
                    }
                }

                double bloomR = sizePx * (3.0 + 2.1 * k);
                session.DrawGlowSprite(x, y, bloomR, Ember, ClampD(0.24 * k, 0, 0.7));

                double bodyR = System.Math.Max(0.9, sizePx * 1.4);
                session.FillCircle(x, y, bodyR, col.WithOpacity(ClampD(0.46 * k, 0, 0.78)));

                double coreR = System.Math.Max(0.7, sizePx * 0.6);
                var hot = new Rgba(
                    col.R + (1 - col.R) * 0.74,
                    col.G + (1 - col.G) * 0.86,
                    col.B + (1 - col.B) * 0.72,
                    ClampD(1.0 * k, 0, 1));
                session.FillCircle(x, y, coreR, hot);

                if (k > 1.05)
                {
                    double sr = System.Math.Max(0.5, sizePx * 0.34);
                    double pop = ClampD((k - 1.05) * 0.8, 0, 0.7);
                    session.FillCircle(x, y, sr, Rgba.White.WithOpacity(pop));
                }
            }
        }
        else
        {
            // LIGHT canvas: cool plankton ink dots, source-over, never blown out.
            if (!lite)
            {
                using (session.PushBlurLayer(System.Math.Max(2.5, sizePx * 2.0), SubstrateBlend.Normal))
                {
                    session.Blend = SubstrateBlend.Normal;
                    for (int i = 0; i < count; i++)
                    {
                        double k = _kk[i];
                        double x = _px[i], y = _py[i];
                        Rgba col = dots[i].Rgba;
                        double r = sizePx * (1.9 + 0.7 * k);
                        // layer opacity 0.5 baked into fill alpha.
                        session.FillCircle(x, y, r, col.WithOpacity(0.5 * ClampD(0.22 * k, 0, 0.4)));
                    }
                }
                session.Blend = SubstrateBlend.Normal;
            }

            for (int i = 0; i < count; i++)
            {
                double k = _kk[i];
                double x = _px[i], y = _py[i];
                Rgba col = dots[i].Rgba;

                double haloR = sizePx * (1.7 + 0.4 * k);
                session.FillCircle(x, y, haloR, col.WithOpacity(ClampD(0.13 * k, 0, 0.28)));

                double coreR = System.Math.Max(0.85, sizePx * 0.62);
                session.FillCircle(x, y, coreR, col.WithOpacity(ClampD(0.92 * form, 0, 1)));

                if (!reduced && k > 1.1)
                {
                    double speckR = System.Math.Max(0.6, sizePx * 0.4);
                    var lit = new Rgba(
                        col.R + (1 - col.R) * 0.5,
                        col.G + (1 - col.G) * 0.55,
                        col.B + (1 - col.B) * 0.4,
                        ClampD((k - 1.1) * 0.7, 0, 0.5));
                    session.FillCircle(x, y, speckR, lit);
                }
            }
        }

        return true;
    }

    private void Grow(int n)
    {
        if (_px.Length >= n) return;
        _px = new double[n];
        _py = new double[n];
        _kk = new double[n];
        _adx = new double[n];
        _ady = new double[n];
    }
}
