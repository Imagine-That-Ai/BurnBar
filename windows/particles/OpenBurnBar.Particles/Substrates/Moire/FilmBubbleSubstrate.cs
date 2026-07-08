using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Moire;

/// <summary>
/// Film Bubble — faithful C# port of Swift
/// <c>Views/Substrate/Moire/FilmBubbleSubstrate.swift</c>. Every silhouette point is
/// a tiny iridescent soap bubble; surface colour comes from thin-film interference:
/// a virtual film thickness = the SUM of two slightly detuned wave fields sampled in
/// node-space. Because the two carriers beat, rainbow moiré sheets drift across the
/// cluster like colour sweeping a real bubble. Thickness → a 256-entry thin-film
/// spectrum LUT (cyan/magenta-heavy), blended 62% spectrum / 38% brand.
/// </summary>
/// <remarks>
/// DARK lays a true GAUSSIAN bloom field (an iridescent glow under the whole cloud),
/// then per bubble: a saturated body disc → a glassy translucent sphere sprite
/// (<see cref="GlowProfile.Sphere"/>) → a bright rim RING
/// (<see cref="ISubstrateDrawingSession.StrokeCircle"/>) → a crisp white specular
/// catchlight (<see cref="GlowProfile.Spark"/>). LIGHT is a normal-blend colored
/// under-halo + volume disc + sphere + crisp rim + spec dot. On the sparse Atelier
/// backdrop a continuous thin-film sheet connects the bubbles (density-splatted).
/// <c>reduced</c> pins the thickness phase; <c>batteryThrottled</c> drops the bloom.
/// The exact constants ARE the look.
/// </remarks>
public sealed class FilmBubbleSubstrate : ISwarmSubstrate
{
    private double[] _pxs = Array.Empty<double>();
    private double[] _pys = Array.Empty<double>();
    private double[] _rads = Array.Empty<double>();
    private Rgba[] _rims = Array.Empty<Rgba>();

    private double[] _filmDensity = Array.Empty<double>();
    private int _filmGridW, _filmGridH;

    private const int SpectrumN = 256;
    private static readonly Rgba[] Spectrum = BuildSpectrum();

    private static Rgba[] BuildSpectrum()
    {
        var outArr = new Rgba[SpectrumN];
        for (int i = 0; i < SpectrumN; i++)
        {
            double u = (double)i / SpectrumN;
            double hue = Frac(0.58 + 0.92 * u);
            double sat = ClampD(0.62 + 0.34 * System.Math.Sin(u * Tau * 2 + 0.4), 0.32, 0.98);
            double lit = ClampD(0.60 + 0.12 * System.Math.Sin(u * Tau + 1.1), 0.46, 0.80);
            (double r, double g, double bl) = HslToRgb(hue, sat, lit);
            outArr[i] = new Rgba(r, g, bl, 1);
        }
        return outArr;
    }

    private static (double, double, double) HslToRgb(double h, double s, double l)
    {
        double c = (1 - System.Math.Abs(2 * l - 1)) * s;
        double hp = Frac(h) * 6;
        double x = c * (1 - System.Math.Abs(hp % 2 - 1));
        double r = 0, g = 0, b = 0;
        if (hp < 1) { r = c; g = x; }
        else if (hp < 2) { r = x; g = c; }
        else if (hp < 3) { g = c; b = x; }
        else if (hp < 4) { g = x; b = c; }
        else if (hp < 5) { r = x; b = c; }
        else { r = c; b = x; }
        double m = l - c / 2;
        return (r + m, g + m, b + m);
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        double cx = frame.Cx, cy = frame.Cy, radius = frame.CloudRadius;

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.55 + 0.45;

        double invR = 1 / System.Math.Max(1, radius);
        double tt = reduced ? 1.7 : t;
        double aFx = 2.1 * invR;
        double aFy = 1.3 * invR;
        double bFx = 2.55 * invR;
        double bFy = 1.05 * invR;
        const double aRate = 0.55;
        const double bRate = -0.42;
        double cFx = 0.78 * invR;
        double cFy = 0.55 * invR;
        const double cRate = 0.21;
        double specN = SpectrumN;

        if (_pxs.Length != count)
        {
            _pxs = new double[count];
            _pys = new double[count];
            _rads = new double[count];
            _rims = new Rgba[count];
        }
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = frame.Dots[i];
            double px = d.X, py = d.Y;
            double seed = Shash(i * 1.37 + 0.5);

            double dxo = 0.0, dyo = 0.0, wob = 1.0;
            if (!reduced)
            {
                double ph = seed * Tau;
                dxo = System.Math.Sin(t * 0.6 + ph) * 0.9;
                dyo = System.Math.Sin(t * 0.47 + ph * 1.7 + 1.3) * 0.9;
                wob = 0.9 + 0.12 * System.Math.Sin(t * 1.3 + ph * 2.3);
            }

            double rx = px - cx, ry = py - cy;
            double thick = System.Math.Sin(rx * aFx + ry * aFy * 0.6 + tt * aRate)
                + System.Math.Sin(rx * bFx * 0.7 + ry * bFy + tt * bRate + seed * 1.1);
            double u = Frac(thick * 0.25 + 0.5);
            int si = System.Math.Min(SpectrumN - 1, System.Math.Max(0, (int)(u * specN)));

            _pxs[i] = px + dxo;
            _pys[i] = py + dyo;
            _rads[i] = System.Math.Max(0.6, sizePx * 2.5 * wob * (0.74 + 0.26 * f));
            _rims[i] = d.Rgba.Mix(Spectrum[si], 0.62);
        }

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        bool sparse = !frame.IsShapeMode;

        double cell = ClampD(sizePx * 17, 30, 56);
        double invCell = 1.0 / cell;
        if (sparse && !lite)
        {
            int gw = System.Math.Max(2, (int)System.Math.Ceiling(frame.Width * invCell) + 1);
            int gh = System.Math.Max(2, (int)System.Math.Ceiling(frame.Height * invCell) + 1);
            if (_filmGridW != gw || _filmGridH != gh)
            {
                _filmGridW = gw; _filmGridH = gh;
                _filmDensity = new double[gw * gh];
            }
            else
            {
                Array.Clear(_filmDensity);
            }
            for (int i = 0; i < count; i++)
            {
                SwarmSubstrateDot d = frame.Dots[i];
                double gx = d.X * invCell, gy = d.Y * invCell;
                int ci = System.Math.Min(gw - 1, System.Math.Max(0, (int)gx));
                int cj = System.Math.Min(gh - 1, System.Math.Max(0, (int)gy));
                for (int jj = System.Math.Max(0, cj - 1); jj <= System.Math.Min(gh - 1, cj + 1); jj++)
                    for (int ii = System.Math.Max(0, ci - 1); ii <= System.Math.Min(gw - 1, ci + 1); ii++)
                    {
                        double ddx = ii + 0.5 - gx;
                        double ddy = jj + 0.5 - gy;
                        double wq = 1.0 - (ddx * ddx + ddy * ddy) * 0.55;
                        if (wq > 0) _filmDensity[jj * gw + ii] += wq;
                    }
            }
        }

        // ── BLOOM FIELD ──
        if (!lite)
        {
            double bloomBoost = sparse ? 1.5 : 1.0;
            double blurScale = (dark ? 1.15 : 0.9) * (sparse ? 1.35 : 1.0);
            double haloR = dark ? 1.35 : 1.1;
            double haloA = (dark ? 0.24 : 0.16) * f * bloomBoost;
            double filmBlur = System.Math.Max(2.0, sizePx * 2.0 * blurScale + (sparse ? cell * 0.42 : 0));
            using (session.PushBlurLayer(filmBlur, dark ? SubstrateBlend.Add : SubstrateBlend.Normal))
            {
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

                if (sparse)
                {
                    int gw = _filmGridW, gh = _filmGridH;
                    double filmA = (dark ? 0.13 : 0.085) * f;
                    double fr = cell * 0.95;
                    for (int jjj = 0; jjj < gh; jjj++)
                    {
                        double cyp = (jjj + 0.5) * cell;
                        double ry = cyp - cy;
                        for (int iii = 0; iii < gw; iii++)
                        {
                            double dens = _filmDensity[jjj * gw + iii];
                            if (dens > 0.004)
                            {
                                double cxp = (iii + 0.5) * cell;
                                double rx = cxp - cx;
                                double thick = System.Math.Sin(rx * aFx + ry * aFy * 0.6 + tt * aRate)
                                    + System.Math.Sin(rx * bFx * 0.7 + ry * bFy + tt * bRate)
                                    + 0.9 * System.Math.Sin(rx * cFx + ry * cFy + tt * cRate);
                                double u = Frac(thick * 0.16 + 0.5);
                                int si = System.Math.Min(SpectrumN - 1, System.Math.Max(0, (int)(u * specN)));
                                double a = ClampD(filmA * Smoothstep(0.0, 1.5, dens), 0, dark ? 0.5 : 0.4);
                                session.FillCircle(cxp, cyp, fr, Spectrum[si].WithOpacity(a));
                            }
                        }
                    }
                }

                for (int i = 0; i < count; i++)
                {
                    double r = _rads[i] * haloR;
                    Rgba glow = _rims[i].WithOpacity(ClampD(haloA, 0, 1));
                    session.FillCircle(_pxs[i], _pys[i], r, glow);
                }
            }
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        }

        // ── per-bubble crisp passes (body → glass → rim → spark) ──
        for (int i = 0; i < count; i++)
        {
            double x = _pxs[i], y = _pys[i];
            double rad = _rads[i];
            double r2 = rad;
            Rgba rim = _rims[i];

            if (dark)
            {
                double rc = rad * 0.95;
                session.FillCircle(x, y, rc, rim.WithOpacity(ClampD(0.5 * f, 0, 1)));
                session.DrawGlowSprite(x, y, r2, Rgba.White, ClampD(0.66 * f, 0, 1), GlowProfile.Sphere);
                double rr = rad * 0.84;
                session.StrokeCircle(x, y, rr, rim.ToWhite(0.32).WithOpacity(ClampD(0.7 * f, 0, 1)),
                    System.Math.Max(0.6, rad * 0.3));
            }
            else
            {
                double lipR = rad * 0.92;
                session.FillCircle(x, y + rad * 0.16, lipR, rim.Darkened(0.45).WithOpacity(ClampD(0.22 * f, 0, 1)));
                double rd = rad * 1.0;
                session.FillCircle(x, y, rd, rim.WithOpacity(ClampD(0.4 * f, 0, 1)));
                session.DrawGlowSprite(x, y, r2, Rgba.White, ClampD(0.8 * f, 0, 1), GlowProfile.Sphere);
                double rr = rad * 0.86;
                session.StrokeCircle(x, y, rr, rim.Darkened(0.12).WithOpacity(ClampD(0.55 * f, 0, 1)),
                    System.Math.Max(0.6, rad * 0.26));
            }

            double sr = System.Math.Max(0.4, rad * 0.4);
            double ox = x - rad * 0.34;
            double oy = y - rad * 0.36;
            session.DrawGlowSprite(ox, oy, sr, Rgba.White, ClampD((dark ? 0.95 : 0.7) * f, 0, 1), GlowProfile.Spark);
        }

        return true;
    }
}
