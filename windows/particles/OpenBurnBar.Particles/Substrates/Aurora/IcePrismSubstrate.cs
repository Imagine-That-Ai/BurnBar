using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Aurora;

/// <summary>
/// Polar Ice Prism — C# port of Swift <c>Views/Substrate/Aurora/IcePrismSubstrate.swift</c>
/// (itself a port of imaginethat <c>aurora/ice-prism.ts</c>). Each silhouette point
/// becomes one oversized, irregular 4-vertex shard of glacial ice — the facets overlap
/// into a single continuous, hard-edged mass (the only solid, cut-gemstone member of the
/// aurora family). A shared aurora light vector orbits ~12s; each facet's glint is the
/// alignment of its fixed normal with that vector, so a teal→violet glint band migrates
/// diagonally across the whole logo.
/// </summary>
/// <remarks>
/// Per facet, painter-sorted back→front: a faint icy backlit bloom (dark), a true
/// Gaussian bloom of the lit band, the relit solid facet fill (source-over both stages),
/// a shadow wedge, a white specular wedge + cyan/violet micro-glints on the brightest,
/// and a prismatic frost rim. Micro-rotation ±~3° lets edges catch and release.
/// <c>reduced</c> → a poised still ice mass with one frozen diagonal glint band;
/// <c>batteryThrottled</c> drops the sort, the two bloom passes, the shadow wedges, the
/// micro-glints, and the rim. Exact alpha/relight constants ARE the look.
/// </remarks>
public sealed class IcePrismSubstrate : ISwarmSubstrate
{
    private const int Verts = 4;
    private static readonly Rgba RimCold = new(176.0 / 255, 226.0 / 255, 240.0 / 255);
    private static readonly (double r, double g, double b) BackBlue = (70.0 / 255, 120.0 / 255, 168.0 / 255);
    private static readonly (double r, double g, double b) IceWhite = (235.0 / 255, 245.0 / 255, 255.0 / 255);
    private static readonly Rgba PrismCyan = new(150.0 / 255, 232.0 / 255, 255.0 / 255);
    private static readonly Rgba PrismViolet = new(176.0 / 255, 158.0 / 255, 255.0 / 255);
    private const double CoverScale = 1.16;

    // The icy underglow tint (Swift 64px icy sprite dominant stop).
    private static readonly Rgba Icy = new(158.0 / 255, 214.0 / 255, 245.0 / 255);

    private int _n = -1;
    private double[] _vcos = Array.Empty<double>();
    private double[] _vsin = Array.Empty<double>();
    private double[] _vrad = Array.Empty<double>();
    private double[] _fsize = Array.Empty<double>();
    private double[] _fnorm = Array.Empty<double>();
    private double[] _fphase = Array.Empty<double>();
    private int[] _order = Array.Empty<int>();
    private double[] _glintS = Array.Empty<double>();
    private double[] _litS = Array.Empty<double>();

    private readonly Vec2[] _facet = new Vec2[Verts];
    private readonly Vec2[] _wedge = new Vec2[Verts];

    private void BuildGeometry(int count)
    {
        _n = count;
        _vcos = new double[count * Verts];
        _vsin = new double[count * Verts];
        _vrad = new double[count * Verts];
        _fsize = new double[count];
        _fnorm = new double[count];
        _fphase = new double[count];
        _order = new int[count];
        for (int i = 0; i < count; i++)
        {
            double fi = i;
            double s0 = Shash(fi * 2.17 + 0.31);
            double s1 = Shash(fi * 3.91 + 1.77);
            double bas = s0 * Tau;
            for (int v = 0; v < Verts; v++)
            {
                double jit = (Shash(fi * 7.3 + v * 11.9 + 4.1) - 0.5) * 0.7;
                double a = bas + (double)v / Verts * Tau + jit;
                double r = 0.78 + Shash(fi * 5.5 + v * 2.3 + 0.9) * 0.46;
                int kk = i * Verts + v;
                _vcos[kk] = System.Math.Cos(a);
                _vsin[kk] = System.Math.Sin(a);
                _vrad[kk] = r;
            }
            _fsize[i] = 2.0 + s1 * 1.3;
            _fnorm[i] = s0 * Tau;
            _fphase[i] = s1 * Tau;
            _order[i] = i;
        }
        _glintS = new double[count];
        _litS = new double[count];
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;
        if (_n != count) BuildGeometry(count);

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        double f = ClampD(frame.SettleProgress, 0, 1) * 0.7 + 0.3;

        // Painter's depth sort back→front by screen y (index tie-break → deterministic).
        if (!lite)
            Array.Sort(_order, (a, b) => dots[a].Y != dots[b].Y ? dots[a].Y.CompareTo(dots[b].Y) : a.CompareTo(b));

        double lt = reduced ? 0.7 : t * (Tau / 12);
        double warp = reduced ? 0 : 0.5 * System.Math.Sin(t * 0.21 + 1.3);
        double lightAng = lt + warp;
        double lcos = System.Math.Cos(lightAng);
        double lsin = System.Math.Sin(lightAng);

        Rgba glowCyan = frame.Stage.Accent;
        Rgba glowViolet = frame.Stage.Accent2;

        for (int i = 0; i < count; i++)
        {
            double fn = _fnorm[i];
            double g = 0.5 + 0.5 * (System.Math.Cos(fn) * lcos + System.Math.Sin(fn) * lsin);
            _glintS[i] = g;
            _litS[i] = g * g;
        }

        // PASS A — presence underglow.
        if (dark && !lite)
        {
            session.Blend = SubstrateBlend.Add;
            foreach (int i in _order)
            {
                double r = sizePx * _fsize[i] * CoverScale * 1.55;
                SwarmSubstrateDot d = dots[i];
                session.DrawGlowSprite(d.X, d.Y, r, Icy, ClampD((0.09 + 0.20 * _litS[i]) * f, 0, 0.5));
            }
        }

        // PASS B — true Gaussian bloom of the lit band.
        if (dark && !lite)
        {
            double bloomR = System.Math.Max(2.0, sizePx * 2.3);
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                foreach (int i in _order)
                {
                    double lit = _litS[i];
                    if (lit < 0.20) continue;
                    SwarmSubstrateDot d = dots[i];
                    double sz = sizePx * _fsize[i] * CoverScale;
                    Rgba core = d.Rgba.ToWhite(0.40 + 0.50 * lit);
                    double a = ClampD((0.22 + 0.55 * lit) * f, 0, 0.95);
                    double cr = sz * 0.62;
                    session.FillCircle(d.X, d.Y, cr, core.WithOpacity(a));
                }
            }
        }

        // PASS C — faceted shards + cut-gem depth and glints.
        double specCap = dark ? 0.95 : 0.72;
        double bodyAlpha = ClampD((dark ? 0.92 : 0.97) * f, 0, 1);
        SubstrateBlend specBlend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        foreach (int i in _order)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;

            double rot = reduced ? 0 : 0.052 * System.Math.Sin(t * 0.4 + _fphase[i]);
            double rc2 = System.Math.Cos(rot), rs = System.Math.Sin(rot);
            double sz = sizePx * _fsize[i] * CoverScale;

            double glint = _glintS[i];
            double facing = glint;
            double lit = _litS[i];
            double back = 1 - facing;

            Rgba baseC = d.Rgba;
            double rr = baseC.R + (IceWhite.r - baseC.R) * (0.20 + 0.64 * lit);
            double gg = baseC.G + (IceWhite.g - baseC.G) * (0.20 + 0.64 * lit);
            double bb = baseC.B + (IceWhite.b - baseC.B) * (0.18 + 0.55 * lit);
            rr += (BackBlue.r - rr) * back * 0.42;
            gg += (BackBlue.g - gg) * back * 0.42;
            bb += (BackBlue.b - bb) * back * 0.42;
            var fill = new Rgba(ClampD(rr, 0, 1), ClampD(gg, 0, 1), ClampD(bb, 0, 1), bodyAlpha);

            int o = i * Verts;
            for (int v = 0; v < Verts; v++)
            {
                int kk = o + v;
                double vr = _vrad[kk] * sz;
                double lx = _vcos[kk] * vr, ly = _vsin[kk] * vr;
                _facet[v] = new Vec2(x + lx * rc2 - ly * rs, y + lx * rs + ly * rc2);
            }
            session.Blend = SubstrateBlend.Normal;
            session.FillPolygon(_facet, fill);

            // lit corner (most aligned with light) and shadowed corner.
            int bestV = 0;
            double bestD = -2.0;
            for (int v = 0; v < Verts; v++)
            {
                int kk = o + v;
                double dd = _vcos[kk] * lcos + _vsin[kk] * lsin;
                if (dd > bestD) { bestD = dd; bestV = v; }
            }

            Vec2 Corner(int kk, double scale)
            {
                double vr = _vrad[kk] * sz * scale;
                double lx = _vcos[kk] * vr, ly = _vsin[kk] * vr;
                return new Vec2(x + lx * rc2 - ly * rs, y + lx * rs + ly * rc2);
            }

            // SHADOW WEDGE.
            if (!lite && back > 0.30)
            {
                int shV = (bestV + 2) % Verts;
                _wedge[0] = Corner(o + shV, 1);
                _wedge[1] = Corner(o + (shV + Verts - 1) % Verts, 0.50);
                _wedge[2] = new Vec2(x, y);
                _wedge[3] = Corner(o + (shV + 1) % Verts, 0.50);
                double shA = ClampD((0.16 + 0.20 * (back - 0.30)) * f, 0, 0.4);
                session.Blend = SubstrateBlend.Normal;
                session.FillPolygon(_wedge, new Rgba(BackBlue.r, BackBlue.g, BackBlue.b, shA));
            }

            // SPECULAR WEDGE.
            double spec = ClampD((glint - 0.50) / 0.50, 0, 1);
            if (spec > 0.02)
            {
                Vec2 c0 = Corner(o + bestV, 1);
                _wedge[0] = c0;
                _wedge[1] = Corner(o + (bestV + Verts - 1) % Verts, 0.46);
                _wedge[2] = new Vec2(x, y);
                _wedge[3] = Corner(o + (bestV + 1) % Verts, 0.46);
                double sa = ClampD((dark ? 0.58 : 0.40) * spec * f, 0, specCap);
                session.Blend = specBlend;
                session.FillPolygon(_wedge, Rgba.White.WithOpacity(sa));

                if (dark && spec > 0.40)
                {
                    double sparkA = ClampD((spec - 0.40) / 0.60 * f, 0, 1);
                    double pr = System.Math.Max(0.6, sz * 0.16);
                    session.Blend = SubstrateBlend.Add;
                    session.FillCircle(c0.X, c0.Y, pr, Rgba.White.WithOpacity(0.85 * sparkA));
                    if (!lite)
                    {
                        double off = sz * 0.22;
                        double dr = pr * 0.8;
                        session.FillCircle(c0.X - off, c0.Y, dr, glowCyan.WithOpacity(0.55 * sparkA));
                        session.FillCircle(c0.X + off, c0.Y, dr, glowViolet.WithOpacity(0.55 * sparkA));
                    }
                }
            }

            // PRISMATIC FROST RIM.
            if (!lite)
            {
                Rgba rim = RimCold.Mix(PrismCyan, 0.55 * lit).Mix(PrismViolet, 0.45 * back);
                double rimA = ClampD((dark ? 0.34 : 0.42) + 0.46 * lit, 0, 0.96) * f;
                session.Blend = SubstrateBlend.Normal;
                session.StrokePolyline(_facet, rim.WithOpacity(rimA), dark ? 1.0 : 1.1, closed: true);
            }
        }

        return true;
    }
}
