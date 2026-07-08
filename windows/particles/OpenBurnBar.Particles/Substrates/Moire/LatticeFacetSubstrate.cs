using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Moire;

/// <summary>
/// Lattice Facet — faithful C# port of Swift
/// <c>Views/Substrate/Moire/LatticeFacetSubstrate.swift</c>. A breathing crystal
/// lattice: a GLOBAL triangular faceted tiling locked to a FIXED screen-px frequency
/// that fills the whole canvas, then MODULATED by the local particle field. A coarse
/// density grid lifts facet brightness/opacity where the swarm clusters and lets it
/// fall gently toward a dim crust where empty (never a hard rectangle), and carries
/// the swarm's average brand colour. A key light rotates one way while an offset
/// lattice phase drifts the other → a diagonal ribbon of lit facets marches across
/// the lattice (the faceted moiré).
/// </summary>
/// <remarks>
/// Passes: (0) one real Gaussian bloom layer (kills the "flat tiles" read);
/// (1) opaque-feathered faceted gem bodies (triangular <c>FillPolygon</c>)
/// with an inner lit top-facet on bright cells; (2) specular hot glints (a cached
/// white-glow sprite + a crisp triangle) riding the moiré ribbon near the swarm.
/// Lattice geometry is cached per layout; the hot loop is O(facets) with no
/// per-frame allocation. The exact constants ARE the look.
/// </remarks>
public sealed class LatticeFacetSubstrate : ISwarmSubstrate
{
    private struct Facet
    {
        public double Ax, Ay, Bx, By, Cx, Cy, Fx, Fy, CosN, SinN, Seed;
    }

    private Facet[] _facets = Array.Empty<Facet>();
    private double _builtW = -1, _builtH = -1, _builtCell = -1;

    // per-facet draw scratch (sized with the lattice; never allocates in the loop).
    private double[] _sBright = Array.Empty<double>();
    private double[] _sR = Array.Empty<double>();
    private double[] _sG = Array.Empty<double>();
    private double[] _sB = Array.Empty<double>();
    private double[] _sA = Array.Empty<double>();
    private double[] _sQ = Array.Empty<double>();
    private double[] _sSpec = Array.Empty<double>();

    // coarse particle-density grid.
    private int _gCols, _gRows;
    private double _gCell = 1.0;
    private double[] _gw = Array.Empty<double>();
    private double[] _gr = Array.Empty<double>();
    private double[] _gg = Array.Empty<double>();
    private double[] _gb = Array.Empty<double>();

    private void EnsureLattice(double width, double height, double cell)
    {
        if (System.Math.Abs(_builtW - width) < 0.5 && System.Math.Abs(_builtH - height) < 0.5
            && System.Math.Abs(_builtCell - cell) < 0.5 && _facets.Length > 0) return;
        _builtW = width; _builtH = height; _builtCell = cell;

        double colW = cell;
        double rowH = cell * 0.8660254;
        int nRows = (int)System.Math.Ceiling(height / rowH) + 2;
        int nCols = (int)System.Math.Ceiling(width / colW) + 2;

        var list = new System.Collections.Generic.List<Facet>((nRows + 2) * (nCols + 2) * 2);

        void Add(double ax, double ay, double bx, double by, double cx, double cy, bool up, int ri, int ci)
        {
            double fx = (ax + bx + cx) / 3.0;
            double fy = (ay + by + cy) / 3.0;
            double seed = Shash2(ci * 1.7 + (up ? 0.31 : 0.74), ri * 1.3 + 0.17);
            double baseAng = up ? -System.Math.PI / 2 : System.Math.PI / 2;
            double na = baseAng + (seed - 0.5) * 0.85;
            list.Add(new Facet
            {
                Ax = ax, Ay = ay, Bx = bx, By = by, Cx = cx, Cy = cy,
                Fx = fx, Fy = fy, CosN = System.Math.Cos(na), SinN = System.Math.Sin(na), Seed = seed,
            });
        }

        for (int ri = -1; ri < nRows; ri++)
        {
            double yT = ri * rowH;
            double yB = yT + rowH;
            double stagger = (ri & 1) == 0 ? 0.0 : colW * 0.5;
            for (int ci = -1; ci < nCols; ci++)
            {
                double x = stagger + ci * colW;
                Add(x, yB, x + colW, yB, x + colW * 0.5, yT, true, ri, ci);
                Add(x + colW * 0.5, yT, x + colW * 1.5, yT, x + colW, yB, false, ri, ci);
            }
        }

        _facets = list.ToArray();
        int n = _facets.Length;
        _sBright = new double[n]; _sR = new double[n]; _sG = new double[n];
        _sB = new double[n]; _sA = new double[n]; _sQ = new double[n]; _sSpec = new double[n];
    }

    private void EnsureGrid(int cols, int rows)
    {
        int want = cols * rows;
        if (_gCols == cols && _gRows == rows && _gw.Length == want) return;
        _gCols = cols; _gRows = rows;
        _gw = new double[want]; _gr = new double[want]; _gg = new double[want]; _gb = new double[want];
    }

    private (double, Rgba) SampleGrid(double x, double y, in Rgba fallback)
    {
        double fx = x / _gCell - 0.5, fy = y / _gCell - 0.5;
        int x0 = (int)System.Math.Floor(fx), y0 = (int)System.Math.Floor(fy);
        double tx = fx - x0, ty = fy - y0;
        int Idx(int ix, int iy)
        {
            int cx = System.Math.Min(System.Math.Max(ix, 0), _gCols - 1);
            int cy = System.Math.Min(System.Math.Max(iy, 0), _gRows - 1);
            return cy * _gCols + cx;
        }
        int i00 = Idx(x0, y0), i10 = Idx(x0 + 1, y0), i01 = Idx(x0, y0 + 1), i11 = Idx(x0 + 1, y0 + 1);
        double Bil(double[] a)
        {
            double top = a[i00] * (1 - tx) + a[i10] * tx;
            double bot = a[i01] * (1 - tx) + a[i11] * tx;
            return top * (1 - ty) + bot * ty;
        }
        double w = Bil(_gw);
        if (w > 1e-4) return (w, new Rgba(Bil(_gr) / w, Bil(_gg) / w, Bil(_gb) / w));
        return (w, fallback);
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        double width = frame.Width, height = frame.Height;
        if (count == 0 || width <= 1 || height <= 1) return false;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        Rgba accent = frame.Stage.Accent;
        Rgba ink = frame.Stage.Ink;
        double t = frame.T;

        double cell = ClampD(30 + sizePx * 4.0, 30, 52);
        EnsureLattice(width, height, cell);
        if (_facets.Length == 0) return true;

        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1);
        double reveal = 0.32 + 0.68 * form;

        int inN = 0;
        for (int i = 0; i < count; i++) if (frame.Dots[i].InShape) inN++;
        double inFrac = (double)inN / count;
        double shapeTight = ClampD(System.Math.Max(frame.IsShapeMode ? 0.7 : 0.0,
            inFrac * Smoothstep(0.4, 0.85, form)), 0, 1);

        double gridCellSize = ClampD(cell * 2.2, 52, 130);
        int cols = System.Math.Max(2, (int)System.Math.Ceiling(width / gridCellSize) + 1);
        int rows = System.Math.Max(2, (int)System.Math.Ceiling(height / gridCellSize) + 1);
        EnsureGrid(cols, rows);
        _gCell = gridCellSize;
        Array.Clear(_gw); Array.Clear(_gr); Array.Clear(_gg); Array.Clear(_gb);
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = frame.Dots[i];
            int gx = System.Math.Min(System.Math.Max((int)(d.X / gridCellSize), 0), cols - 1);
            int gy = System.Math.Min(System.Math.Max((int)(d.Y / gridCellSize), 0), rows - 1);
            int k = gy * cols + gx;
            double w = ClampD(d.Opacity, 0, 1) * 0.6 + 0.4;
            _gw[k] += w;
            Rgba c = d.Rgba;
            _gr[k] += c.R * w; _gg[k] += c.G * w; _gb[k] += c.B * w;
        }

        double lightA = reduced ? -0.6 : t * 0.18;
        double latPhase = reduced ? 1.0 : -t * 0.42;
        double lx = System.Math.Cos(lightA), ly = System.Math.Sin(lightA);
        double breath = reduced ? 1.0 : 1.0 + 0.05 * System.Math.Sin(t * 0.7);
        double hueDrift = reduced ? 0.0 : t * 0.05;

        double waveA = Tau / (cell * 6.5);
        double waveB = Tau / (cell * 5.6);

        double floorDim = (dark ? 0.085 : 0.11) * (1.0 - shapeTight);
        double densExp = Lerp(1.0, 2.4, shapeTight);

        // ── PASS A: compute every facet's state once ──
        int n = _facets.Length;
        for (int fi = 0; fi < n; fi++)
        {
            Facet f = _facets[fi];
            (double gW, Rgba brand) = SampleGrid(f.Fx, f.Fy, accent);
            double dens = 1.0 - System.Math.Exp(-gW * 0.30);
            double densG = System.Math.Pow(dens, densExp);

            double facing = f.CosN * lx + f.SinN * ly;
            double latA = (f.Fx * 0.86 + f.Fy * 0.32) * waveA;
            double latB = (f.Fx * 0.24 + f.Fy * 0.94) * waveB;
            double band = 0.5 + 0.5 * System.Math.Sin(latA + latPhase) * System.Math.Sin(latB - latPhase);
            double lit = ClampD(0.5 + 0.5 * facing, 0, 1) * (0.45 + 0.55 * band);

            double glow = (floorDim + (1 - floorDim) * densG) * breath;
            double bright = ClampD((0.30 + 0.70 * lit) * glow * reveal, 0, 1.2);
            double q = System.Math.Min(3.0, System.Math.Floor(ClampD(bright, 0, 1) * 4.0)) / 3.0;

            Rgba jewel = SampleRamp(Iris, band * 0.6 + f.Seed * 0.5 + hueDrift);
            Rgba facetCol = jewel.Mix(brand, ClampD(densG * 0.8, 0, 0.8));

            Rgba body = dark
                ? facetCol.ToWhite(0.05 + 0.45 * q)
                : facetCol.Mix(ink, 0.18 * (1 - q)).ToWhite(0.04 + 0.20 * q);
            double aBody = dark
                ? ClampD(0.05 + 0.92 * bright, 0, 0.95)
                : ClampD(0.04 + 0.62 * bright, 0, 0.82);

            double spec = facing > 0.25 ? ClampD((facing - 0.25) / 0.75, 0, 1) * band * densG : 0;

            _sBright[fi] = bright;
            _sR[fi] = body.R; _sG[fi] = body.G; _sB[fi] = body.B;
            _sA[fi] = aBody; _sQ[fi] = q; _sSpec[fi] = spec;
        }

        // ── PASS 0: REAL Gaussian under-bloom for the whole field ──
        if (!throttled)
        {
            double bloomR = System.Math.Max(3.0, cell * 0.55);
            double rg = cell * 0.95;
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
            using (session.PushBlurLayer(bloomR, dark ? SubstrateBlend.Add : SubstrateBlend.Normal))
            {
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                for (int fi = 0; fi < n; fi++)
                {
                    double bright = _sBright[fi];
                    if (bright <= 0.08) continue;
                    Facet f = _facets[fi];
                    Rgba glowCol = new Rgba(_sR[fi], _sG[fi], _sB[fi]).ToWhite(0.12 + 0.4 * _sQ[fi]);
                    double a = dark
                        ? ClampD(0.10 + 0.70 * bright, 0, 0.85)
                        : ClampD(0.05 + 0.18 * bright, 0, 0.32);
                    session.FillCircle(f.Fx, f.Fy, rg, glowCol.WithOpacity(a));
                }
            }
        }

        // ── PASS 1: faceted gem bodies — the continuous cut crystal ──
        session.Blend = SubstrateBlend.Normal;
        Span<PointD> tri = stackalloc PointD[3];
        for (int fi = 0; fi < n; fi++)
        {
            double a = _sA[fi];
            if (a <= 0.02) continue;
            Facet f = _facets[fi];
            tri[0] = new PointD(f.Ax, f.Ay);
            tri[1] = new PointD(f.Bx, f.By);
            tri[2] = new PointD(f.Cx, f.Cy);
            session.FillPolygon(tri, new Rgba(_sR[fi], _sG[fi], _sB[fi]).WithOpacity(a));

            if (!throttled && _sBright[fi] > 0.52)
            {
                double q = _sQ[fi];
                Rgba top = new Rgba(_sR[fi], _sG[fi], _sB[fi]).ToWhite(0.30 + 0.45 * q);
                const double s = 0.46;
                tri[0] = new PointD(f.Fx + (f.Ax - f.Fx) * s, f.Fy + (f.Ay - f.Fy) * s);
                tri[1] = new PointD(f.Fx + (f.Bx - f.Fx) * s, f.Fy + (f.By - f.Fy) * s);
                tri[2] = new PointD(f.Fx + (f.Cx - f.Fx) * s, f.Fy + (f.Cy - f.Fy) * s);
                session.FillPolygon(tri, top.WithOpacity(ClampD(a * 0.85, 0, 0.9)));
            }
        }

        // ── PASS 2: specular hot glints riding the moiré ribbon (near the swarm) ──
        if (!throttled)
        {
            session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
            Rgba specColor = dark ? Rgba.White : new Rgba(252.0 / 255, 253.0 / 255, 1.0);
            double sr = cell * 0.30;
            for (int fi = 0; fi < n; fi++)
            {
                double spec = _sSpec[fi];
                if (spec <= 0.06) continue;
                Facet f = _facets[fi];
                double ex = f.Fx + f.CosN * cell * 0.18;
                double ey = f.Fy + f.SinN * cell * 0.18;

                if (dark)
                {
                    double gr = cell * (0.32 + 0.5 * spec);
                    session.DrawGlowSprite(ex, ey, gr, Rgba.White, ClampD(0.28 + 0.5 * spec, 0, 0.9));
                }

                double perpX = -f.SinN, perpY = f.CosN;
                tri[0] = new PointD(ex + f.CosN * sr * 0.6, ey + f.SinN * sr * 0.6);
                tri[1] = new PointD(ex + perpX * sr * 0.42 - f.CosN * sr * 0.28, ey + perpY * sr * 0.42 - f.SinN * sr * 0.28);
                tri[2] = new PointD(ex - perpX * sr * 0.42 - f.CosN * sr * 0.28, ey - perpY * sr * 0.42 - f.SinN * sr * 0.28);
                double alpha = ClampD((dark ? 0.66 : 0.42) * spec, 0, 0.9);
                session.FillPolygon(tri, specColor.WithOpacity(alpha));
            }
        }

        return true;
    }
}
