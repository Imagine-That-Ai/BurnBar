using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Math;

/// <summary>
/// Lazily-built point-cloud structure for the stroke / streamline idioms — C# port
/// of Swift <c>SubstrateStructureProvider</c> (<c>Views/Substrate/SubstrateKit.swift</c>).
/// It computes a single-stroke nearest-neighbor walk (<see cref="Structure.Order"/>),
/// per-point k-NN lists (<see cref="Structure.Neighbors"/>), and segment-break flags
/// for polylines (<see cref="Structure.Breaks"/>) over a uniform grid, in ~O(n).
/// </summary>
/// <remarks>
/// In the macOS engine one provider instance is owned by the frame and shared by
/// whichever substrate is active. On Windows each stroke/streamline substrate
/// (Glass Ribbon, Silk Streamline, Aurora Filament) owns its own provider — only
/// one substrate paints at a time, and the provider caches by a cheap topology
/// signature so the walk is rebuilt only when the cloud actually changes, never
/// per-frame. Deterministic (index tie-breaks) so the FNV geometry checksum is
/// stable frame-to-frame.
/// </remarks>
public sealed class SubstrateStructure
{
    public readonly struct Structure
    {
        public readonly int[] Order;
        public readonly int[][] Neighbors;
        public readonly bool[] Breaks;

        public Structure(int[] order, int[][] neighbors, bool[] breaks)
        {
            Order = order;
            Neighbors = neighbors;
            Breaks = breaks;
        }
    }

    private Structure? _cached;
    private ulong _sig = ulong.MaxValue;
    private int _cachedK = -1;

    /// <summary>The NN order + kNN for <paramref name="dots"/>, cached by topology signature.</summary>
    public Structure Get(SwarmSubstrateDot[] dots, int k = 6)
    {
        ulong s = Signature(dots);
        if (_cached is Structure c && s == _sig && _cachedK == k) return c;
        Structure built = Build(dots, k);
        _cached = built;
        _sig = s;
        _cachedK = k;
        return built;
    }

    // Cheap topology fingerprint: count + a strided position hash (FNV-1a), matches
    // the Swift signature flavor (coarse rounded positions on a 64-point stride).
    private static ulong Signature(SwarmSubstrateDot[] dots)
    {
        ulong h = 1469598103934665603UL;
        void Mix(long v) => h = (h ^ unchecked((ulong)v)) * 1099511628211UL;
        Mix(dots.Length);
        int stride = System.Math.Max(1, dots.Length / 64);
        for (int i = 0; i < dots.Length; i += stride)
        {
            Mix((long)System.Math.Round(dots[i].X * 0.5));
            Mix((long)System.Math.Round(dots[i].Y * 0.5));
        }
        return h;
    }

    private static Structure Build(SwarmSubstrateDot[] dots, int k)
    {
        int n = dots.Length;
        if (n <= 1)
        {
            var order0 = new int[n];
            for (int i = 0; i < n; i++) order0[i] = i;
            var nb0 = new int[n][];
            for (int i = 0; i < n; i++) nb0[i] = Array.Empty<int>();
            return new Structure(order0, nb0, new bool[n]);
        }

        // Uniform grid over the bounding box for O(n) neighbor queries.
        double minX = dots[0].X, minY = dots[0].Y, maxX = dots[0].X, maxY = dots[0].Y;
        for (int i = 0; i < n; i++)
        {
            SwarmSubstrateDot d = dots[i];
            if (d.X < minX) minX = d.X;
            if (d.Y < minY) minY = d.Y;
            if (d.X > maxX) maxX = d.X;
            if (d.Y > maxY) maxY = d.Y;
        }
        double w = System.Math.Max(1, maxX - minX), hgt = System.Math.Max(1, maxY - minY);
        double cell = System.Math.Max(4.0, System.Math.Sqrt(w * hgt / n)); // ~1 point per cell
        int cols = System.Math.Max(1, (int)(w / cell) + 1);
        int rows = System.Math.Max(1, (int)(hgt / cell) + 1);

        (int cx, int cy) CellOf(SwarmSubstrateDot d) => (
            System.Math.Min(cols - 1, System.Math.Max(0, (int)((d.X - minX) / cell))),
            System.Math.Min(rows - 1, System.Math.Max(0, (int)((d.Y - minY) / cell))));

        var grid = new List<int>[cols * rows];
        for (int i = 0; i < grid.Length; i++) grid[i] = new List<int>();
        for (int i = 0; i < n; i++)
        {
            (int gx, int gy) = CellOf(dots[i]);
            grid[gy * cols + gx].Add(i);
        }

        void Candidates(int i, int ring, List<int> outList)
        {
            outList.Clear();
            (int gx, int gy) = CellOf(dots[i]);
            for (int yy = System.Math.Max(0, gy - ring); yy <= System.Math.Min(rows - 1, gy + ring); yy++)
                for (int xx = System.Math.Max(0, gx - ring); xx <= System.Math.Min(cols - 1, gx + ring); xx++)
                    outList.AddRange(grid[yy * cols + xx]);
        }

        // kNN per point (expand ring until enough candidates).
        var neighbors = new int[n][];
        var nnDist = new double[n];
        var cand = new List<int>(64);
        var scored = new List<(int j, double d)>(64);
        int maxRing = System.Math.Max(cols, rows);
        for (int i = 0; i < n; i++)
        {
            int ring = 1;
            Candidates(i, ring, cand);
            while (cand.Count < k + 1 && ring < maxRing) { ring++; Candidates(i, ring, cand); }
            double xi = dots[i].X, yi = dots[i].Y;
            scored.Clear();
            foreach (int j in cand)
            {
                if (j == i) continue;
                double dx = dots[j].X - xi, dy = dots[j].Y - yi;
                scored.Add((j, dx * dx + dy * dy));
            }
            // distance ascending, index tie-break → deterministic ordering.
            scored.Sort((a, b) => a.d != b.d ? a.d.CompareTo(b.d) : a.j.CompareTo(b.j));
            int take = System.Math.Min(k, scored.Count);
            var nb = new int[take];
            for (int t = 0; t < take; t++) nb[t] = scored[t].j;
            neighbors[i] = nb;
            nnDist[i] = scored.Count > 0 ? System.Math.Sqrt(scored[0].d) : cell;
        }

        // Median nearest-neighbor distance → polyline break threshold.
        var sortedNN = (double[])nnDist.Clone();
        Array.Sort(sortedNN);
        double medianNN = sortedNN[n / 2];
        double breakThresh = System.Math.Max(cell, medianNN * 3.0);

        // Greedy nearest-neighbor walk for a single stroke order. Start nearest centroid.
        double cxs = 0, cys = 0;
        for (int i = 0; i < n; i++) { cxs += dots[i].X; cys += dots[i].Y; }
        cxs /= n; cys /= n;
        int start = 0;
        double bestD = double.PositiveInfinity;
        for (int i = 0; i < n; i++)
        {
            double dd = (dots[i].X - cxs) * (dots[i].X - cxs) + (dots[i].Y - cys) * (dots[i].Y - cys);
            if (dd < bestD) { bestD = dd; start = i; }
        }

        var visited = new bool[n];
        var order = new List<int>(n);
        var breaks = new List<bool>(n);
        int cur = start;
        visited[cur] = true;
        order.Add(cur);
        for (int step = 1; step < n; step++)
        {
            int ring = 1, picked = -1;
            double pickedD = double.PositiveInfinity;
            while (picked == -1 && ring <= maxRing)
            {
                Candidates(cur, ring, cand);
                foreach (int j in cand)
                {
                    if (visited[j]) continue;
                    double dx = dots[j].X - dots[cur].X, dy = dots[j].Y - dots[cur].Y;
                    double dd = dx * dx + dy * dy;
                    // strict-less keeps the lowest index on ties → deterministic.
                    if (dd < pickedD) { pickedD = dd; picked = j; }
                }
                ring++;
            }
            if (picked == -1)
            {
                for (int j = 0; j < n; j++)
                {
                    if (visited[j]) continue;
                    double dx = dots[j].X - dots[cur].X, dy = dots[j].Y - dots[cur].Y;
                    double dd = dx * dx + dy * dy;
                    if (dd < pickedD) { pickedD = dd; picked = j; }
                }
            }
            if (picked < 0) break;
            breaks.Add(System.Math.Sqrt(pickedD) > breakThresh);
            visited[picked] = true;
            order.Add(picked);
            cur = picked;
        }
        breaks.Add(false); // pad to align with order indices (source parity).

        return new Structure(order.ToArray(), neighbors, breaks.ToArray());
    }
}
