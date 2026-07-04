using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Mesh;

/// <summary>
/// Iso Contour — faithful C# port of Swift
/// <c>Views/Substrate/Mesh/MeshIsolineSubstrate.swift</c>. The mark drawn as a
/// topographic contour map. The cloud points are splatted (Gaussian) into a 60×60
/// density grid ONCE per layout — a smooth scalar that peaks at the dense core and
/// falls to zero outside the silhouette. Each frame a cheap organic fbm time-wobble
/// is composited, then 8 iso-levels are marched: 7 inner contours whose level window
/// drifts together (a living topo), plus one geometrically LOCKED index boundary
/// contour drawn brightest/thickest. Each level is one batched
/// <see cref="ISubstrateDrawingSession.DrawLineBatch"/>. A footprint coverage mask
/// gates the march so contours exist ONLY inside the point cloud and dissolve softly
/// at its edge (dismantling the bounding-rectangle read).
/// </summary>
/// <remarks>
/// DARK → additive glowing filaments (the index gets wide low-alpha underglow restrokes
/// then a near-white core); LIGHT → thin opaque source-over ink. <c>reduced</c> parks
/// the drift; <c>batteryThrottled</c> drops the underglow restrokes. Pure stroke
/// material. Owns the whole silhouette → suppresses the glyph pass. The exact
/// constants ARE the look.
/// </remarks>
public sealed class MeshIsolineSubstrate : ISwarmSubstrate
{
    private const int Grid = 60;
    private const int Cells = Grid * Grid;
    private const int Pad = 6;
    private const int InnerLevels = 7;
    private const double BoundaryLevel = 0.18;
    private const double SpanMul = 3.2;
    private const double CovSkip = 0.07;
    private const double CovFull = 0.40;

    private readonly double[] _field = new double[Cells];
    private readonly double[] _warp = new double[Cells];
    private readonly double[] _scratch = new double[Cells];
    private readonly double[] _coverage = new double[Cells];
    private double _sig = double.NaN;
    private bool _builtDark;
    private double _gx0, _gy0, _gw = 1.0, _gh = 1.0;
    private Rgba _rampLo = new(0.47, 0.71, 1.0);
    private Rgba _rampMid = new(0.59, 0.92, 1.0);
    private Rgba _rampHi = new(0.88, 0.98, 1.0);

    public bool SuppressesGlyphs => true;

    private readonly struct Iso
    {
        public readonly List<LineSegment> Full;
        public readonly List<LineSegment> Feather;
        public readonly Rgba Body;
        public readonly Rgba Glow;
        public readonly double Lw;
        public Iso(List<LineSegment> full, List<LineSegment> feather, in Rgba body, in Rgba glow, double lw)
        {
            Full = full; Feather = feather; Body = body; Glow = glow; Lw = lw;
        }
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        double radius = frame.CloudRadius;
        if (count == 0 || radius <= 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;
        double cx = frame.Cx, cy = frame.Cy;
        Rgba accent = frame.Stage.Accent;
        Rgba accent2 = frame.Stage.Accent2;
        Rgba white = Rgba.White;

        SwarmSubstrateDot s0 = frame.Dots[0];
        double newSig = count * 131.0
            + System.Math.Round(s0.X) * 0.13
            + System.Math.Round(s0.Y) * 0.071
            + System.Math.Round(radius) * 1.7
            + System.Math.Round(cx) * 0.011
            + System.Math.Round(cy) * 0.017;
        if (newSig != _sig || dark != _builtDark)
        {
            _sig = newSig;
            Rebuild(frame);
        }
        if (double.IsNaN(_sig)) return true;

        Composite(t, reduced);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        double x0 = _gx0 - Pad * _gw;
        double y0 = _gy0 - Pad * _gh;

        double baseW = ClampD(radius * 0.006, 0.6, 1.5);

        double loBand = BoundaryLevel + 0.08;
        double hiBand = 0.92;
        double band = hiBand - loBand;
        double drift = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * (Tau * 0.06));
        double spacing = band / InnerLevels;
        double aGlow = dark ? 0.84 : 0.88;

        Rgba coreTint = white.Mix(accent, 0.20);
        const double featherA = 0.45;

        var isos = new List<Iso>(InnerLevels);
        for (int nn = 0; nn < InnerLevels; nn++)
        {
            double level = loBand + (nn + drift) * spacing;
            if (level >= hiBand) level -= band;
            double u = ClampD((level - loBand) / band, 0, 1);
            Rgba irisStop = SampleRamp(Iris, 0.06 + u * 0.42);
            Rgba ramp = RampAt(u).Mix(irisStop, 0.24);
            Rgba body = ramp.Mix(coreTint, u * u * 0.42);
            Rgba glow = ramp.Mix(accent2, (1 - u) * 0.34);
            double lw = baseW * Lerp(1.55, 0.85, u);
            double edgeFade = System.Math.Min(1, (1 - System.Math.Abs(u - 0.5) * 2) * 3 + 0.18);
            double a = ClampD(aGlow * edgeFade, 0, 1);
            if (a <= 0.001) continue;
            (List<LineSegment> full, List<LineSegment> feather) = March(level, x0, y0);
            isos.Add(new Iso(full, feather, body.WithOpacity(a), glow.WithOpacity(a), lw));
        }

        double shimmer = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * 0.7);
        Rgba idxCol = RampAt(Lerp(0.4, 1.0, shimmer)).Mix(SampleRamp(Iris, 0.1), 0.22);
        (List<LineSegment> idxFull, List<LineSegment> idxFeather) = March(BoundaryLevel, x0, y0);

        if (dark)
        {
            // PASS 1 · TRUE GAUSSIAN BLOOM (dropped on battery).
            if (!lite)
            {
                double bloomR = ClampD(radius * 0.035, 7, 18);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    foreach (Iso iso in isos)
                    {
                        session.DrawLineBatch(Span(iso.Full), iso.Glow, iso.Lw * 2.6);
                        session.DrawLineBatch(Span(iso.Feather), iso.Glow.WithOpacity(iso.Glow.A * featherA), iso.Lw * 2.0);
                    }
                    Rgba idxGlow = idxCol.Mix(accent2, 0.30);
                    session.DrawLineBatch(Span(idxFull), idxGlow.WithOpacity(0.8), baseW * 4.4);
                    session.DrawLineBatch(Span(idxFeather), idxGlow.WithOpacity(0.42), baseW * 3.2);
                }
                session.Blend = SubstrateBlend.Add;
            }

            // PASS 2 · SATURATED BODY.
            foreach (Iso iso in isos)
            {
                session.DrawLineBatch(Span(iso.Full), iso.Body, iso.Lw);
                session.DrawLineBatch(Span(iso.Feather), iso.Body.WithOpacity(iso.Body.A * featherA), iso.Lw * 0.82);
            }

            // PASS 3 · INDEX boundary: soft underglow → iris body → core.
            session.DrawLineBatch(Span(idxFull), idxCol.WithOpacity(0.24), baseW * 4.0);
            session.DrawLineBatch(Span(idxFull), idxCol.WithOpacity(0.42), baseW * 2.4);
            Rgba core = idxCol.Mix(coreTint, 0.6);
            session.DrawLineBatch(Span(idxFull), core, baseW * 1.6);
            session.DrawLineBatch(Span(idxFeather), core.WithOpacity(0.5), baseW * 1.2);
        }
        else
        {
            foreach (Iso iso in isos)
            {
                session.DrawLineBatch(Span(iso.Full), iso.Body, iso.Lw * 1.15);
                session.DrawLineBatch(Span(iso.Feather), iso.Body.WithOpacity(iso.Body.A * featherA), iso.Lw * 0.95);
            }
            session.DrawLineBatch(Span(idxFull), idxCol.WithOpacity(0.30), baseW * 3.0);
            session.DrawLineBatch(Span(idxFull), idxCol.WithOpacity(0.92), baseW * 2.0);
            session.DrawLineBatch(Span(idxFeather), idxCol.WithOpacity(0.45), baseW * 1.5);
        }

        return true;
    }

    private void Rebuild(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        double radius = frame.CloudRadius;
        Array.Clear(_field);
        Array.Clear(_coverage);
        if (count == 0 || radius <= 0) { _sig = double.NaN; return; }

        double span = radius * SpanMul;
        double half = span / 2;
        _gx0 = frame.Cx - half;
        _gy0 = frame.Cy - half;
        double usable = Grid - 2 * Pad;
        _gw = span / usable;
        _gh = span / usable;
        double inv = usable / span;

        const double sigmaCells = 1.6;
        double sig2 = 2 * sigmaCells * sigmaCells;
        int rad = (int)System.Math.Ceiling(sigmaCells * 2.4);
        for (int p = 0; p < count; p++)
        {
            double gxf = (dots[p].X - _gx0) * inv + Pad;
            double gyf = (dots[p].Y - _gy0) * inv + Pad;
            int cgx = (int)System.Math.Round(gxf), cgy = (int)System.Math.Round(gyf);
            int x0 = System.Math.Max(0, cgx - rad), x1 = System.Math.Min(Grid - 1, cgx + rad);
            int y0 = System.Math.Max(0, cgy - rad), y1 = System.Math.Min(Grid - 1, cgy + rad);
            if (x0 > x1 || y0 > y1) continue;
            for (int gy = y0; gy <= y1; gy++)
            {
                double dy = gy - gyf;
                int rowBase = gy * Grid;
                for (int gx = x0; gx <= x1; gx++)
                {
                    double dx = gx - gxf;
                    _field[rowBase + gx] += System.Math.Exp(-(dx * dx + dy * dy) / sig2);
                }
            }
        }

        double peak = 0.0;
        for (int i = 0; i < Cells; i++) if (_field[i] > peak) peak = _field[i];
        if (peak <= 1e-6) { _sig = double.NaN; return; }
        double invPeak = 1 / peak;

        for (int gy = 0; gy < Grid; gy++)
        {
            int myEdge = System.Math.Min(gy, Grid - 1 - gy);
            for (int gx = 0; gx < Grid; gx++)
            {
                int i = gy * Grid + gx;
                double rn = _field[i] * invPeak;
                double cov = Smoothstep(0.03, 0.5, rn);
                double m = System.Math.Min(myEdge, System.Math.Min(gx, Grid - 1 - gx));
                double rim = Smoothstep(0.0, Pad, m);
                cov *= rim * rim;
                _coverage[i] = cov;
            }
        }

        for (int i = 0; i < Cells; i++)
            _field[i] = System.Math.Pow(ClampD(_field[i] * invPeak, 0, 1), 0.78);

        for (int gy = 0; gy < Grid; gy++)
            for (int gx = 0; gx < Grid; gx++)
                _warp[gy * Grid + gx] = VNoise(gx * 0.21, gy * 0.21) + 0.5 * VNoise(gx * 0.47 + 9, gy * 0.47 - 4);

        BuildRamp(dots, frame.Dark);
        _builtDark = frame.Dark;
    }

    private void BuildRamp(SwarmSubstrateDot[] dots, bool dark)
    {
        int count = dots.Length;
        Rgba a = dots[0].Rgba;
        Rgba b = dots[count / 2].Rgba;
        Rgba c = dots[count - 1].Rgba;
        double bR = (a.R + b.R + c.R) / 3;
        double bG = (a.G + b.G + c.G) / 3;
        double bB = (a.B + b.B + c.B) / 3;
        if (dark)
        {
            _rampLo = new Rgba(bR * 0.55, bG * 0.62, System.Math.Min(1, bB * 0.7 + 40.0 / 255.0));
            _rampMid = new Rgba(bR * 0.78 + 24.0 / 255.0, bG * 0.92 + 30.0 / 255.0, System.Math.Min(1, bB * 0.95 + 60.0 / 255.0));
            _rampHi = new Rgba(System.Math.Min(1, bR * 0.7 + 150.0 / 255.0), System.Math.Min(1, bG * 0.85 + 150.0 / 255.0), 1.0);
        }
        else
        {
            _rampLo = new Rgba(bR * 0.34, bG * 0.32, bB * 0.4 + 12.0 / 255.0);
            _rampMid = new Rgba(bR * 0.42, bG * 0.44, bB * 0.5 + 18.0 / 255.0);
            _rampHi = new Rgba(bR * 0.5, bG * 0.56, bB * 0.62 + 24.0 / 255.0);
        }
    }

    private Rgba RampAt(double u)
    {
        if (u < 0.5) return _rampLo.Mix(_rampMid, u * 2);
        return _rampMid.Mix(_rampHi, (u - 0.5) * 2);
    }

    private void Composite(double t, bool reduced)
    {
        double wobAmp = reduced ? 0.0 : 0.045;
        double wt = t * 0.9;
        if (wobAmp <= 0)
        {
            Array.Copy(_field, _scratch, Cells);
            return;
        }
        for (int i = 0; i < Cells; i++)
        {
            double v = _field[i];
            _scratch[i] = v + wobAmp * System.Math.Sin(wt + _warp[i] * Tau) * v;
        }
    }

    private (List<LineSegment> full, List<LineSegment> feather) March(double level, double x0, double y0)
    {
        var full = new List<LineSegment>();
        var feather = new List<LineSegment>();
        double[] fld = _scratch;
        double[] cov = _coverage;
        double gw = _gw, gh = _gh;
        double Ix(double a, double b)
        {
            double d = b - a;
            return (level - a) / (d == 0 ? 1e-6 : d);
        }
        for (int gy = 0; gy < Grid - 1; gy++)
        {
            int rowA = gy * Grid;
            int rowB = rowA + Grid;
            double cyT = y0 + gy * gh;
            double cyB = cyT + gh;
            for (int gx = 0; gx < Grid - 1; gx++)
            {
                double tl = fld[rowA + gx];
                double tr = fld[rowA + gx + 1];
                double br = fld[rowB + gx + 1];
                double bl = fld[rowB + gx];
                int code = 0;
                if (tl > level) code |= 8;
                if (tr > level) code |= 4;
                if (br > level) code |= 2;
                if (bl > level) code |= 1;
                if (code == 0 || code == 15) continue;
                double c = (cov[rowA + gx] + cov[rowA + gx + 1] + cov[rowB + gx + 1] + cov[rowB + gx]) * 0.25;
                if (c < CovSkip) continue;
                bool toFull = c >= CovFull;
                double cxL = x0 + gx * gw;
                double cxR = cxL + gw;
                double tX = cxL + gw * Ix(tl, tr);
                double rY = cyT + gh * Ix(tr, br);
                double bX = cxL + gw * Ix(bl, br);
                double lY = cyT + gh * Ix(tl, bl);
                List<LineSegment> p = toFull ? full : feather;
                switch (code)
                {
                    case 1: case 14: p.Add(new LineSegment(cxL, lY, bX, cyB)); break;
                    case 2: case 13: p.Add(new LineSegment(bX, cyB, cxR, rY)); break;
                    case 3: case 12: p.Add(new LineSegment(cxL, lY, cxR, rY)); break;
                    case 4: case 11: p.Add(new LineSegment(tX, cyT, cxR, rY)); break;
                    case 5:
                        p.Add(new LineSegment(cxL, lY, tX, cyT));
                        p.Add(new LineSegment(bX, cyB, cxR, rY));
                        break;
                    case 6: case 9: p.Add(new LineSegment(tX, cyT, bX, cyB)); break;
                    case 7: case 8: p.Add(new LineSegment(cxL, lY, tX, cyT)); break;
                    case 10:
                        p.Add(new LineSegment(tX, cyT, cxR, rY));
                        p.Add(new LineSegment(cxL, lY, bX, cyB));
                        break;
                }
            }
        }
        return (full, feather);
    }

    private static double VHash(int ix, int iy)
    {
        uint h = unchecked((uint)(ix * 374_761_393 + iy * 668_265_263));
        h = unchecked((h ^ (h >> 13)) * 1_274_126_177);
        h ^= h >> 16;
        return (h % 100_000) / 100_000.0;
    }

    private static double VNoise(double x, double y)
    {
        int ix = (int)System.Math.Floor(x), iy = (int)System.Math.Floor(y);
        double fx = x - ix, fy = y - iy;
        double ux = fx * fx * (3 - 2 * fx);
        double uy = fy * fy * (3 - 2 * fy);
        double a = VHash(ix, iy);
        double b = VHash(ix + 1, iy);
        double c = VHash(ix, iy + 1);
        double d = VHash(ix + 1, iy + 1);
        return Lerp(Lerp(a, b, ux), Lerp(c, d, ux), uy);
    }

    private static ReadOnlySpan<LineSegment> Span(List<LineSegment> l)
        => System.Runtime.InteropServices.CollectionsMarshal.AsSpan(l);
}
