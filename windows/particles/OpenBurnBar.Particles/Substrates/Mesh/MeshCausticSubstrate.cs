using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Mesh;

/// <summary>
/// Caustic Pool — faithful C# port of Swift
/// <c>Views/Substrate/Mesh/MeshCausticSubstrate.swift</c>. A continuous web of light
/// through water. In the dense SHAPE regime it renders per-vertex caustic pools + a
/// refracted filament NET built from the kNN <see cref="SubstrateStructureProvider"/>
/// (the connected-node lattice of the Mesh family) that pools light on the silhouette.
/// In the sparse FREE-SWARM regime it renders a CONTINUOUS caustic material across the
/// whole canvas: a coarse density/colour field splatted from the swarm and box-blurred
/// (feathers to nothing where the swarm thins), an animated 2-layer fbm height field
/// folded with |sin|³ and crossed → a crawling net of thin bright caustic filaments,
/// modulated by the density envelope, coloured by the closed iris ramp + local brand.
/// </summary>
/// <remarks>
/// One true Gaussian bloom layer carries the glow; a crisp additive core pass adds the
/// hot filament cores; gated specular sparks ride the brightest cells. <c>reduced</c>
/// freezes phase/drift; <c>batteryThrottled</c> drops the bloom + sparks. The exact
/// constants ARE the look.
/// </remarks>
public sealed class MeshCausticSubstrate : ISwarmSubstrate
{
    // SHAPE-regime scratch.
    private double[] _inten = Array.Empty<double>();
    private double[] _hueU = Array.Empty<double>();
    // FREE-SWARM cell scratch.
    private double[] _aW = Array.Empty<double>();
    private double[] _aR = Array.Empty<double>();
    private double[] _aG = Array.Empty<double>();
    private double[] _aB = Array.Empty<double>();
    private double[] _aHue = Array.Empty<double>();
    private double[] _blurTmp = Array.Empty<double>();
    private double[] _cellI = Array.Empty<double>();
    private double[] _cellR = Array.Empty<double>();
    private double[] _cellG = Array.Empty<double>();
    private double[] _cellB = Array.Empty<double>();

    // 6-stop closed iridescent jewel ramp (sky→aqua→mint→gold→magenta→violet).
    private static readonly Rgba[] IrisRamp =
    {
        new Rgba(70 / 255.0, 150 / 255.0, 235 / 255.0),
        new Rgba(80 / 255.0, 220 / 255.0, 210 / 255.0),
        new Rgba(150 / 255.0, 235 / 255.0, 150 / 255.0),
        new Rgba(235 / 255.0, 200 / 255.0, 120 / 255.0),
        new Rgba(235 / 255.0, 130 / 255.0, 200 / 255.0),
        new Rgba(140 / 255.0, 120 / 255.0, 240 / 255.0),
    };

    private static readonly Rgba SparkTint = new(1.0, 232 / 255.0, 1.0);

    private static Rgba Iris(double u)
    {
        int n = IrisRamp.Length;
        double fu = Frac(u) * n;
        int i = (int)System.Math.Floor(fu) % n;
        double fr = fu - System.Math.Floor(fu);
        return IrisRamp[i].Mix(IrisRamp[(i + 1) % n], fr);
    }

    private static double VNoise(double x, double y)
    {
        double xi = System.Math.Floor(x), yi = System.Math.Floor(y);
        double xf = x - xi, yf = y - yi;
        double u = xf * xf * (3 - 2 * xf);
        double v = yf * yf * (3 - 2 * yf);
        double n00 = Shash(xi * 127.1 + yi * 311.7);
        double n10 = Shash((xi + 1) * 127.1 + yi * 311.7);
        double n01 = Shash(xi * 127.1 + (yi + 1) * 311.7);
        double n11 = Shash((xi + 1) * 127.1 + (yi + 1) * 311.7);
        double a = n00 + (n10 - n00) * u;
        double b = n01 + (n11 - n01) * u;
        return a + (b - a) * v;
    }

    private static double Fbm2(double x, double y)
        => VNoise(x, y) * 0.65 + VNoise(x * 2.03 + 5.2, y * 2.03 - 3.1) * 0.35;

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        if (count == 0) return true;

        int formed = 0;
        for (int i = 0; i < count; i++) if (frame.Dots[i].InShape) formed++;
        double inShapeFrac = (double)formed / count;
        bool shapeMode = frame.IsShapeMode || (frame.SettleProgress >= 0.6 && inShapeFrac > 0.5);

        double f = ClampD(frame.SettleProgress, 0, 1) * 0.55 + 0.45;

        if (shapeMode) PaintShapePools(frame, session, f);
        else PaintCausticField(frame, session, f);
        return true;
    }

    // ── FREE-SWARM — continuous caustic field across the whole canvas ──
    private void PaintCausticField(SwarmSubstrateFrame frame, ISubstrateDrawingSession session, double f)
    {
        int count = frame.Dots.Length;
        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        Rgba accent = frame.Stage.Accent;
        Rgba ink = frame.Stage.Ink;

        double width = frame.Width, height = frame.Height;
        if (width <= 1 || height <= 1) return;
        double minDim = System.Math.Min(width, height);

        double step = ClampD(minDim * 0.05, 12, 60);
        int cols = System.Math.Max(3, (int)System.Math.Ceiling(width / step) + 1);
        int rows = System.Math.Max(3, (int)System.Math.Ceiling(height / step) + 1);
        int nCells = cols * rows;

        if (_aW.Length != nCells)
        {
            _aW = new double[nCells]; _aR = new double[nCells]; _aG = new double[nCells];
            _aB = new double[nCells]; _aHue = new double[nCells]; _blurTmp = new double[nCells];
            _cellI = new double[nCells]; _cellR = new double[nCells]; _cellG = new double[nCells];
            _cellB = new double[nCells];
        }
        else
        {
            Array.Clear(_aW); Array.Clear(_aR); Array.Clear(_aG); Array.Clear(_aB); Array.Clear(_aHue);
        }

        double invStep = 1 / step;
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = frame.Dots[i];
            double gx = d.X * invStep - 0.5;
            double gy = d.Y * invStep - 0.5;
            int c0 = (int)System.Math.Floor(gx), r0 = (int)System.Math.Floor(gy);
            double fx = gx - c0, fy = gy - r0;
            double w = ClampD(d.Opacity, 0.2, 1.0) * (0.7 + 0.35 * (d.BaseSize - 0.8));
            Rgba rgba = d.Rgba;
            int cyRow = r0;
            double wy = 1 - fy;
            for (int sy = 0; sy < 2; sy++)
            {
                if (cyRow >= 0 && cyRow < rows)
                {
                    int cxi = c0;
                    double wx = 1 - fx;
                    for (int sx = 0; sx < 2; sx++)
                    {
                        if (cxi >= 0 && cxi < cols)
                        {
                            double ww = w * wx * wy;
                            int idx = cyRow * cols + cxi;
                            _aW[idx] += ww;
                            _aR[idx] += ww * rgba.R;
                            _aG[idx] += ww * rgba.G;
                            _aB[idx] += ww * rgba.B;
                            _aHue[idx] += ww * d.ColorIndex;
                        }
                        cxi += 1; wx = fx;
                    }
                }
                cyRow += 1; wy = fy;
            }
        }

        BlurField(_aW, cols, rows);
        BlurField(_aW, cols, rows);
        BlurField(_aR, cols, rows);
        BlurField(_aG, cols, rows);
        BlurField(_aB, cols, rows);
        BlurField(_aHue, cols, rows);

        double maxW = 1e-4;
        foreach (double v in _aW) if (v > maxW) maxW = v;
        double invMaxW = 1 / maxW;

        double phase = reduced ? 0.55 : t * (Tau * 0.08);
        double hueDrift = reduced ? 0.12 : Frac(t / 16);
        double nf = 1.0 / System.Math.Max(40.0, minDim * 0.16);
        double flowX = phase * 0.25;
        double flowY = -phase * 0.18;
        double invW = 1 / width, invH = 1 / height;

        for (int r = 0; r < rows; r++)
        {
            double py = (r + 0.5) * step;
            for (int c = 0; c < cols; c++)
            {
                int idx = r * cols + c;
                double px = (c + 0.5) * step;
                double wsum = _aW[idx];
                double dn = wsum * invMaxW;

                double x = px * nf, y = py * nf;
                double h1 = Fbm2(x + flowX, y + flowY);
                double h2 = Fbm2(y * 0.92 - 11.0 - flowY, x * 0.92 + 7.0 + flowX);
                double s1 = System.Math.Abs(System.Math.Sin((h1 * 2.6 + phase) * System.Math.PI));
                double s2 = System.Math.Abs(System.Math.Sin((h2 * 2.6 - phase * 0.8) * System.Math.PI));
                double r1 = s1 * s1 * s1;
                double r2 = s2 * s2 * s2;
                double cross = r1 * r2;
                double web = r1 * 0.7 + r2 * 0.55 + cross * cross * 1.1;

                double env = Smoothstep(0.0, 0.55, dn + 0.16);
                _cellI[idx] = ClampD(web * env, 0, 1.5);

                double posU = (px * invW * 0.55 + py * invH * 0.45) * 0.5;
                double lhue = wsum > 1e-4 ? _aHue[idx] / wsum : 0;
                Rgba col = Iris(posU + h1 * 0.55 + lhue * 0.5 + hueDrift);
                if (wsum > 1e-4)
                {
                    double inv = 1 / wsum;
                    var brand = new Rgba(_aR[idx] * inv, _aG[idx] * inv, _aB[idx] * inv);
                    col = col.Mix(brand, 0.3 * ClampD(dn, 0, 1));
                }
                col = col.Mix(accent, 0.08);
                _cellR[idx] = col.R; _cellG[idx] = col.G; _cellB[idx] = col.B;
            }
        }

        if (dark)
        {
            if (!lite)
            {
                double bloomR = ClampD(step * 0.72, 3, 26);
                double discR = step * 0.95;
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int r = 0; r < rows; r++)
                    {
                        double py = (r + 0.5) * step;
                        for (int c = 0; c < cols; c++)
                        {
                            int idx = r * cols + c;
                            double k = _cellI[idx];
                            if (k < 0.045) continue;
                            double a = ClampD(k * 0.55 * f, 0, 0.82);
                            if (a < 0.012) continue;
                            double px = (c + 0.5) * step;
                            var col = new Rgba(_cellR[idx], _cellG[idx], _cellB[idx], a);
                            session.FillCircle(px, py, discR, col);
                        }
                    }
                }
            }

            session.Blend = SubstrateBlend.Add;
            for (int r = 0; r < rows; r++)
            {
                double py = (r + 0.5) * step;
                for (int c = 0; c < cols; c++)
                {
                    int idx = r * cols + c;
                    double k = _cellI[idx];
                    if (k < 0.2) continue;
                    double kk = ClampD((k - 0.2) / 1.3, 0, 1);
                    double a = ClampD((0.18 + 0.7 * kk) * f, 0, 0.9);
                    if (a < 0.012) continue;
                    double rad = step * (0.28 + 0.55 * kk);
                    double px = (c + 0.5) * step;
                    Rgba col = new Rgba(_cellR[idx], _cellG[idx], _cellB[idx]).ToWhite(0.22 + 0.5 * kk);
                    session.FillCircle(px, py, rad, col.WithOpacity(a));
                }
            }

            if (!lite)
            {
                double invStep2 = 1 / step;
                for (int i = 0; i < count; i++)
                {
                    SwarmSubstrateDot d = frame.Dots[i];
                    int c = System.Math.Min(cols - 1, System.Math.Max(0, (int)(d.X * invStep2)));
                    int r = System.Math.Min(rows - 1, System.Math.Max(0, (int)(d.Y * invStep2)));
                    double k = _cellI[r * cols + c];
                    if (k < 0.5) continue;
                    double seed = Shash(i * 2.71 + 0.13);
                    double tw = reduced ? 0.5 + 0.5 * System.Math.Sin(seed * 23) : System.Math.Sin(t * (1.3 + seed) + seed * Tau);
                    if (tw < 0.25) continue;
                    double sp = ClampD((k - 0.5) / 0.6, 0, 1);
                    double a = ClampD(0.42 * sp * tw * f, 0, 0.6);
                    if (a < 0.008) continue;
                    double rad = sizePx * (0.8 + 1.5 * sp);
                    session.DrawGlowSprite(d.X, d.Y, rad, SparkTint, a);
                }
            }
        }
        else
        {
            session.Blend = SubstrateBlend.Normal;
            double discR = step * 0.98;
            for (int r = 0; r < rows; r++)
            {
                double py = (r + 0.5) * step;
                for (int c = 0; c < cols; c++)
                {
                    int idx = r * cols + c;
                    double k = _cellI[idx];
                    if (k < 0.045) continue;
                    double a = ClampD((0.18 + 0.55 * k) * f, 0, 0.72);
                    if (a < 0.01) continue;
                    double px = (c + 0.5) * step;
                    Rgba pool = new Rgba(_cellR[idx], _cellG[idx], _cellB[idx]).Mix(ink, 0.28);
                    session.FillCircle(px, py, discR, pool.WithOpacity(a));
                }
            }
            for (int r = 0; r < rows; r++)
            {
                double py = (r + 0.5) * step;
                for (int c = 0; c < cols; c++)
                {
                    int idx = r * cols + c;
                    double k = _cellI[idx];
                    if (k < 0.42) continue;
                    double kk = ClampD((k - 0.42) / 1.0, 0, 1);
                    double a = ClampD(0.5 * kk * f, 0, 0.6);
                    if (a < 0.01) continue;
                    double rad = step * (0.2 + 0.34 * kk);
                    double px = (c + 0.5) * step;
                    Rgba col = new Rgba(_cellR[idx], _cellG[idx], _cellB[idx]).ToWhite(0.6);
                    session.FillCircle(px, py, rad, col.WithOpacity(a));
                }
            }
        }
    }

    private void BlurField(double[] a, int cols, int rows)
    {
        for (int r = 0; r < rows; r++)
        {
            int baseIdx = r * cols;
            for (int c = 0; c < cols; c++)
            {
                int i = baseIdx + c;
                double l = c > 0 ? a[i - 1] : a[i];
                double rr = c < cols - 1 ? a[i + 1] : a[i];
                _blurTmp[i] = (l + 2 * a[i] + rr) * 0.25;
            }
        }
        for (int r = 0; r < rows; r++)
        {
            int baseIdx = r * cols;
            for (int c = 0; c < cols; c++)
            {
                int i = baseIdx + c;
                double u = r > 0 ? _blurTmp[i - cols] : _blurTmp[i];
                double dn = r < rows - 1 ? _blurTmp[i + cols] : _blurTmp[i];
                a[i] = (u + 2 * _blurTmp[i] + dn) * 0.25;
            }
        }
    }

    // ── SHAPE — per-vertex pooled caustics + refracted filament net ──
    private void PaintShapePools(SwarmSubstrateFrame frame, ISubstrateDrawingSession session, double f)
    {
        int count = frame.Dots.Length;
        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        double cx = frame.Cx, cy = frame.Cy, radius = frame.CloudRadius;
        Rgba accent = frame.Stage.Accent;
        Rgba ink = frame.Stage.Ink;

        double phase = reduced ? 0.6 : t * (Tau * 0.08);
        double hueDrift = reduced ? 0.15 : Frac(t / 14);
        double fs = 3.4 / System.Math.Max(radius, 1);

        if (_inten.Length != count)
        {
            _inten = new double[count];
            _hueU = new double[count];
        }

        double maxI = 1e-4;
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = frame.Dots[i];
            double x = d.X, y = d.Y;
            double fld = Fbm2(x * fs + phase * 0.6, y * fs - phase * 0.4);
            double ridge = System.Math.Abs(System.Math.Sin((fld * 2.4 + phase) * System.Math.PI));
            ridge = ridge * ridge * ridge;
            double seed = Shash(i * 1.37 + 0.5);
            double pulse = reduced
                ? 0.78 + 0.22 * (0.5 + 0.5 * System.Math.Sin(seed * 17))
                : 0.7 + 0.3 * (0.5 + 0.5 * System.Math.Sin(t * (1.0 + seed * 0.8) + seed * Tau));
            double v = ClampD((0.22 + 0.92 * ridge) * pulse, 0, 1.7);
            _inten[i] = v;
            if (v > maxI) maxI = v;
            double ang = System.Math.Atan2(y - cy, x - cx) / Tau;
            _hueU[i] = ang * 0.5 + fld * 0.7 + hueDrift;
        }
        double invMax = 1 / maxI;

        int nb = IrisRamp.Length;
        var bucketSegs = new List<LineSegment>[nb];
        for (int i = 0; i < nb; i++) bucketSegs[i] = new List<LineSegment>();
        var bucketStrSum = new double[nb];
        var bucketN = new int[nb];
        int[][] neighbors = frame.Structure.Get(frame.Dots, 6).Neighbors;
        if (neighbors.Length >= count)
        {
            double gapSq = radius * radius * 0.16;
            for (int i = 0; i < count; i++)
            {
                double ki = _inten[i] * invMax;
                if (ki < 0.4) continue;
                SwarmSubstrateDot di = frame.Dots[i];
                int[] list = neighbors[i];
                int lim = System.Math.Min(2, list.Length);
                for (int jn = 0; jn < lim; jn++)
                {
                    int nj = list[jn];
                    if (nj <= i) continue;
                    double kj = _inten[nj] * invMax;
                    if (kj < 0.4) continue;
                    SwarmSubstrateDot dj = frame.Dots[nj];
                    double dx = dj.X - di.X, dy = dj.Y - di.Y;
                    if (dx * dx + dy * dy > gapSq) continue;
                    double strength = ClampD((ki + kj) * 0.5 - 0.3, 0, 1) * 1.7;
                    double hm = (_hueU[i] + _hueU[nj]) * 0.5;
                    int bkt = System.Math.Min(nb - 1, (int)(Frac(hm) * nb));
                    bucketSegs[bkt].Add(new LineSegment(di.X, di.Y, dj.X, dj.Y));
                    bucketStrSum[bkt] += strength;
                    bucketN[bkt] += 1;
                }
            }
        }

        Rgba BucketHue(int b) => Iris((b + 0.5) / nb);

        if (dark)
        {
            if (!lite)
            {
                double bloomR = System.Math.Max(2.0, sizePx * 2.2);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < count; i++)
                    {
                        SwarmSubstrateDot d = frame.Dots[i];
                        double k = _inten[i] * invMax;
                        Rgba hu = Iris(_hueU[i]);
                        Rgba col = d.Rgba.Mix(hu, 0.66).Mix(accent, 0.12);
                        double rad = sizePx * (0.9 + 2.8 * k);
                        double a = ClampD((0.10 + 0.5 * k) * f, 0, 0.72);
                        if (a < 0.012) continue;
                        session.FillCircle(d.X, d.Y, rad, col.WithOpacity(a));
                    }
                    for (int b = 0; b < nb; b++)
                    {
                        int n = bucketN[b];
                        if (n == 0) continue;
                        double meanStr = bucketStrSum[b] / n;
                        double a = ClampD(0.42 * meanStr, 0, 0.85) * f;
                        if (a < 0.012) continue;
                        Rgba fil = BucketHue(b).Mix(Rgba.White, 0.45);
                        session.DrawLineBatch(Span(bucketSegs[b]), fil.WithOpacity(a), 2.4);
                    }
                }
            }

            session.Blend = SubstrateBlend.Add;
            for (int i = 0; i < count; i++)
            {
                SwarmSubstrateDot d = frame.Dots[i];
                double k = _inten[i] * invMax;
                Rgba hu = Iris(_hueU[i]);
                Rgba body = d.Rgba.Mix(hu, 0.6).ToWhite(0.18 + 0.5 * k);
                double rad = sizePx * (0.42 + 1.25 * k);
                double a = ClampD((0.20 + 0.72 * k) * f, 0, 0.95);
                if (a < 0.01) continue;
                session.FillCircle(d.X, d.Y, rad, body.WithOpacity(a));
            }

            for (int b = 0; b < nb; b++)
            {
                int n = bucketN[b];
                if (n == 0) continue;
                double meanStr = bucketStrSum[b] / n;
                double a = ClampD(0.34 * meanStr, 0, 0.7) * f;
                if (a < 0.012) continue;
                Rgba fil = BucketHue(b).Mix(Rgba.White, 0.55);
                session.DrawLineBatch(Span(bucketSegs[b]), fil.WithOpacity(a), 1.0);
            }

            if (!lite)
            {
                for (int i = 0; i < count; i++)
                {
                    double k = _inten[i] * invMax;
                    if (k < 0.6) continue;
                    double seed = Shash(i * 2.71 + 0.13);
                    double tw = reduced ? 0.5 + 0.5 * System.Math.Sin(seed * 23) : System.Math.Sin(t * (1.4 + seed) + seed * Tau);
                    if (tw < 0.2) continue;
                    double sp = (k - 0.6) / 0.4;
                    double a = ClampD(0.4 * sp * tw * f, 0, 0.6);
                    if (a < 0.006) continue;
                    double rad = sizePx * (0.8 + 1.4 * sp);
                    SwarmSubstrateDot d = frame.Dots[i];
                    session.DrawGlowSprite(d.X, d.Y, rad, SparkTint, a);
                }
            }
        }
        else
        {
            session.Blend = SubstrateBlend.Normal;

            for (int i = 0; i < count; i++)
            {
                SwarmSubstrateDot d = frame.Dots[i];
                double k = _inten[i] * invMax;
                double a = ClampD((0.16 + 0.5 * k) * f, 0, 0.66);
                if (a < 0.006) continue;
                double rad = sizePx * (1.5 + 1.6 * k);
                Rgba pool = d.Rgba.Mix(ink, 0.42).WithOpacity(a);
                session.FillCircle(d.X, d.Y, rad, pool);
            }

            for (int i = 0; i < count; i++)
            {
                SwarmSubstrateDot d = frame.Dots[i];
                double k = _inten[i] * invMax;
                Rgba hu = Iris(_hueU[i]);
                Rgba col = d.Rgba.Mix(hu, 0.5);
                double rad = sizePx * (0.9 + 1.5 * k);
                double a = ClampD((0.4 + 0.5 * k) * f, 0, 0.95);
                if (a < 0.01) continue;
                session.FillCircle(d.X, d.Y, rad, col.WithOpacity(a));
                if (k > 0.45)
                {
                    double hr = rad * 0.42;
                    double ha = ClampD((k - 0.45) * 1.1 * f, 0, 0.7);
                    session.FillCircle(d.X, d.Y, hr, col.ToWhite(0.62).WithOpacity(ha));
                }
            }

            for (int b = 0; b < nb; b++)
            {
                int n = bucketN[b];
                if (n == 0) continue;
                double meanStr = bucketStrSum[b] / n;
                double a = ClampD(0.34 * meanStr, 0, 0.6) * f;
                if (a < 0.012) continue;
                Rgba fil = BucketHue(b).Mix(ink, 0.18);
                session.DrawLineBatch(Span(bucketSegs[b]), fil.WithOpacity(a), 1.1);
            }

            if (!lite)
            {
                for (int i = 0; i < count; i++)
                {
                    double k = _inten[i] * invMax;
                    if (k < 0.62) continue;
                    double seed = Shash(i * 2.71 + 0.13);
                    double tw = reduced ? 0.5 + 0.5 * System.Math.Sin(seed * 23) : System.Math.Sin(t * (1.4 + seed) + seed * Tau);
                    if (tw < 0.2) continue;
                    double sp = (k - 0.62) / 0.38;
                    double a = ClampD(0.5 * sp * tw * f, 0, 0.55);
                    if (a < 0.01) continue;
                    double rad = sizePx * (0.4 + 0.5 * sp);
                    SwarmSubstrateDot d = frame.Dots[i];
                    session.FillCircle(d.X, d.Y, rad, Rgba.White.WithOpacity(a));
                }
            }
        }
    }

    private static ReadOnlySpan<LineSegment> Span(List<LineSegment> l)
        => System.Runtime.InteropServices.CollectionsMarshal.AsSpan(l);
}
