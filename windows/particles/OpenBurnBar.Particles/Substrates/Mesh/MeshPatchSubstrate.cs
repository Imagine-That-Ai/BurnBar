using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Mesh;

/// <summary>
/// Gradient Patch — faithful C# port of Swift
/// <c>Views/Substrate/Mesh/MeshPatchSubstrate.swift</c>. A CONTINUOUS iridescent-mesh
/// tessellation: an edge-to-edge sheet of glossy stained-glass panes that covers the
/// cloud bounding box, brightens where the swarm clusters and dissolves softly where
/// it thins. A per-cell DENSITY field splatted from the particles (Gaussian kernel)
/// modulates each pane (empty → fades; dense → saturated), each cell's hue is an
/// inverse-distance blend of the nearby particle hues, a slow 2-octave height field
/// lifts/tilts the panes (draped breathing cloth), each pane catches a specular
/// hotspot + an iridescent thin-film seam, and one pooled Gaussian bloom glows under
/// the lit panes.
/// </summary>
/// <remarks>
/// Each pane is a rotated rounded-rect lozenge filled with a 3-stop linear gradient
/// (<see cref="ISubstrateDrawingSession.FillRoundedRectGradient"/>): hot toward white
/// on the lit top, sunk toward iris-tinted near-black at the bottom. The exact
/// constants ARE the look.
/// </remarks>
public sealed class MeshPatchSubstrate : ISwarmSubstrate
{
    private const int MaxGrid = 240;
    private const int MaxCells = 22_000;
    private const double Overlap = 1.06;
    private const double CornerFrac = 0.28;
    private const double MinTargetCellPx = 7.0;
    private const double MaxTargetCellPx = 10.5;
    private const double ThrottledMaxTargetCellPx = 13.0;
    private const double TargetCellSizeMultiplier = 3.6;
    private const int SplatR = 2;
    private const double SplatSigma = 0.92;

    private static readonly Rgba NearBlack = new(18.0 / 255, 22.0 / 255, 34.0 / 255);
    private static readonly Rgba[] IrisRamp =
    {
        new Rgba(120.0 / 255, 196.0 / 255, 255.0 / 255),
        new Rgba(150.0 / 255, 150.0 / 255, 255.0 / 255),
        new Rgba(232.0 / 255, 150.0 / 255, 232.0 / 255),
        new Rgba(255.0 / 255, 168.0 / 255, 150.0 / 255),
        new Rgba(150.0 / 255, 236.0 / 255, 210.0 / 255),
    };

    private int _builtCount = -1;
    private bool _built;
    private int _lastW = -1, _lastH = -1;
    private int _cols, _rows, _cells;
    private double _cellW, _cellH, _originX, _originY, _ext;
    private double _builtMinX, _builtMinY, _builtMaxX, _builtMaxY;

    private double[] _wsum = Array.Empty<double>();
    private double[] _crsum = Array.Empty<double>();
    private double[] _cgsum = Array.Empty<double>();
    private double[] _cbsum = Array.Empty<double>();
    private double[] _colR = Array.Empty<double>();
    private double[] _colG = Array.Empty<double>();
    private double[] _colB = Array.Empty<double>();
    private double[] _dens = Array.Empty<double>();
    private double[] _hcache = Array.Empty<double>();

    private static double HeightField(double gx, double gy, double t)
    {
        double a = System.Math.Sin(gx * 0.9 + t * 0.6) * System.Math.Cos(gy * 0.8 - t * 0.5)
            + 0.5 * System.Math.Sin(gx * 1.9 - gy * 1.3 + t * 0.9);
        return a / 1.5;
    }

    private static Rgba IrisAt(double p)
    {
        int n = IrisRamp.Length;
        double nn = n;
        double fp = (p % nn + nn) % nn;
        int i0 = (int)fp;
        int i1 = (i0 + 1) % n;
        return IrisRamp[i0].Mix(IrisRamp[i1], fp - i0);
    }

    private static double TargetCellPx(double sizePx, bool batteryThrottled)
        => ClampD(sizePx * TargetCellSizeMultiplier, MinTargetCellPx,
            batteryThrottled ? ThrottledMaxTargetCellPx : MaxTargetCellPx);

    private static (int cols, int rows) GridDimensions(double width, double height, double sizePx, bool batteryThrottled)
    {
        double targetCellPx = TargetCellPx(sizePx, batteryThrottled);
        int cols = System.Math.Max(8, System.Math.Min(MaxGrid, (int)System.Math.Round(width / targetCellPx)));
        int rows = System.Math.Max(8, System.Math.Min(MaxGrid, (int)System.Math.Round(height / targetCellPx)));
        int budget = batteryThrottled ? MaxCells / 2 : MaxCells;
        if (cols * rows > budget)
        {
            double scale = System.Math.Sqrt((double)(cols * rows) / budget);
            cols = System.Math.Max(8, (int)(cols / scale));
            rows = System.Math.Max(8, (int)(rows / scale));
        }
        return (cols, rows);
    }

    private void Layout(SwarmSubstrateFrame frame)
    {
        double cw = System.Math.Max(frame.Width, 1);
        double ch = System.Math.Max(frame.Height, 1);
        _builtCount = frame.Dots.Length;
        _built = frame.SettleProgress >= 0.6 || frame.Reduced;
        _lastW = (int)System.Math.Round(cw);
        _lastH = (int)System.Math.Round(ch);

        double minX = double.MaxValue, minY = double.MaxValue, maxX = -double.MaxValue, maxY = -double.MaxValue;
        foreach (SwarmSubstrateDot d in frame.Dots)
        {
            if (d.X < minX) minX = d.X;
            if (d.X > maxX) maxX = d.X;
            if (d.Y < minY) minY = d.Y;
            if (d.Y > maxY) maxY = d.Y;
        }
        if (!(maxX > minX)) { minX = 0; maxX = cw; }
        if (!(maxY > minY)) { minY = 0; maxY = ch; }
        _builtMinX = minX; _builtMinY = minY; _builtMaxX = maxX; _builtMaxY = maxY;

        bool throttle = frame.BatteryThrottled;
        double targetCellPx = TargetCellPx(frame.SizePx, throttle);
        double pad = targetCellPx * 1.5;
        double x0 = System.Math.Max(0.0, minX - pad), y0 = System.Math.Max(0.0, minY - pad);
        double x1 = System.Math.Min(cw, maxX + pad), y1 = System.Math.Min(ch, maxY + pad);
        if (!(x1 > x0)) { x0 = 0; x1 = cw; }
        if (!(y1 > y0)) { y0 = 0; y1 = ch; }
        double bw = x1 - x0, bh = y1 - y0;

        (int c, int r) = GridDimensions(bw, bh, frame.SizePx, throttle);
        _cols = c; _rows = r; _cells = c * r;
        _originX = x0; _originY = y0;
        _cellW = bw / c; _cellH = bh / r;
        _ext = System.Math.Max(_cellW, _cellH) * 0.5 * Overlap;

        _wsum = new double[_cells]; _crsum = new double[_cells]; _cgsum = new double[_cells];
        _cbsum = new double[_cells]; _colR = new double[_cells]; _colG = new double[_cells];
        _colB = new double[_cells]; _dens = new double[_cells]; _hcache = new double[_cells];
    }

    private void Splat(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        Array.Clear(_wsum); Array.Clear(_crsum); Array.Clear(_cgsum); Array.Clear(_cbsum);

        double invCW = 1.0 / System.Math.Max(_cellW, 1e-6);
        double invCH = 1.0 / System.Math.Max(_cellH, 1e-6);
        double twoSig2 = 2 * SplatSigma * SplatSigma;
        int radius = SplatR;

        foreach (SwarmSubstrateDot d in dots)
        {
            double fx = (d.X - _originX) * invCW;
            double fy = (d.Y - _originY) * invCH;
            int cc = (int)fx;
            int rr = (int)fy;
            double cr = d.Rgba.R, cg = d.Rgba.G, cb = d.Rgba.B;
            double wgt0 = System.Math.Max(0.15, d.Opacity);
            for (int dy = -radius; dy <= radius; dy++)
            {
                int ry = rr + dy;
                if (ry < 0 || ry >= _rows) continue;
                double ddy = (ry + 0.5) - fy;
                int baseIdx = ry * _cols;
                for (int dx = -radius; dx <= radius; dx++)
                {
                    int cx = cc + dx;
                    if (cx < 0 || cx >= _cols) continue;
                    double ddx = (cx + 0.5) - fx;
                    double dist2 = ddx * ddx + ddy * ddy;
                    double wg = wgt0 * System.Math.Exp(-dist2 / twoSig2);
                    int idx = baseIdx + cx;
                    _wsum[idx] += wg;
                    _crsum[idx] += wg * cr;
                    _cgsum[idx] += wg * cg;
                    _cbsum[idx] += wg * cb;
                }
            }
        }

        double sumW = 0.0;
        int occ = 0;
        for (int i = 0; i < _cells; i++) if (_wsum[i] > 1e-4) { sumW += _wsum[i]; occ++; }
        double meanW = occ > 0 ? sumW / occ : 1.0;
        double norm = 1.0 / System.Math.Max(meanW * 1.45, 1e-6);
        for (int i = 0; i < _cells; i++)
        {
            double w = _wsum[i];
            if (w > 1e-4)
            {
                double inv = 1.0 / w;
                _colR[i] = _crsum[i] * inv;
                _colG[i] = _cgsum[i] * inv;
                _colB[i] = _cbsum[i] * inv;
                _dens[i] = Smoothstep(0.05, 1.0, w * norm);
            }
            else
            {
                _dens[i] = 0;
            }
        }
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        if (count <= 0) return false;

        int wi = (int)System.Math.Round(System.Math.Max(frame.Width, 1));
        int hi = (int)System.Math.Round(System.Math.Max(frame.Height, 1));
        bool bboxMoved = false;
        if (_cells > 0)
        {
            double minX = double.MaxValue, minY = double.MaxValue, maxX = -double.MaxValue, maxY = -double.MaxValue;
            foreach (SwarmSubstrateDot d in frame.Dots)
            {
                if (d.X < minX) minX = d.X;
                if (d.X > maxX) maxX = d.X;
                if (d.Y < minY) minY = d.Y;
                if (d.Y > maxY) maxY = d.Y;
            }
            double tol = System.Math.Max(_cellW, _cellH) * 1.25;
            bboxMoved = System.Math.Abs(minX - _builtMinX) > tol || System.Math.Abs(maxX - _builtMaxX) > tol
                     || System.Math.Abs(minY - _builtMinY) > tol || System.Math.Abs(maxY - _builtMaxY) > tol;
        }
        if (count != _builtCount || wi != _lastW || hi != _lastH || bboxMoved
            || (!_built && (frame.SettleProgress >= 0.6 || frame.Reduced)))
        {
            Layout(frame);
        }
        if (_cells <= 0) return false;
        Splat(frame);

        bool dark = frame.Stage.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        Rgba accent = frame.Stage.Accent;
        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.55 + 0.45;
        double ht = reduced ? 0 : frame.T;
        double seamPhase = reduced ? 0 : frame.T * 0.18;
        double baseExt = _ext > 0 ? _ext : frame.SizePx * 4;

        for (int i = 0; i < _cells; i++)
        {
            double gx = i % _cols;
            double gy = i / _cols;
            _hcache[i] = HeightField(gx * 0.5, gy * 0.5, ht * 0.4);
        }

        // ── Pass A (dark only): ONE pooled Gaussian bloom under the lit panes ──
        if (dark && !throttled)
        {
            double bloomR = System.Math.Max(3.0, baseExt * 1.2);
            session.Blend = SubstrateBlend.Add;
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < _cells; i++)
                {
                    double dn = _dens[i];
                    if (dn < 0.12) continue;
                    double hf = _hcache[i];
                    double br = ClampD(0.42 + 0.58 * hf, 0, 1) * dn;
                    if (br < 0.12) continue;
                    int col = i % _cols;
                    int row = i / _cols;
                    double x = _originX + (col + 0.5) * _cellW;
                    double y = _originY + (row + 0.5) * _cellH - hf * baseExt * 0.5;
                    Rgba glow = new Rgba(_colR[i], _colG[i], _colB[i]).ToWhite(0.26).Mix(accent, 0.18);
                    double rr = baseExt * (1.35 + 0.5 * br);
                    double a = ClampD(0.42 * br * f, 0, 0.58);
                    session.FillCircle(x, y, rr, glow.WithOpacity(a));
                }
            }
        }

        // ── Pass B: the continuous ROUNDED gradient panes (edge-to-edge sheet) ──
        session.Blend = SubstrateBlend.Normal;
        for (int i = 0; i < _cells; i++)
        {
            double dn = _dens[i];
            if (dn < 0.025) continue;
            double hf = _hcache[i];
            int col = i % _cols;
            int row = i / _cols;
            double cxp = _originX + (col + 0.5) * _cellW;
            double cyp = _originY + (row + 0.5) * _cellH - hf * baseExt * 0.45;

            double gx = col * 0.5, gy = row * 0.5;
            double tilt = reduced ? 0 : 0.20 * (HeightField(gx + 0.6, gy, ht * 0.4) - HeightField(gx - 0.6, gy, ht * 0.4));
            double cosT = System.Math.Cos(tilt), sinT = System.Math.Sin(tilt);

            PointD Rp(double lx, double ly) => new(cxp + (lx * cosT - ly * sinT), cyp + (lx * sinT + ly * cosT));
            PointD pTop = Rp(-baseExt * 0.7, -baseExt);
            PointD pBot = Rp(baseExt * 0.7, baseExt);

            var baseC = new Rgba(_colR[i], _colG[i], _colB[i]);
            double litK = ClampD(0.5 + 0.42 * hf, 0, 1);
            Rgba iris = IrisAt(seamPhase + col * 0.18 + row * 0.12);
            Rgba topC = baseC.ToWhite(0.12 + 0.40 * litK).Mix(iris, 0.10);
            Rgba botC = baseC.Mix(NearBlack, 0.20 * (1 - litK) + 0.06);
            Rgba midC = topC.Mix(botC, 0.5);

            double paneOpacity = ClampD(0.82 * f * dn, 0, 0.88);
            session.FillRoundedRectGradient(cxp, cyp, baseExt, baseExt, baseExt * CornerFrac, tilt,
                topC, midC, botC, pTop, pBot, paneOpacity);

            double specK = ClampD(litK * dn, 0, 1);
            if (specK > 0.12)
            {
                double ox = -baseExt * 0.40, oy = -baseExt * 0.40;
                double hxp = cxp + (ox * cosT - oy * sinT);
                double hyp = cyp + (ox * sinT + oy * cosT);
                double hr = baseExt * (0.78 + 0.28 * specK);
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                double specOpacity = ClampD((dark ? 0.38 : 0.28) * specK * f, 0, dark ? 0.58 : 0.38);
                session.DrawGlowSprite(hxp, hyp, hr, Rgba.White, specOpacity);
                session.Blend = SubstrateBlend.Normal;
            }

            double seamA = ClampD((0.12 + 0.26 * litK) * f * dn, 0, 0.46);
            if (seamA > 0.02)
            {
                session.StrokeRoundedRect(cxp, cyp, baseExt, baseExt, baseExt * CornerFrac, tilt, iris, 1, seamA);
            }
        }

        return true;
    }
}
