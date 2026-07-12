using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Drawn Constellation — faithful C# port of Swift
/// <c>Views/Substrate/Constellation/StellariumSubstrate.swift</c> (port of imaginethat
/// <c>constellation/stellarium.ts</c>). An antique star-chart: a sparse, capped
/// nearest-neighbour GRAPH of luminous edges plus open-ring star NODES sitting exactly
/// on the silhouette points. The lines ARE the mark, so this idiom owns the whole
/// silhouette (<see cref="SuppressesGlyphs"/> = true).
/// </summary>
/// <remarks>
/// Topology (built once per layout via <see cref="SubstrateStructure"/>, cached in
/// point-index space so geometry tracks the moving dots for free): each node links its
/// 1–2 nearest neighbours within a density-adaptive gate (<c>medianNN²·6 + 1</c>),
/// deduped low→high, capped at <c>maxEdges</c>; falls back to the NN-walk chain when too
/// sparse. Per frame: a dark-only Gaussian bloom layer (wide accent wash + non-guide
/// filament glow + survey-beam halo + batched star-core glow), then a wide soft body
/// pass, a crisp thin filament, a crawling DASHED guide-tick pass (<c>dashPhase = -t·9</c>),
/// a survey beam tracing <c>(t·0.11·ec)%ec</c> (dropped when reduced/throttled), and
/// per-node marks — a soft color halo, a luminous open RING, and a hot breathing core.
/// </remarks>
public sealed class StellariumSubstrate : ISwarmSubstrate
{
    private const int MaxEdges = 900;
    private const int GuideEvery = 5;

    private readonly SubstrateStructure _structure = new();

    // Cached constellation graph in point-index space (rebuilt only on count change).
    private readonly List<int> _edgeA = new();
    private readonly List<int> _edgeB = new();
    private int _edgeCount;
    private int _builtCount = -1;

    // Per-frame segment scratch (cleared each frame; reused across passes).
    private readonly List<LineSegment> _allEdges = new();
    private readonly List<LineSegment> _solid = new();
    private readonly List<LineSegment> _guide = new();
    private readonly List<LineSegment> _beam = new();

    public bool SuppressesGlyphs => true;

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;

        EnsureGraph(dots);
        int ec = _edgeCount;

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.55 + 0.45;

        Rgba acc = frame.Stage.Accent;
        Rgba crispCol = dark
            ? new Rgba(acc.R + (1 - acc.R) * 0.72, acc.G + (1 - acc.G) * 0.72, acc.B + (1 - acc.B) * 0.78)
            : new Rgba(acc.R * 0.45, acc.G * 0.45, acc.B * 0.5);
        Rgba beamCol = dark ? new Rgba(0.96, 0.975, 1.0) : crispCol;

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // Build the edge geometry ONCE — reused by the bloom + crisp passes.
        _allEdges.Clear();
        _solid.Clear();
        _guide.Clear();
        if (ec > 0)
        {
            for (int e = 0; e < ec; e++)
            {
                int a = _edgeA[e], b = _edgeB[e];
                var seg = new LineSegment(dots[a].X, dots[a].Y, dots[b].X, dots[b].Y);
                _allEdges.Add(seg);
                if (e % GuideEvery == 0) _guide.Add(seg); else _solid.Add(seg);
            }
        }

        // SURVEY BEAM geometry: the few edges the sweep is currently lighting.
        _beam.Clear();
        var beamLit = new List<(int e, double k)>();
        bool beamActive = !reduced && !throttled && ec > 0;
        if (beamActive)
        {
            double ecD = ec;
            double beamPos = ecD * Frac(t * 0.11);
            double beamWidth = System.Math.Max(2.0, ecD * 0.028);
            for (int e = 0; e < ec; e++)
            {
                double dd = e - beamPos;
                if (dd < -ecD / 2) dd += ecD; else if (dd > ecD / 2) dd -= ecD;
                double k = 1 - System.Math.Abs(dd) / beamWidth;
                if (k <= 0) continue;
                int a = _edgeA[e], b = _edgeB[e];
                _beam.Add(new LineSegment(dots[a].X, dots[a].Y, dots[b].X, dots[b].Y));
                beamLit.Add((e, k));
            }
        }

        // ── BLOOM (dark only): a real Gaussian glow layer under the crisp chart. ──
        if (dark && !throttled && ec > 0)
        {
            double bloomR = System.Math.Max(2.5, sizePx * 1.7);
            double wideW = System.Math.Max(1.6, sizePx * 1.25);
            double glowW = System.Math.Max(1.0, sizePx * 0.72);
            Rgba glowTint = acc.ToWhite(0.32);
            double nodeGlowR = System.Math.Max(1.4, sizePx * 1.55);
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                session.DrawLineBatch(CollectionsMarshal.AsSpan(_allEdges), acc.WithOpacity(0.42 * f), wideW);
                session.DrawLineBatch(CollectionsMarshal.AsSpan(_solid), crispCol.WithOpacity(0.5 * f), glowW);
                if (beamActive)
                    session.DrawLineBatch(CollectionsMarshal.AsSpan(_beam), beamCol.WithOpacity(0.75 * f), glowW * 1.4);
                Rgba coreGlow = glowTint.WithOpacity(0.5 * f);
                for (int i = 0; i < count; i++)
                    session.FillCircle(dots[i].X, dots[i].Y, nodeGlowR, coreGlow);
            }
            session.Blend = SubstrateBlend.Add;
        }

        // ── PASS 1: wide soft body over every edge. ──
        if (ec > 0)
        {
            session.DrawLineBatch(CollectionsMarshal.AsSpan(_allEdges),
                acc.WithOpacity((dark ? 0.14 : 0.1) * f), System.Math.Max(1.4, sizePx * 1.05));
        }

        // ── PASS 2: crisp thin filament + engraved guide-dash crawl. ──
        if (ec > 0)
        {
            double crispW = System.Math.Max(0.8, sizePx * 0.45);
            session.DrawLineBatch(CollectionsMarshal.AsSpan(_solid),
                crispCol.WithOpacity((dark ? 0.62 : 0.72) * f), crispW);
            session.DrawDashedLineBatch(CollectionsMarshal.AsSpan(_guide),
                crispCol.WithOpacity((dark ? 0.52 : 0.58) * f), crispW,
                dashOn: 2.4, dashOff: 4.2, dashPhase: reduced ? 0 : -t * 9);

            // SURVEY BEAM crisp core: bright traced line over the bloom halo.
            if (beamActive)
            {
                Span<LineSegment> one = stackalloc LineSegment[1];
                foreach ((int e, double k) in beamLit)
                {
                    int a = _edgeA[e], b = _edgeB[e];
                    one[0] = new LineSegment(dots[a].X, dots[a].Y, dots[b].X, dots[b].Y);
                    double alpha = ClampD(Smoothstep(0, 1, k) * (dark ? 0.7 : 0.65) * f, 0, 1);
                    session.DrawLineBatch(one, beamCol.WithOpacity(alpha),
                        System.Math.Max(0.9, sizePx * (0.55 + 0.6 * k)));
                }
            }
        }

        // ── NODES: soft halo, luminous open ring, hot breathing core. ──
        double ringR = System.Math.Max(1.4, sizePx * 0.95);
        double ringW = System.Math.Max(0.7, sizePx * 0.34);
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            double ph = Shash(i * 1.61 + 0.31) * Tau;
            double tw = reduced ? 0.6 + 0.4 * System.Math.Sin(ph) : 0.5 + 0.5 * System.Math.Sin(t * 1.5 + ph);
            Rgba col = d.Rgba;

            double haloR = System.Math.Max(1.2, sizePx * (1.05 + 0.45 * tw));
            session.FillCircle(x, y, haloR, col.WithOpacity((dark ? 0.2 : 0.13) * f));

            Rgba ringCol = dark ? col.ToWhite(0.28) : col;
            session.StrokeCircle(x, y, ringR, ringCol.WithOpacity((dark ? 0.62 : 0.6) * f), ringW);

            Rgba coreCol = dark ? col.ToWhite(0.62) : col;
            double coreR = System.Math.Max(0.8, sizePx * (0.38 + 0.14 * tw));
            double coreA = ClampD((dark ? 0.8 + 0.2 * tw : 0.82 + 0.18 * tw) * f, 0, 1);
            session.FillCircle(x, y, coreR, coreCol.WithOpacity(coreA));
        }

        return true;
    }

    /// <summary>Build the sparse, deduped constellation graph (once per topology).</summary>
    private void EnsureGraph(SwarmSubstrateDot[] dots)
    {
        int count = dots.Length;
        if (_builtCount == count) return;
        _builtCount = count;

        _edgeA.Clear();
        _edgeB.Clear();
        _edgeCount = 0;
        if (count < 2) return;

        SubstrateStructure.Structure s = _structure.Get(dots, 6);
        int[][] neigh = s.Neighbors;

        if (neigh.Length >= count)
        {
            var samples = new List<double>();
            int step = System.Math.Max(1, count / 64);
            int i = 0;
            while (i < count)
            {
                int[] row = neigh[i];
                if (row.Length > 0)
                {
                    int j = row[0];
                    if (j >= 0 && j < count)
                    {
                        double dx = dots[i].X - dots[j].X, dy = dots[i].Y - dots[j].Y;
                        samples.Add(dx * dx + dy * dy);
                    }
                }
                i += step;
            }
            samples.Sort();
            double med = samples.Count == 0
                ? frame_cloudR2(dots) * 0.01
                : samples[samples.Count >> 1];
            double gate = med * 6.0 + 1;

            var seen = new HashSet<long>();
            for (int a0 = 0; a0 < count && _edgeCount < MaxEdges; a0++)
            {
                int[] row = neigh[a0];
                int linked = 0;
                foreach (int j in row)
                {
                    if (linked >= 2) break;
                    if (j < 0 || j >= count || j == a0) continue;
                    double dx = dots[a0].X - dots[j].X, dy = dots[a0].Y - dots[j].Y;
                    if (dx * dx + dy * dy > gate) continue;
                    int a = a0 < j ? a0 : j;
                    int b = a0 < j ? j : a0;
                    long key = (long)a * count + b;
                    if (!seen.Add(key)) continue;
                    _edgeA.Add(a); _edgeB.Add(b); _edgeCount++;
                    linked++;
                }
            }
        }

        // Fallback/supplement: chain the NN-walk order for a continuous spine.
        if (_edgeCount < 1)
        {
            int[] order = s.Order;
            if (order.Length >= 2)
            {
                int i = 1;
                while (i < order.Length && _edgeCount < MaxEdges)
                {
                    int a = order[i - 1], b = order[i];
                    if (a != b)
                    {
                        _edgeA.Add(System.Math.Min(a, b)); _edgeB.Add(System.Math.Max(a, b)); _edgeCount++;
                    }
                    i++;
                }
            }
            else
            {
                int i = 1;
                while (i < count && _edgeCount < MaxEdges)
                {
                    _edgeA.Add(i - 1); _edgeB.Add(i); _edgeCount++;
                    i++;
                }
            }
        }
    }

    // Coarse cloud-radius² fallback for the density gate when no NN samples exist.
    private static double frame_cloudR2(SwarmSubstrateDot[] dots)
    {
        int n = dots.Length;
        double cx = 0, cy = 0;
        for (int i = 0; i < n; i++) { cx += dots[i].X; cy += dots[i].Y; }
        cx /= n; cy /= n;
        double sum = 0;
        for (int i = 0; i < n; i++)
        {
            double dx = dots[i].X - cx, dy = dots[i].Y - cy;
            sum += System.Math.Sqrt(dx * dx + dy * dy);
        }
        double r = sum / n;
        return r * r;
    }
}
