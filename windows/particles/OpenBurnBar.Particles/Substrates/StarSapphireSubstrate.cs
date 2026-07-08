using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Cut Star Sapphire — faithful C# port of Swift
/// <c>Views/Substrate/Constellation/StarSapphireSubstrate.swift</c> (itself a port of
/// imaginethat <c>constellation/starsapphire.ts</c> drawBody). Every silhouette point
/// is a tiny cut sky-blue star sapphire: a 6-sided gem split into wedge facets from
/// its center, each facet filled FLAT at a brightness set by its rotated normal vs a
/// slowly-drifting top-left key (orientation shading — no real 3D).
/// </summary>
/// <remarks>
/// The 6 unit verts + 6 wedge normals are precomputed ONCE (deterministic, same on
/// every gem). Real layered depth: (1) DARK — a Gaussian-blurred additive per-gem
/// bloom disc in the gem's own hue so overlapping discs pool into a luminous field;
/// (2) source-over faceted BODY — SIX lambert wedge polygons
/// (<c>shade = 0.34 + lit²·0.9</c>), a crisp darkened-brand hex edge stroke, and a
/// near-white highlight triangle on the brightest facet; (3) a hot specular CORE —
/// a cached white-glow bloom + a crisp glint disc on the brightest VERTEX, plus a
/// faint six-ray asterism for the brightest ~22% (seed &gt; 0.78). Each gem spins its
/// facet-light assignment on <c>t·0.6·(0.7+seed·0.6)</c>; the whole-cloud key drifts
/// on <c>sin(t·0.11)</c>. <c>reduced</c> freezes a poised jewel-case;
/// <c>batteryThrottled</c> drops the bloom-under layer + asterism. The exact
/// alpha/shade constants ARE the look — line-for-line with the Swift original.
/// </remarks>
public sealed class StarSapphireSubstrate : ISwarmSubstrate
{
    private const int Facets = 6;

    // Precomputed gem geometry (built once, never per-frame).
    private readonly double[] _vx = new double[Facets];
    private readonly double[] _vy = new double[Facets];
    private readonly double[] _nx = new double[Facets];
    private readonly double[] _ny = new double[Facets];

    // Reused rotated-vertex scratch (overwritten per gem; no per-gem heap).
    private readonly double[] _rxv = new double[Facets];
    private readonly double[] _ryv = new double[Facets];

    public StarSapphireSubstrate()
    {
        int n = Facets;
        // Outer ring: slightly irregular radius wobble so the cut looks hand-faceted
        // but deterministic (identical on every gem).
        for (int i = 0; i < n; i++)
        {
            double a = i / (double)n * Tau - System.Math.PI / 2;
            double r = 0.86 + 0.14 * Shash(i * 3.1 + 1);
            _vx[i] = System.Math.Cos(a) * r;
            _vy[i] = System.Math.Sin(a) * r;
        }
        // Wedge i spans vertex i → i+1; its normal points at the edge midpoint.
        for (int i = 0; i < n; i++)
        {
            int j = (i + 1) % n;
            double mx = (_vx[i] + _vx[j]) * 0.5;
            double my = (_vy[i] + _vy[j]) * 0.5;
            double m = System.Math.Sqrt(mx * mx + my * my);
            double inv = m == 0 ? 1 : 1 / m;
            _nx[i] = mx * inv;
            _ny[i] = my * inv;
        }
    }

    /// <summary>Push a brand color toward white by per-channel amounts, with a baked alpha.</summary>
    private static Rgba WhitePush(in Rgba c, double wr, double wg, double wb, double alpha) =>
        new Rgba(c.R + (1 - c.R) * wr, c.G + (1 - c.G) * wg, c.B + (1 - c.B) * wb, alpha);

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        int n = Facets;
        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;

        // form-driven scale: gems "cut" into being as the cloud assembles.
        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.4 + 0.6;
        double gemR = System.Math.Max(2.8, frame.SizePx * 2.15) * form;

        // whole-cloud key drifts microscopically so asterism rays sweep.
        double lightA = reduced ? -2.2 : -2.2 + System.Math.Sin(t * 0.11) * 0.5;
        double baseLx = System.Math.Cos(lightA);
        double baseLy = System.Math.Sin(lightA);

        const double blueLitLift = 22.0 / 255.0;
        const double edgeBlueLift = 12.0 / 255.0;

        // ── DEPTH 1: soft colored Gaussian bloom UNDER (dark, not throttled) ──
        if (dark && !lite)
        {
            double bloomR = gemR * 0.85;
            double discR = gemR * 1.06;
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < count; i++)
                {
                    SwarmSubstrateDot d = dots[i];
                    Rgba baseCol = d.Rgba;
                    double seed = Shash(i * 1.37 + 0.5);
                    double pulse = 0.72 + 0.28 * (reduced
                        ? 0.5 + 0.5 * System.Math.Sin(seed * 17)
                        : System.Math.Sin(t * 0.9 + seed * Tau));
                    Rgba halo = WhitePush(baseCol, 0.18, 0.18, 0.30, ClampD(0.34 * pulse, 0, 0.6) * baseCol.A);
                    session.FillCircle(d.X, d.Y, discR, halo);
                }
            }
        }

        // ── DEPTH 2: faceted gem BODIES (source-over ALWAYS — facets never blow out) ──
        session.Blend = SubstrateBlend.Normal;
        Span<Vec2> tri = stackalloc Vec2[3];
        Span<Vec2> hex = stackalloc Vec2[Facets];
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            Rgba baseCol = d.Rgba;
            double alpha = baseCol.A;
            double seed = Shash(i * 1.37 + 0.5);

            double spin = reduced ? seed * Tau : t * 0.6 * (0.7 + seed * 0.6) + seed * Tau;
            double ca = System.Math.Cos(spin), sa = System.Math.Sin(spin);

            for (int fct = 0; fct < n; fct++)
            {
                _rxv[fct] = (_vx[fct] * ca - _vy[fct] * sa) * gemR;
                _ryv[fct] = (_vx[fct] * sa + _vy[fct] * ca) * gemR;
            }

            // SIX faithful lambert wedges + track the brightest facet.
            int brightF = 0;
            double brightVal = -2.0;
            for (int fct = 0; fct < n; fct++)
            {
                int g = (fct + 1) % n;
                double rnx = _nx[fct] * ca - _ny[fct] * sa;
                double rny = _nx[fct] * sa + _ny[fct] * ca;
                double dotL = rnx * baseLx + rny * baseLy; // -1 shadow … 1 lit
                double lit = 0.5 + 0.5 * dotL;
                if (dotL > brightVal) { brightVal = dotL; brightF = fct; }
                double shade = 0.34 + lit * lit * 0.9;
                var facet = new Rgba(
                    ClampD(baseCol.R * shade, 0, 1),
                    ClampD(baseCol.G * shade, 0, 1),
                    ClampD(baseCol.B * shade + lit * blueLitLift, 0, 1),
                    alpha);
                tri[0] = new Vec2(x, y);
                tri[1] = new Vec2(x + _rxv[fct], y + _ryv[fct]);
                tri[2] = new Vec2(x + _rxv[g], y + _ryv[g]);
                session.FillPolygon(tri, facet);
            }

            // crisp dark crystal edge — the hard geometry.
            if (gemR > 2.2)
            {
                for (int fct = 0; fct < n; fct++) hex[fct] = new Vec2(x + _rxv[fct], y + _ryv[fct]);
                Rgba edge = dark
                    ? new Rgba(baseCol.R * 0.2, baseCol.G * 0.22, ClampD(baseCol.B * 0.3 + edgeBlueLift, 0, 1), 0.85 * alpha)
                    : new Rgba(baseCol.R * 0.32, baseCol.G * 0.32, baseCol.B * 0.42, 0.7 * alpha);
                session.StrokePolyline(hex, edge, 1.0, closed: true);
            }

            // bright highlight triangle on the light-facing facet (the migrating cut).
            int gg = (brightF + 1) % n;
            double hiA = ClampD(0.45 + 0.5 * brightVal, 0, 0.95) * alpha;
            Rgba hi = WhitePush(baseCol, 0.7, 0.7, 0.85, hiA);
            tri[0] = new Vec2(x, y);
            tri[1] = new Vec2(x + _rxv[brightF] * 0.92, y + _ryv[brightF] * 0.92);
            tri[2] = new Vec2(x + _rxv[gg] * 0.92, y + _ryv[gg] * 0.92);
            session.FillPolygon(tri, hi);
        }

        // ── DEPTH 3: hot specular CORE — glints + asterism ──
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        Span<LineSegment> rays = stackalloc LineSegment[3];
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            Rgba baseCol = d.Rgba;
            double alpha = baseCol.A;
            double seed = Shash(i * 1.37 + 0.5);
            double spin = reduced ? seed * Tau : t * 0.6 * (0.7 + seed * 0.6) + seed * Tau;
            double ca = System.Math.Cos(spin), sa = System.Math.Sin(spin);

            // brightest VERTEX (the one facing the key) carries the glint.
            int brightI = 0;
            double brightVal = -2.0;
            for (int fct = 0; fct < n; fct++)
            {
                double rvx = _vx[fct] * ca - _vy[fct] * sa;
                double rvy = _vx[fct] * sa + _vy[fct] * ca;
                double dotL = rvx * baseLx + rvy * baseLy;
                if (dotL > brightVal) { brightVal = dotL; brightI = fct; }
            }
            double gx = x + (_vx[brightI] * ca - _vy[brightI] * sa) * gemR;
            double gy = y + (_vx[brightI] * sa + _vy[brightI] * ca) * gemR;

            double tw = reduced
                ? 0.45 + 0.4 * (0.5 + 0.5 * System.Math.Sin(seed * 21))
                : 0.45 + 0.4 * System.Math.Sin(t * (1.3 + seed) + seed * Tau);
            double glint = ClampD(tw, 0.18, 0.95) * (0.6 + 0.4 * ClampD(brightVal, 0, 1));

            // (a) cached hot-core bloom sprite (dark).
            if (dark)
            {
                double bloomR = gemR * (0.9 + 0.7 * glint);
                session.DrawGlowSprite(gx, gy, bloomR, Rgba.White, ClampD(0.5 * glint, 0, 0.7) * alpha);
            }

            // (b) crisp specular glint circle at the brightest vertex.
            double glR = System.Math.Max(1.1, gemR * 0.42);
            double glA = (dark ? glint * 0.95 : glint * 0.55) * alpha;
            Rgba glC = WhitePush(baseCol, 0.85, 0.85, 0.92, glA);
            session.FillCircle(gx, gy, glR, glC);

            // (c) brightest ~22% flash a faint six-ray asterism that sweeps.
            if (seed > 0.78 && !lite)
            {
                double flash = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * 0.9 + seed * 9.0);
                double aA = ClampD(flash, 0, 1);
                if (aA > 0.04)
                {
                    double rayLen = gemR * (1.5 + aA * 0.9);
                    double rot = reduced ? lightA : lightA + t * 0.05;
                    double rayA = (dark ? 0.42 : 0.24) * aA * alpha;
                    Rgba rayC = WhitePush(baseCol, 0.8, 0.8, 0.9, rayA);
                    for (int kk = 0; kk < 3; kk++)
                    {
                        double a = rot + kk / 3.0 * System.Math.PI;
                        double dx = System.Math.Cos(a) * rayLen, dy = System.Math.Sin(a) * rayLen;
                        rays[kk] = new LineSegment(x - dx, y - dy, x + dx, y + dy);
                    }
                    session.DrawLineBatch(rays, rayC, 0.8);
                }
            }
        }

        return true;
    }
}
