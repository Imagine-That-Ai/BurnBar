using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Flow;

/// <summary>
/// Glass Ribbon — C# port of Swift <c>Views/Substrate/Flow/GlassRibbonSubstrate.swift</c>
/// (itself a port of imaginethat <c>flow/glass-ribbon.ts</c>). The whole point cloud is
/// read as ONE streamline (the cached nearest-neighbour walk) and extruded into a twisted
/// liquid-glass ribbon: between consecutive ordered points a quad cross-section is laid
/// down whose half-width tracks a curl-noise wind and breathes on a slow pulse, filled
/// with a cross-band gradient (dark edge → bright body → dark edge) shaded by the facet
/// normal vs a fixed top-left light, trimmed by cyan/magenta dispersion rails and a crisp
/// dark edge, then raked by a sliding white specular streak.
/// </summary>
/// <remarks>
/// Body + rails + edges are source-over on both stages; the specular bloom is a true
/// additive Gaussian layer on dark with a crisp hot core on top. <c>reduced</c> → a poised
/// still frame (frozen twist, one fixed mid-band glint); <c>batteryThrottled</c> drops the
/// dispersion rails + the bloom. Constants match the Swift original line-for-line.
/// </remarks>
public sealed class GlassRibbonSubstrate : ISwarmSubstrate
{
    private readonly SubstrateStructure _structure = new();

    private double[] _mx = Array.Empty<double>();
    private double[] _my = Array.Empty<double>();
    private double[] _lx = Array.Empty<double>();
    private double[] _ly = Array.Empty<double>();
    private double[] _rx = Array.Empty<double>();
    private double[] _ry = Array.Empty<double>();
    private double[] _nrm = Array.Empty<double>();
    private bool[] _brk = Array.Empty<bool>();

    private readonly Vec2[] _quad = new Vec2[4];
    private readonly Vec2[] _seg = new Vec2[2];
    private readonly GradientStop[] _stops = new GradientStop[3];

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        double radius = frame.CloudRadius;
        if (count < 2 || radius <= 0) return false;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool battery = frame.BatteryThrottled;
        double t = frame.T;
        double sizePx = frame.SizePx;
        double cx = frame.Cx, cy = frame.Cy;

        SubstrateStructure.Structure s = _structure.Get(dots, 6);
        int[] order = s.Order;
        int nv = order.Length;
        if (nv < 2) return false;
        Grow(nv);

        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1);
        double reveal = 0.15 + 0.85 * form;

        double wMin = System.Math.Max(1.6, sizePx * 0.85);
        double wMax = System.Math.Max(wMin + 0.6, radius * 0.062);

        double tt = reduced ? 0.6 : t * 0.42;
        double specHead = reduced ? 0.5 : Frac(t * 0.075);
        double seamGap = radius * 0.42;
        double seamGap2 = seamGap * seamGap;

        // build rail vertices from the NN walk.
        for (int k = 0; k < nv; k++)
        {
            int i = order[k];
            double x = dots[i].X, y = dots[i].Y;
            _mx[k] = x; _my[k] = y;

            double ux = (x - cx) / radius;
            double uy = (y - cy) / radius;
            double wind = CurlAngle(ux * 2.4, uy * 2.4, tt);
            double wind2 = CurlAngle(ux * 2.4 + 0.3, uy * 2.4 + 0.3, tt);
            double turn = System.Math.Abs(System.Math.Atan2(System.Math.Sin(wind2 - wind), System.Math.Cos(wind2 - wind)));
            turn = ClampD(turn / 1.4, 0, 1);
            double breath = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * 0.9 + ux * 3 + uy * 2);
            double hw = (wMin + (wMax - wMin) * (1 - turn) * (0.7 + 0.3 * breath)) * reveal;

            double na = wind + System.Math.PI / 2;
            _nrm[k] = na;
            double cxn = System.Math.Cos(na) * hw;
            double cyn = System.Math.Sin(na) * hw;
            _lx[k] = x - cxn; _ly[k] = y - cyn;
            _rx[k] = x + cxn; _ry[k] = y + cyn;

            if (k < nv - 1)
            {
                int ni = order[k + 1];
                double dx = dots[ni].X - x, dy = dots[ni].Y - y;
                _brk[k] = dx * dx + dy * dy > seamGap2;
            }
            else
            {
                _brk[k] = true;
            }
        }

        double lightA = -System.Math.PI * 0.72;
        var bodyWhite = new Rgba(235.0 / 255, 242.0 / 255, 1.0);
        var cyanRail = new Rgba(90.0 / 255, 220.0 / 255, 1.0);
        var magentaRail = new Rgba(1.0, 120.0 / 255, 235.0 / 255);
        double fillAlpha = dark ? 0.92 : 0.96;
        double dispBase = dark ? 0.34 : 0.26;
        double edgeAlpha = dark ? 0.55 : 0.4;
        double dispTime = reduced ? 0.0 : t * 1.3;

        // PASS 1: faceted glass body + dispersion + dark edge (source-over).
        session.Blend = SubstrateBlend.Normal;
        for (int k = 0; k < nv - 1; k++)
        {
            if (_brk[k]) continue;
            double lx0 = _lx[k], ly0 = _ly[k], rx0 = _rx[k], ry0 = _ry[k];
            double lx1 = _lx[k + 1], ly1 = _ly[k + 1], rx1 = _rx[k + 1], ry1 = _ry[k + 1];

            Rgba col = dots[order[k]].Rgba;
            double shade = 0.5 + 0.5 * System.Math.Cos(_nrm[k] - lightA);
            var edge = new Rgba(col.R * 0.22, col.G * 0.24, col.B * 0.32 + 8.0 / 255);
            double bodyT = 0.32 + 0.45 * shade;
            Rgba body = new Rgba(col.R, col.G, col.B).Mix(bodyWhite, bodyT);

            _quad[0] = new Vec2(lx0, ly0);
            _quad[1] = new Vec2(rx0, ry0);
            _quad[2] = new Vec2(rx1, ry1);
            _quad[3] = new Vec2(lx1, ly1);
            _stops[0] = new GradientStop(0.0, edge.WithOpacity(fillAlpha));
            _stops[1] = new GradientStop(0.5, body.WithOpacity(fillAlpha));
            _stops[2] = new GradientStop(1.0, edge.WithOpacity(fillAlpha));
            session.FillPolygonGradient(_quad, _stops, lx0, ly0, rx0, ry0);

            if (!battery)
            {
                double disp = 0.5 + 0.5 * System.Math.Sin(_nrm[k] - lightA + dispTime);
                double da = dispBase * disp;
                _seg[0] = new Vec2(lx0, ly0); _seg[1] = new Vec2(lx1, ly1);
                session.StrokePolyline(_seg, cyanRail.WithOpacity(da), 1);
                _seg[0] = new Vec2(rx0, ry0); _seg[1] = new Vec2(rx1, ry1);
                session.StrokePolyline(_seg, magentaRail.WithOpacity(da), 1);
            }

            Rgba edgeStroke = edge.WithOpacity(edgeAlpha);
            _seg[0] = new Vec2(lx0, ly0); _seg[1] = new Vec2(lx1, ly1);
            session.StrokePolyline(_seg, edgeStroke, 1);
            _seg[0] = new Vec2(rx0, ry0); _seg[1] = new Vec2(rx1, ry1);
            session.StrokePolyline(_seg, edgeStroke, 1);
        }

        // PASS 2: sliding specular streak — additive Gaussian bloom + crisp core.
        double winK = System.Math.Max(2, (int)System.Math.Round(nv * 0.12));
        double headV = specHead * nv;
        double specAlphaBase = dark ? 0.85 : 0.5;
        Rgba bloomCol = new Rgba(1, 1, 1).Mix(cyanRail, 0.28);
        double bloomR = System.Math.Max(2.5, sizePx * 1.5);

        bool Streak(int k, out double ax, out double ay, out double bx, out double by, out double spec)
        {
            ax = ay = bx = by = spec = 0;
            double dd = k - headV;
            dd -= System.Math.Round(dd / nv) * nv;
            double along = System.Math.Abs(dd);
            if (along > winK) return false;
            double env = Smoothstep(winK, 0, along);
            double facing = System.Math.Cos(_nrm[k] - lightA);
            spec = env * (0.45 + 0.55 * ClampD(facing, 0, 1));
            if (spec <= 0.01) return false;
            const double off = 0.42;
            ax = _mx[k] + (_rx[k] - _mx[k]) * off;
            ay = _my[k] + (_ry[k] - _my[k]) * off;
            bx = _mx[k + 1] + (_rx[k + 1] - _mx[k + 1]) * off;
            by = _my[k + 1] + (_ry[k + 1] - _my[k + 1]) * off;
            return true;
        }

        // PASS 2a — Gaussian bloom halo (dark, non-throttled).
        if (dark && !battery)
        {
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int k = 0; k < nv - 1; k++)
                {
                    if (_brk[k]) continue;
                    if (!Streak(k, out double ax, out double ay, out double bx, out double by, out double spec)) continue;
                    double a = ClampD(0.55 * spec, 0, 1);
                    double lw = System.Math.Max(1.6, sizePx * 1.35 * (0.55 + spec));
                    _seg[0] = new Vec2(ax, ay); _seg[1] = new Vec2(bx, by);
                    session.StrokePolyline(_seg, bloomCol.WithOpacity(a), lw);
                }
            }
        }

        // PASS 2b — crisp hot core.
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        for (int k = 0; k < nv - 1; k++)
        {
            if (_brk[k]) continue;
            if (!Streak(k, out double ax, out double ay, out double bx, out double by, out double spec)) continue;
            double a = ClampD(specAlphaBase * spec, 0, 1);
            double lw = System.Math.Max(0.85, sizePx * 0.55 * (0.5 + spec));
            _seg[0] = new Vec2(ax, ay); _seg[1] = new Vec2(bx, by);
            session.StrokePolyline(_seg, Rgba.White.WithOpacity(a), lw);
        }

        return true;
    }

    private void Grow(int n)
    {
        if (_mx.Length >= n) return;
        _mx = new double[n];
        _my = new double[n];
        _lx = new double[n];
        _ly = new double[n];
        _rx = new double[n];
        _ry = new double[n];
        _nrm = new double[n];
        _brk = new bool[n];
    }

    // Cheap smooth deterministic 2-D value-noise (the curl-noise wind sampler),
    // ported verbatim from the Swift `vnoise` (h = frac(sin(a*127.1+b*311.7)*43758.5453)).
    private static double VNoise(double x, double y)
    {
        double xi = System.Math.Floor(x), yi = System.Math.Floor(y);
        double xf = x - xi, yf = y - yi;
        double u = xf * xf * (3 - 2 * xf);
        double v = yf * yf * (3 - 2 * yf);
        static double H(double a, double b)
        {
            double n = System.Math.Sin(a * 127.1 + b * 311.7) * 43758.5453;
            return n - System.Math.Floor(n);
        }
        double aa = H(xi, yi);
        double bb = H(xi + 1, yi);
        double cc = H(xi, yi + 1);
        double dd = H(xi + 1, yi + 1);
        return (aa + (bb - aa) * u) + ((cc - aa) + (aa - bb - cc + dd) * u) * v;
    }

    private static double CurlAngle(double x, double y, double tt)
    {
        const double e = 0.55;
        double nx = VNoise(x + e, y + tt) - VNoise(x - e, y + tt);
        double ny = VNoise(x, y + e + tt) - VNoise(x, y - e + tt);
        return System.Math.Atan2(nx, -ny);
    }
}
