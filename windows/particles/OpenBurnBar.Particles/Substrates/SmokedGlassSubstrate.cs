using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Smoked Glass Slab — faithful C# port of Swift
/// <c>Views/Substrate/Volumetric/SmokedGlassSubstrate.swift</c> (port of imaginethat
/// <c>volumetric/smoked-glass.ts</c>, the only SOLID material in the family). Each
/// silhouette point is a small extruded glass CHIP: a rotated rounded quad with a
/// static per-point facet normal (outward bearing from the centroid + per-seed jitter)
/// and a baked depth = screen altitude. A single slow top-light rakes the slab so the
/// per-chip <c>lit</c> migrates and specular rims crawl.
/// </summary>
/// <remarks>
/// Chips draw DEPTH-SORTED back→front (the load-bearing correctness detail). Layered:
/// a continuous frosted VOLUME (full-canvas floor + blurred haze pools) on the sparse
/// free-swarm; a DARK Gaussian bloom BED; the depth-sorted colored smoked BASE slabs
/// (rounded quads); light gated to the LIT SIDE (corner sheen, breathing interior glow,
/// hot core sprites); and a face-culled near-white specular RIM stroke on facets whose
/// <c>n·light ≥ 0.45</c>. <c>reduced</c> holds a poised still slab; <c>batteryThrottled</c>
/// drops the bloom bed + rim + interior glow. Rotated rounded quads go through
/// <see cref="ISubstrateDrawingSession.FillRoundedQuad"/>; the full-canvas wash through
/// <see cref="ISubstrateDrawingSession.FillRect"/>.
/// </remarks>
public sealed class SmokedGlassSubstrate : ISwarmSubstrate
{
    private int _n = -1;
    private double[] _nxA = Array.Empty<double>();
    private double[] _nyA = Array.Empty<double>();
    private double[] _depthA = Array.Empty<double>();
    private double[] _phaseA = Array.Empty<double>();
    private double[] _rotC = Array.Empty<double>();
    private double[] _rotS = Array.Empty<double>();
    private int[] _orderA = Array.Empty<int>();
    private double[] _swX = Array.Empty<double>();
    private double[] _swY = Array.Empty<double>();
    private double[] _litA = Array.Empty<double>();

    private void BuildField(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        _n = count;
        _nxA = new double[count]; _nyA = new double[count];
        _depthA = new double[count]; _phaseA = new double[count];
        _rotC = new double[count]; _rotS = new double[count];
        _orderA = new int[count];
        _swX = new double[count]; _swY = new double[count]; _litA = new double[count];
        if (count == 0) return;

        double cx = frame.Cx, cy = frame.Cy;
        double minY = dots[0].Y, maxY = dots[0].Y;
        for (int i = 0; i < count; i++) { if (dots[i].Y < minY) minY = dots[i].Y; if (dots[i].Y > maxY) maxY = dots[i].Y; }
        double span = (maxY - minY) == 0 ? 1 : (maxY - minY);

        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double seed = Shash(i * 1.37 + 0.5);
            double bearing = System.Math.Atan2(d.Y - cy, d.X - cx);
            double jit = (Shash(i * 2.71 + 0.13) - 0.5) * 1.7;
            double a = bearing + jit;
            _nxA[i] = System.Math.Cos(a);
            _nyA[i] = System.Math.Sin(a);
            _depthA[i] = (d.Y - minY) / span;
            _phaseA[i] = seed * Tau;
            double half = System.Math.Atan2(_nyA[i], _nxA[i]) * 0.5;
            _rotC[i] = System.Math.Cos(half);
            _rotS[i] = System.Math.Sin(half);
            _orderA[i] = i;
        }
        Array.Sort(_orderA, (x, y) => _depthA[x].CompareTo(_depthA[y]));
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;
        if (_n != count) BuildField(frame);

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;
        double radius = frame.CloudRadius;
        double sizePx = frame.SizePx;
        double f = ClampD(frame.SettleProgress, 0, 1) * 0.5 + 0.5;

        double lightAng = reduced ? -1.05 : -1.05 + 0.5 * System.Math.Sin(t * 0.04);
        double lx = System.Math.Cos(lightAng), ly = System.Math.Sin(lightAng);
        double breath = reduced ? 0.6 : 0.5 + 0.5 * System.Math.Sin(t * (Tau / 1.8));
        bool dense = frame.IsShapeMode;
        double sparseLift = dense ? 1.0 : 1.18;
        double opLift = dense ? 0.0 : 0.07;
        double hazeK = dense ? 0.30 : 1.0;

        double chipR = ClampD((sizePx * 1.9 + radius * 0.006) * sparseLift, 1.7, 5.5);

        double smoke = dark ? 0.30 : 0.18;
        double coolR = dark ? 122.0 / 255 : 70.0 / 255;
        double coolG = dark ? 142.0 / 255 : 84.0 / 255;
        double coolB = dark ? 178.0 / 255 : 116.0 / 255;
        Rgba accent = frame.Stage.Accent;

        // ── per-frame preloop: sub-pixel sway + facet lighting ──
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            if (!reduced)
            {
                double swAmp = 0.5 + 0.7 * _depthA[i];
                x += System.Math.Sin(t * 0.5 + _phaseA[i]) * swAmp;
                y += System.Math.Cos(t * 0.46 + _phaseA[i] * 1.3) * swAmp * 0.7;
            }
            _swX[i] = x; _swY[i] = y;
            double ndl = _nxA[i] * lx + _nyA[i] * ly;
            _litA[i] = ClampD(ndl * 0.5 + 0.5, 0, 1);
        }

        double cornerR = chipR * 0.42;

        // colored smoked base fill for chip i.
        Rgba BaseColor(int i)
        {
            Rgba baseCol = dots[i].Rgba;
            double dep = _depthA[i];
            double shade = 0.58 + 0.34 * dep;
            double r0 = Lerp(baseCol.R, coolR, smoke) * shade;
            double g0 = Lerp(baseCol.G, coolG, smoke) * shade;
            double b0 = Lerp(baseCol.B, coolB, smoke) * shade;
            double a = ClampD(((dark ? 0.5 + 0.32 * dep : 0.6 + 0.24 * dep) + opLift) * f, 0, dark ? 0.94 : 0.97);
            return new Rgba(ClampD(r0, 0, 1), ClampD(g0, 0, 1), ClampD(b0, 0, 1), a);
        }

        // ── layer -1: continuous frosted smoked-glass VOLUME ──
        if (hazeK > 0.01)
        {
            double fogR = Lerp(coolR, accent.R, 0.26);
            double fogG = Lerp(coolG, accent.G, 0.26);
            double fogB = Lerp(coolB, accent.B, 0.26);

            if (!dense)
            {
                double floorA = ClampD((dark ? 0.12 : 0.095) * (lite ? 0.82 : 1.0) * f, 0, 0.20);
                if (floorA > 0.004)
                {
                    session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                    session.FillRect(0, 0, frame.Width, frame.Height, new Rgba(fogR, fogG, fogB, floorA));
                }
            }

            double hazeDisc = chipR * (dense ? 6.0 : 10.0);
            double hazeBlur = lite ? System.Math.Max(9.0, chipR * 3.4) : System.Math.Max(16.0, chipR * 6.2);
            double poolA = (dark ? 0.060 : 0.050) * hazeK * (lite ? 0.7 : 1.0);
            Rgba poolCol = dark
                ? new Rgba(fogR, fogG, fogB, 1).ToWhite(0.05)
                : new Rgba(Lerp(fogR, 0.20, 0.30), Lerp(fogG, 0.25, 0.30), Lerp(fogB, 0.38, 0.30), 1);
            using (session.PushBlurLayer(hazeBlur, dark ? SubstrateBlend.Add : SubstrateBlend.Normal))
            {
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                for (int i = 0; i < count; i++)
                {
                    double a = ClampD(poolA * (0.78 + 0.22 * _depthA[i]) * f, 0, 0.16);
                    if (a < 0.004) continue;
                    session.FillCircle(dots[i].X, dots[i].Y, hazeDisc, poolCol.WithOpacity(a));
                }
            }
        }

        // ── layer 0 (DARK only): real Gaussian bloom bed under the slab. ──
        if (dark && !lite)
        {
            double bloomDisc = chipR * 2.7;
            double blurR = System.Math.Max(4.0, chipR * 1.9);
            using (session.PushBlurLayer(blurR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < count; i++)
                {
                    SwarmSubstrateDot d = dots[i];
                    double lit = _litA[i];
                    double dep = _depthA[i];
                    Rgba hue = accent.Mix(SampleRamp(Iris, d.ColorIndex), 0.34);
                    Rgba gcol = d.Rgba.Mix(hue, 0.42).ToWhite(0.10);
                    double k = (0.42 + 0.58 * lit) * (0.7 + 0.3 * dep);
                    double a = ClampD(0.16 * k * f, 0, 0.42);
                    session.FillCircle(d.X, d.Y, bloomDisc, gcol.WithOpacity(a));
                }
            }
        }

        Span<LineSegment> one = stackalloc LineSegment[1];

        if (dark)
        {
            // Body (.normal, back→front).
            session.Blend = SubstrateBlend.Normal;
            for (int oi = 0; oi < count; oi++)
            {
                int i = _orderA[oi];
                session.FillRoundedQuad(_swX[i], _swY[i], chipR, cornerR, _rotC[i], _rotS[i], BaseColor(i));
            }

            // Highlights (.plusLighter): gated to the lit side.
            session.Blend = SubstrateBlend.Add;
            for (int i = 0; i < count; i++)
            {
                double lit = _litA[i];
                if (lit <= 0.30) continue;
                double x = _swX[i], y = _swY[i];
                double sk = Smoothstep(0.30, 1.0, lit);
                double sa = ClampD(0.42 * sk * f, 0, 0.55);
                if (sa > 0.01)
                {
                    double sr = chipR * 1.05;
                    double ex = x + lx * chipR * 0.5;
                    double ey = y + ly * chipR * 0.5;
                    session.DrawGlowSprite(ex, ey, sr, Rgba.White, sa);
                }
                if (!lite && lit > 0.44)
                {
                    double tg = (lit - 0.44) / 0.56;
                    double ta = ClampD(0.26 * tg * (0.6 + 0.4 * breath) * f, 0, 0.42);
                    if (ta > 0.01)
                    {
                        double tr = chipR * (0.7 + 0.35 * tg);
                        session.DrawGlowSprite(x, y, tr, Rgba.White, ta);
                    }
                }
                if (lit > 0.66)
                {
                    double tw = reduced ? 0.7 : 0.6 + 0.4 * System.Math.Sin(t * 1.7 + _phaseA[i] * 1.7);
                    double ck = Smoothstep(0.66, 1.0, lit) * tw;
                    double ca = ClampD(0.5 * ck * f, 0, 0.7);
                    if (ca > 0.01)
                    {
                        double cr = chipR * 0.62;
                        session.DrawGlowSprite(x, y, cr, Rgba.White, ca);
                    }
                }
            }
        }
        else
        {
            // LIGHT: source-over doesn't commute → full stack back→front per chip.
            session.Blend = SubstrateBlend.Normal;
            for (int oi = 0; oi < count; oi++)
            {
                int i = _orderA[oi];
                double x = _swX[i], y = _swY[i];
                double lit = _litA[i];
                double dep = _depthA[i];
                double shA = ClampD((0.10 + 0.10 * dep) * f, 0, 0.22);
                if (shA > 0.01)
                {
                    double so = chipR * 0.3;
                    session.FillRoundedQuad(x + so, y + so * 1.2, chipR, cornerR, _rotC[i], _rotS[i],
                        new Rgba(0.20, 0.25, 0.38, shA));
                }
                session.FillRoundedQuad(x, y, chipR, cornerR, _rotC[i], _rotS[i], BaseColor(i));
                if (lit > 0.28)
                {
                    double sk = Smoothstep(0.28, 1.0, lit);
                    double sa = ClampD(0.36 * sk * f, 0, 0.5);
                    if (sa > 0.01)
                    {
                        double sr = chipR * 0.95;
                        double ex = x + lx * chipR * 0.46;
                        double ey = y + ly * chipR * 0.46;
                        session.DrawGlowSprite(ex, ey, sr, Rgba.White, sa);
                    }
                }
                if (!lite && lit > 0.44)
                {
                    double tg = (lit - 0.44) / 0.56;
                    double ta = ClampD(0.15 * tg * (0.6 + 0.4 * breath) * f, 0, 0.3);
                    if (ta > 0.01)
                    {
                        double tr = chipR * 0.72;
                        session.DrawGlowSprite(x, y, tr, Rgba.White, ta);
                    }
                }
            }
        }

        // ── specular rim strokes on light-facing facets (face-culled) ──
        if (!lite)
        {
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
            double specCap = dark ? 0.85 : 0.62;
            double lineW = dark ? 1.25 : 1.0;
            for (int oi = 0; oi < count; oi++)
            {
                int i = _orderA[oi];
                double ndl = _nxA[i] * lx + _nyA[i] * ly;
                if (ndl < 0.45) continue;
                double spec = (ndl - 0.45) / 0.55;
                double tw = reduced ? 0.7 : 0.65 + 0.35 * System.Math.Sin(t * 1.7 + _phaseA[i] * 1.7);
                double a = ClampD((dark ? 0.55 : 0.42) * spec * tw * f, 0, specCap);
                if (a < 0.02) continue;
                double x = _swX[i], y = _swY[i];
                double px = -ly, py = lx;
                double len = chipR * (0.85 + 0.5 * spec);
                double ex = x + lx * chipR * 0.55;
                double ey = y + ly * chipR * 0.55;
                double white = 0.55 + 0.45 * spec;
                Rgba col = dots[i].Rgba.ToWhite(white).WithOpacity(a);
                one[0] = new LineSegment(ex - px * len, ey - py * len, ex + px * len, ey + py * len);
                session.DrawLineBatch(one, col, lineW);
            }
        }

        return true;
    }
}
