using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Moire;

/// <summary>
/// Fringe Bloom — faithful C# port of Swift
/// <c>Views/Substrate/Moire/FringeBloomSubstrate.swift</c> (a real two-grating
/// interferogram rendered as a continuous glowing field). Two slowly-drifting
/// sinusoidal gratings beat against each other (drift +0.55 / -0.44, ~10° rotated);
/// the beat envelope crawls luminous moiré bands diagonally. Contrast (γ) pops the
/// antinodes; a FLOOR lift keeps the band field continuously lit.
/// </summary>
/// <remarks>
/// Two regimes, branched on shape state: SPARSE/free swarm evaluates the fringe
/// scalar field over a bounded-px grid that tiles the whole canvas (bands FILL
/// instead of collapsing into confetti), feathered + tinted by a coarse particle
/// density splat; SHAPE mode is the dense per-node interferogram (every silhouette
/// point a soft emissive node whose brightness is the fringe product). DARK is
/// additive (<see cref="SubstrateBlend.Add"/>); LIGHT is normal with alpha carrying
/// the fringe. <c>reduced</c> freezes the phases; <c>batteryThrottled</c> drops the
/// heaviest extra passes. The exact constants ARE the look — matched line-for-line.
/// </remarks>
public sealed class FringeBloomSubstrate : ISwarmSubstrate
{
    private const double Floor = 0.22;
    private const double Gamma = 1.7;
    private const double DriftA = 0.55;
    private const double DriftB = 0.44;
    private const double Beat = 0.085;

    // Per-layout density grid (rebuilt only when canvas geometry changes).
    private int _gCols, _gRows;
    private double _gStep;
    private double[] _gW = Array.Empty<double>();
    private double[] _gR = Array.Empty<double>();
    private double[] _gG = Array.Empty<double>();
    private double[] _gB = Array.Empty<double>();

    // reusable scratch for the continuous field cells.
    private readonly List<FieldCell> _cells = new(4096);

    private readonly struct FieldCell
    {
        public readonly double X, Y, Inten;
        public readonly Rgba Col;
        public FieldCell(double x, double y, double inten, in Rgba col) { X = x; Y = y; Inten = inten; Col = col; }
    }

    /// <summary>The two-grating interference field, sampled in the mark's own frame.</summary>
    private readonly struct FringeField
    {
        public readonly double Kx, Ky, C2, S2, K2, PhA, PhB, Form, FloorV, GammaV;
        public FringeField(double kx, double ky, double c2, double s2, double k2,
            double phA, double phB, double form, double floorV, double gammaV)
        {
            Kx = kx; Ky = ky; C2 = c2; S2 = s2; K2 = k2; PhA = phA; PhB = phB;
            Form = form; FloorV = floorV; GammaV = gammaV;
        }

        public (double inten, double gmix) Eval(double px, double py)
        {
            double g1 = 0.5 + 0.5 * System.Math.Sin(px * Kx + py * Ky * 0.18 + PhA);
            double u2 = px * C2 - py * S2;
            double g2 = 0.5 + 0.5 * System.Math.Sin(u2 * K2 + PhB);
            double inten = System.Math.Pow(g1 * g2, GammaV);
            inten = FloorV + (1 - FloorV) * inten;
            inten *= Form;
            return (inten, g1 * 0.5 + g2 * 0.5);
        }
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
        double width = frame.Width, height = frame.Height;

        int inShapeN = 0;
        for (int i = 0; i < count; i++) if (frame.Dots[i].InShape) inShapeN++;
        double inShapeFrac = (double)inShapeN / count;
        bool shaped = frame.IsShapeMode || (frame.SettleProgress >= 0.6 && inShapeFrac > 0.5);

        double settle = ClampD(frame.SettleProgress, 0, 1);
        double form = reduced ? 1.0 : (shaped ? settle * 0.55 + 0.45 : 0.6 + 0.4 * settle);

        double beat = reduced ? 0 : System.Math.Sin(t * Beat) * 0.5;
        double kf = shaped
            ? 5.6 / System.Math.Max(radius, 1)
            : (2 * System.Math.PI) / ClampD(System.Math.Min(width, height) / 8, 84, 150);
        double kx = kf * (1 + 0.05 * beat);
        double ky = kf * (1 + 0.05 * beat) * 0.92;
        const double ang2 = 0.18;
        double c2 = System.Math.Cos(ang2);
        double s2 = System.Math.Sin(ang2);
        double k2 = kf * 1.06;
        double phA = reduced ? 0.6 : t * DriftA;
        double phB = reduced ? -0.9 : -t * DriftB;

        var fringe = new FringeField(kx, ky, c2, s2, k2, phA, phB, form, Floor, Gamma);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // The additive bloom sprite (dark only) — the canonical white glow.
        Rgba glowTint = Rgba.White;

        if (shaped)
        {
            PaintShape(frame, session, in fringe, dark, lite, sizePx, cx, cy, Floor, count, glowTint);
        }
        else
        {
            PaintField(frame, session, in fringe, dark, lite, reduced, sizePx,
                cx, cy, width, height, count, glowTint);
        }

        return true;
    }

    // ── FREE / SPARSE — continuous interferogram feathered + tinted by density ──
    private void PaintField(SwarmSubstrateFrame frame, ISubstrateDrawingSession session,
        in FringeField fringe, bool dark, bool lite, bool reduced, double sizePx,
        double cx, double cy, double width, double height, int count, in Rgba glowTint)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        Rgba accent = frame.Stage.Accent;

        double area = System.Math.Max(width * height, 1);
        double targetCells = lite ? 1500.0 : 2800.0;
        double stepMin = ClampD(sizePx * 7.0, 15, 24);
        double gs = System.Math.Max(stepMin, System.Math.Sqrt(area / targetCells));

        double cd = System.Math.Max(gs * 2.4, 42);
        int cols = System.Math.Max(2, (int)System.Math.Ceiling(width / cd) + 1);
        int rows = System.Math.Max(2, (int)System.Math.Ceiling(height / cd) + 1);
        if (cols != _gCols || rows != _gRows || cd != _gStep)
        {
            _gCols = cols; _gRows = rows; _gStep = cd;
            int nn = cols * rows;
            _gW = new double[nn]; _gR = new double[nn]; _gG = new double[nn]; _gB = new double[nn];
        }
        else
        {
            Array.Clear(_gW); Array.Clear(_gR); Array.Clear(_gG); Array.Clear(_gB);
        }
        double invCd = 1 / cd;
        double twoSig2 = 2 * cd * cd;
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            int ix = (int)System.Math.Floor(d.X * invCd - 0.5);
            int iy = (int)System.Math.Floor(d.Y * invCd - 0.5);
            Rgba cr = d.Rgba;
            for (int jj = iy - 2; jj <= iy + 2; jj++)
            {
                if (jj < 0 || jj >= rows) continue;
                double cyp = (jj + 0.5) * cd;
                double ddy = d.Y - cyp;
                int baseIdx = jj * cols;
                for (int ii = ix - 2; ii <= ix + 2; ii++)
                {
                    if (ii < 0 || ii >= cols) continue;
                    double cxp = (ii + 0.5) * cd;
                    double ddx = d.X - cxp;
                    double wq = System.Math.Exp(-(ddx * ddx + ddy * ddy) / twoSig2);
                    int idx = baseIdx + ii;
                    _gW[idx] += wq;
                    _gR[idx] += wq * cr.R;
                    _gG[idx] += wq * cr.G;
                    _gB[idx] += wq * cr.B;
                }
            }
        }
        double maxW = 1e-6;
        foreach (double v in _gW) if (v > maxW) maxW = v;
        double invMax = 1 / maxW;

        _cells.Clear();
        int fCols = System.Math.Max(1, (int)System.Math.Ceiling(width / gs));
        int fRows = System.Math.Max(1, (int)System.Math.Ceiling(height / gs));
        for (int fy = 0; fy < fRows; fy++)
        {
            double y = (fy + 0.5) * gs;
            double py = y - cy;
            for (int fx = 0; fx < fCols; fx++)
            {
                double x = (fx + 0.5) * gs;
                (double w, double dr, double dg, double db) ds = SampleDens(x, y, invMax);
                double densN = ds.w * invMax;
                double coverage = Smoothstep(0.04, 0.20, densN);
                if (coverage > 0.02)
                {
                    (double inten, double gmix) = fringe.Eval(x - cx, py);
                    double cluster = Smoothstep(0.18, 0.62, densN);
                    double fInten = inten * coverage * (0.5 + 0.9 * cluster);
                    if (fInten >= 0.035)
                    {
                        double seed = Frac(gmix + x * 0.00065 + y * 0.00095);
                        Rgba spec = SampleRamp(Iris, seed);
                        var brand = new Rgba(ds.dr, ds.dg, ds.db, 1);
                        Rgba col = brand.Mix(spec, 0.55)
                            .Mix(accent, dark ? 0.22 : 0.05)
                            .ToWhite(dark ? 0.12 : 0.0);
                        _cells.Add(new FieldCell(x, y, fInten, col));
                    }
                }
            }
        }

        // (1) ONE real Gaussian bloom layer the whole interferogram rests in.
        double cellR = gs * 0.95;
        double blurRad = gs * (dark ? 1.05 : 0.8);
        using (session.PushBlurLayer(blurRad, dark ? SubstrateBlend.Add : SubstrateBlend.Normal))
        {
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
            foreach (FieldCell c in _cells)
            {
                double k = System.Math.Min(c.Inten, 1.6);
                double r = cellR * (0.78 + 0.42 * System.Math.Min(k, 1.2));
                double a = dark ? ClampD(0.5 * k, 0, 0.92) : ClampD(0.3 * k, 0, 0.6);
                session.FillCircle(c.X, c.Y, r, c.Col.WithOpacity(a));
            }
        }
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // (2) crisp antinode crests — sharpen the bright fringe bands (throttle drops).
        if (!lite)
        {
            double crestR = gs * 0.48;
            foreach (FieldCell c in _cells)
            {
                if (c.Inten <= 0.6) continue;
                double k = System.Math.Min(c.Inten, 1.6);
                Rgba col = dark ? c.Col.ToWhite(0.34 + 0.5 * System.Math.Min(k - 0.6, 1.0)) : c.Col.ToWhite(0.0);
                double a = dark ? ClampD(0.36 * (k - 0.55), 0, 0.72) : ClampD(0.32 * (k - 0.55), 0, 0.55);
                session.FillCircle(c.X, c.Y, crestR, col.WithOpacity(a));
            }
        }

        // (3) particle seeds — modulate the field's core brightness/colour.
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            (double pin, double pg) = fringe.Eval(d.X - cx, d.Y - cy);
            double cov = Smoothstep(0.04, 0.20, SampleDens(d.X, d.Y, invMax).w * invMax);
            double k = ClampD(pin * cov, 0, 1.6);
            if (k < 0.06) continue;
            Rgba spec = SampleRamp(Iris, Frac(pg + d.ColorIndex * 0.2));
            if (dark)
            {
                double r0 = sizePx * (1.5 + 1.4 * System.Math.Min(k, 1.0));
                session.DrawGlowSprite(d.X, d.Y, r0, glowTint, ClampD(0.52 * k, 0, 0.85));
                Rgba body = d.Rgba.Mix(spec, 0.42).ToWhite(0.2 + 0.45 * System.Math.Min(k, 1.0));
                double br = System.Math.Max(0.7, sizePx * 0.66);
                session.FillCircle(d.X, d.Y, br, body.WithOpacity(ClampD(0.5 * k, 0, 0.9)));
            }
            else
            {
                Rgba col = d.Rgba.Mix(spec, 0.3);
                double r = System.Math.Max(0.8, sizePx * 0.7);
                session.FillCircle(d.X, d.Y, r, col.WithOpacity(ClampD(0.42 * k, 0, 0.62)));
            }
        }
    }

    /// <summary>Bilinear sample of the (weight, weight-averaged brand colour) field.</summary>
    private (double w, double r, double g, double b) SampleDens(double x, double y, double invMax)
    {
        double gx = x / _gStep - 0.5, gy = y / _gStep - 0.5;
        int ix = (int)System.Math.Floor(gx), iy = (int)System.Math.Floor(gy);
        double fx = gx - ix, fy = gy - iy;
        int At(int a, int b)
        {
            int aa = System.Math.Min(System.Math.Max(a, 0), _gCols - 1);
            int bb = System.Math.Min(System.Math.Max(b, 0), _gRows - 1);
            return bb * _gCols + aa;
        }
        int i00 = At(ix, iy), i10 = At(ix + 1, iy), i01 = At(ix, iy + 1), i11 = At(ix + 1, iy + 1);
        double Bil(double[] a)
        {
            double top = a[i00] * (1 - fx) + a[i10] * fx;
            double bot = a[i01] * (1 - fx) + a[i11] * fx;
            return top * (1 - fy) + bot * fy;
        }
        double w = Bil(_gW);
        double inv = w > 1e-6 ? 1 / w : 0;
        return (w, Bil(_gR) * inv, Bil(_gG) * inv, Bil(_gB) * inv);
    }

    // ── SHAPE — the original dense per-node interferogram ──
    private void PaintShape(SwarmSubstrateFrame frame, ISubstrateDrawingSession session,
        in FringeField fringe, bool dark, bool lite, double sizePx,
        double cx, double cy, double floor, int count, in Rgba glowTint)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        Rgba accent = frame.Stage.Accent;

        if (!lite)
        {
            double bloomR = sizePx * (dark ? 2.9 : 2.1);
            double blurRad = sizePx * (dark ? 3.4 : 2.3);
            using (session.PushBlurLayer(blurRad, dark ? SubstrateBlend.Add : SubstrateBlend.Normal))
            {
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                for (int i = 0; i < count; i++)
                {
                    SwarmSubstrateDot d = dots[i];
                    (double inten, double gmix) = fringe.Eval(d.X - cx, d.Y - cy);
                    double k = ClampD(inten, 0, 1.9);
                    if (k < 0.05) continue;
                    Rgba spec = SampleRamp(Iris, Frac(gmix + d.ColorIndex * 0.2));
                    Rgba glowCol = d.Rgba.Mix(spec, 0.62).Mix(accent, dark ? 0.22 : 0.05).ToWhite(dark ? 0.16 : 0.0);
                    double r = bloomR * (0.6 + 0.9 * System.Math.Min(k, 1.4));
                    double a = dark ? ClampD(0.42 * k, 0, 0.88) : ClampD(0.24 * k, 0, 0.5);
                    session.FillCircle(d.X, d.Y, r, glowCol.WithOpacity(a));
                }
            }
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        }

        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            (double inten, double gmix) = fringe.Eval(x - cx, y - cy);
            if (inten <= 0) continue;
            Rgba spec = SampleRamp(Iris, Frac(gmix + d.ColorIndex * 0.2));

            if (dark)
            {
                double k = ClampD(inten, 0, 1.9);
                double r0 = sizePx * (2.4 + 2.8 * System.Math.Min(k, 1.0));
                session.DrawGlowSprite(x, y, r0, glowTint, ClampD(0.44 + 0.72 * k, 0, 1.0));
                Rgba bodyCol = d.Rgba.Mix(spec, 0.46);
                double bodyR = System.Math.Max(1.0, sizePx * 1.5);
                session.FillCircle(x, y, bodyR, bodyCol.WithOpacity(ClampD(0.64 * k, 0, 0.95)));
                double coreR = System.Math.Max(0.72, sizePx * 0.62);
                Rgba coreCol = bodyCol.ToWhite(0.36 + 0.55 * System.Math.Min(k, 1.0));
                session.FillCircle(x, y, coreR, coreCol.WithOpacity(ClampD(0.42 + 0.6 * (k - 0.4), 0.28, 1.0)));
                if (!lite && k > 0.7)
                {
                    double rb = sizePx * (4.8 + 3.6 * (k - 0.7));
                    session.DrawGlowSprite(x, y, rb, glowTint, ClampD(0.2 * (k - 0.7) * 2.6, 0, 0.46));
                }
            }
            else
            {
                double k = ClampD(inten, 0, 1.4);
                Rgba haloCol = d.Rgba.Mix(spec, 0.36);
                double haloR = sizePx * (2.0 + 1.4 * System.Math.Min(k, 1.0));
                session.FillCircle(x, y, haloR, haloCol.WithOpacity(ClampD(0.26 * k, 0, 0.5)));
                Rgba coreCol = d.Rgba.Mix(spec, 0.26);
                double coreR = System.Math.Max(0.92, sizePx * 0.82);
                session.FillCircle(x, y, coreR, coreCol.WithOpacity(ClampD(0.6 + 0.42 * (k - floor), 0.4, 0.97)));
            }
        }
    }
}
