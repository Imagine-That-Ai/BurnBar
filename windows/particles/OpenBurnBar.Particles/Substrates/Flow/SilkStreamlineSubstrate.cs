using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Flow;

/// <summary>
/// Silk Streamline — C# port of Swift <c>Views/Substrate/Flow/SilkStreamlineSubstrate.swift</c>
/// (itself a port of imaginethat <c>flow/silk-streamline.ts</c>). The curl-noise wind that
/// orients the Flow world, drawn in INK: the cloud is grouped once per layout (via the NN
/// walk + break flags) into a handful of broad-nib calligraphic streamlines. Each stream is
/// filled as a single closed ribbon polygon whose two edges are offset from the centreline
/// by a fixed flat-nib vector, so apparent weight is the true thick/thin of a calligraphy
/// pen; a slow ~0.18 Hz pressure wave travels head→tail and a faint nib-wobble keeps the
/// edge wet.
/// </summary>
/// <remarks>
/// INK is opaque source-over on both stages (must read on a light canvas). Per-stream linear
/// gradients (ink + a luminous dark-bloom variant) are cached and rebuilt only on layout /
/// polarity change. A true additive Gaussian bloom underlays the ink on dark; a satin sheen
/// runs the centreline crease; a wet-head catchlight rides the travelling-wave peak. Owns the
/// whole silhouette → <see cref="SuppressesGlyphs"/> is <c>true</c>. Constants match the
/// Swift original line-for-line.
/// </remarks>
public sealed class SilkStreamlineSubstrate : ISwarmSubstrate
{
    private static readonly double Ex = System.Math.Cos(-System.Math.PI / 4.4);
    private static readonly double Ey = System.Math.Sin(-System.Math.PI / 4.4);

    public bool SuppressesGlyphs => true;

    private sealed class Stream
    {
        public int[] Idx = Array.Empty<int>();
        public Vec2[] Pts = Array.Empty<Vec2>();
        public double[] Pressure = Array.Empty<double>();
        public double[] Arc = Array.Empty<double>();
        public double Seed;
        public GradientStop[] Stops = Array.Empty<GradientStop>();
        public GradientStop[] GlowStops = Array.Empty<GradientStop>();
        public Vec2 Head;
        public Vec2 Tail;
        public Rgba Solid;
        // Per-frame ribbon scratch (filled in place; no per-frame heap churn).
        public Vec2[] BodyBuf = Array.Empty<Vec2>();   // 2n closed loop (n>=2)
        public Vec2[] CreaseBuf = Array.Empty<Vec2>(); // n centreline
        public int N;
    }

    private readonly SubstrateStructure _structure = new();
    private readonly List<Stream> _streams = new();
    private double[] _wob = Array.Empty<double>();
    private double _sig = double.NaN;
    private bool _builtDark;
    private readonly GradientStop[] _sbuf = new GradientStop[8];

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0 || frame.CloudRadius <= 0) return true;

        double newSig = count * 131.0
            + System.Math.Round(dots[0].X) * 0.13
            + System.Math.Round(dots[0].Y) * 0.071
            + System.Math.Round(frame.CloudRadius) * 1.7
            + System.Math.Round(frame.Cx) * 0.011
            + System.Math.Round(frame.Cy) * 0.017;
        if (newSig != _sig || _streams.Count == 0 || frame.Dark != _builtDark)
        {
            _sig = newSig;
            _builtDark = frame.Dark;
            Rebuild(frame);
        }
        if (_streams.Count == 0) return true;

        bool reduced = frame.Reduced;
        bool dark = frame.Dark;
        double nibW = ClampD(frame.CloudRadius * 0.09, 3.2, 22)
            * (reduced ? 1 : 0.6 + 0.4 * ClampD(frame.SettleProgress, 0, 1));
        double wave = reduced ? 0 : frame.T * (Tau * 0.18);
        double t = frame.T;

        double ex = Ex, ey = Ey;
        double nx = -ey, ny = ex;

        double HalfAt(Stream s, int i)
        {
            double pr = s.Pressure[i];
            if (!reduced)
                pr *= 0.78 + 0.34 * (0.5 + 0.5 * System.Math.Sin(wave - s.Arc[i] * 5.0 + s.Seed * 2.0));
            return 0.5 * nibW * pr;
        }
        double WanderAt(Stream s, int i)
        {
            double bas = _wob[s.Idx[i]] * nibW * 0.5;
            if (reduced) return bas;
            return bas + System.Math.Sin(t * 1.3 + i * 0.7 + s.Seed * 3) * nibW * 0.06;
        }

        // Build each broad-nib ribbon polygon + centreline crease ONCE this frame.
        foreach (Stream s in _streams)
        {
            int n = s.Pts.Length;
            if (n < 2) continue;
            int w = 0;
            for (int i = 0; i < n; i++)
            {
                Vec2 p = s.Pts[i];
                double hw = HalfAt(s, i), wd = WanderAt(s, i);
                double cx = p.X + nx * wd, cy = p.Y + ny * wd;
                s.CreaseBuf[i] = new Vec2(cx, cy);
                s.BodyBuf[w++] = new Vec2(cx + ex * hw, cy + ey * hw);
            }
            for (int i = n - 1; i >= 0; i--)
            {
                Vec2 p = s.Pts[i];
                double hw = HalfAt(s, i), wd = WanderAt(s, i);
                s.BodyBuf[w++] = new Vec2(p.X - ex * hw + nx * wd, p.Y - ey * hw + ny * wd);
            }
        }

        // PASS 1 (dark) — TRUE GAUSSIAN BLOOM under the ink.
        if (dark && !frame.BatteryThrottled)
        {
            double blurR = ClampD(nibW * 0.95, 3, 15);
            double bloomOpacity = reduced ? 0.44 : 0.52;
            using (session.PushBlurLayer(blurR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                foreach (Stream s in _streams)
                {
                    if (s.Pts.Length < 2) continue;
                    FillRibbon(session, s, s.GlowStops, s.Solid.ToWhite(0.26), bloomOpacity);
                }
            }
        }

        // PASS 2 — INK BODY (opaque source-over).
        double bodyOpacity = dark ? 0.96 : 0.95;
        session.Blend = SubstrateBlend.Normal;
        foreach (Stream s in _streams)
        {
            if (s.Pts.Length < 2) continue;
            FillRibbon(session, s, s.Stops, s.Solid, bodyOpacity);
        }
        foreach (Stream s in _streams)
        {
            if (s.Pts.Length >= 2) continue;
            Vec2 p = s.Pts[0];
            double rr = nibW * 0.34;
            session.FillCircle(p.X, p.Y, rr, s.Solid);
        }

        // PASS 3 — SATIN SHEEN along the crease.
        double sheenW = System.Math.Max(0.6, nibW * 0.16);
        if (dark)
        {
            Rgba sheenInk = new Rgba(1, 1, 1).Mix(frame.Stage.Accent2, 0.34);
            session.Blend = SubstrateBlend.Add;
            foreach (Stream s in _streams)
            {
                if (s.Pts.Length < 2) continue;
                double shimmer = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(wave * 1.3 + s.Seed * 2.2);
                double a = 0.07 + 0.10 * shimmer;
                session.StrokePolyline(s.CreaseBuf.AsSpan(0, s.Pts.Length),
                    sheenInk.WithOpacity(ClampD(a, 0, 1)), sheenW);
            }
        }
        else
        {
            session.Blend = SubstrateBlend.Normal;
            foreach (Stream s in _streams)
            {
                if (s.Pts.Length < 2) continue;
                double shimmer = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(wave * 1.3 + s.Seed * 2.2);
                double a = 0.05 + 0.06 * shimmer;
                session.StrokePolyline(s.CreaseBuf.AsSpan(0, s.Pts.Length),
                    Rgba.White.WithOpacity(ClampD(a, 0, 1)), sheenW);
            }
        }

        // PASS 4 (dark) — WET-HEAD catchlight.
        if (dark && !reduced && !frame.BatteryThrottled)
        {
            session.Blend = SubstrateBlend.Add;
            foreach (Stream s in _streams)
            {
                int n = s.Pts.Length;
                if (n < 2) continue;
                double up = (wave + s.Seed * 2.0) / 5.0;
                up -= System.Math.Floor(up);
                int vi = System.Math.Min(n - 1, System.Math.Max(0, (int)System.Math.Round(up * (n - 1))));
                Vec2 p = s.Pts[vi];
                double pulse = 0.5 + 0.5 * System.Math.Sin(t * 2 + s.Seed * 4);
                double hr = nibW * 0.5;
                session.FillCircle(p.X, p.Y, hr, frame.Stage.Accent2.WithOpacity(ClampD(0.05 + 0.05 * pulse, 0, 1)));
                double r = nibW * 0.26;
                session.FillCircle(p.X, p.Y, r, Rgba.White.WithOpacity(ClampD(0.12 + 0.07 * pulse, 0, 1)));
            }
        }

        return true;
    }

    // Fill one ribbon body: a per-stream linear gradient when the stream has ≥2 stops
    // and a non-degenerate head→tail axis; otherwise a solid fallback fill. The pass
    // opacity is baked into a scratch stop buffer (no per-frame gradient allocation).
    private void FillRibbon(ISubstrateDrawingSession session, Stream s,
        GradientStop[] baseStops, in Rgba solidFallback, double opacity)
    {
        ReadOnlySpan<Vec2> body = s.BodyBuf.AsSpan(0, s.N * 2);
        bool axis = s.Head.X != s.Tail.X || s.Head.Y != s.Tail.Y;
        if (baseStops.Length >= 2 && axis)
        {
            int m = System.Math.Min(baseStops.Length, _sbuf.Length);
            for (int i = 0; i < m; i++)
            {
                GradientStop g = baseStops[i];
                _sbuf[i] = new GradientStop(g.Location, g.Color.WithOpacity(ClampD(g.Color.A * opacity, 0, 1)));
            }
            session.FillPolygonGradient(body, _sbuf.AsSpan(0, m),
                s.Head.X, s.Head.Y, s.Tail.X, s.Tail.Y);
        }
        else
        {
            session.FillPolygon(body, solidFallback.WithOpacity(opacity));
        }
    }

    // MARK: - Layout

    private void Rebuild(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        _streams.Clear();

        _wob = new double[count];
        for (int i = 0; i < count; i++) _wob[i] = VNoise(i * 0.37, i * 0.91) - 0.5;

        if (count <= 1)
        {
            if (count == 1) _streams.Add(MakeStream(new[] { 0 }, dots, 0, frame.Stage.Accent));
            return;
        }

        SubstrateStructure.Structure s = _structure.Get(dots, 6);
        int[] order = s.Order;
        bool[] breaks = s.Breaks;
        int n = order.Length;
        if (n == 0) return;

        int target = (int)ClampD(System.Math.Round((double)count / 26.0), 5, 16);
        int segLen = System.Math.Max(2, (int)System.Math.Round((double)count / target));

        var current = new List<int>(segLen + 1);
        int seedN = 0;
        for (int k = 0; k < n; k++)
        {
            current.Add(order[k]);
            bool atBreak = k < breaks.Length && breaks[k];
            bool isLast = k == n - 1;
            if (isLast || atBreak || current.Count >= segLen)
            {
                _streams.Add(MakeStream(current.ToArray(), dots, seedN, frame.Stage.Accent));
                seedN++;
                current.Clear();
            }
        }
    }

    private Stream MakeStream(int[] idx, SwarmSubstrateDot[] dots, int seedN, Rgba accent)
    {
        int n = idx.Length;
        double seed = 1 + seedN * 0.6180339887;
        var pts = new Vec2[n];
        var pressure = new double[n];
        var arc = new double[n];

        double len = 0;
        for (int i = 0; i < n; i++)
        {
            SwarmSubstrateDot d = dots[idx[i]];
            pts[i] = new Vec2(d.X, d.Y);
            if (i > 0)
                len += Hypot(pts[i].X - pts[i - 1].X, pts[i].Y - pts[i - 1].Y);
        }

        double acc = 0;
        for (int i = 0; i < n; i++)
        {
            if (i > 0) acc += Hypot(pts[i].X - pts[i - 1].X, pts[i].Y - pts[i - 1].Y);
            double u = len > 0 ? acc / len : 0;
            arc[i] = u;
            double slow = VNoise(u * 2.0 + seed * 1.7, seed);
            double fast = VNoise(u * 6.3 + seed * 0.9, seed + 5.3);
            double pr = 0.5 + 0.62 * slow + 0.16 * (fast - 0.5);
            double endK = System.Math.Min(0.16, 2.0 / System.Math.Max(2, n));
            double e = System.Math.Min(u, 1 - u) / System.Math.Max(1e-3, endK);
            pr *= 0.18 + 0.82 * Smoothstep(0, 1, ClampD(e, 0, 1));
            pressure[i] = ClampD(pr, 0.16, 1.25);
        }

        Rgba solid = (n > 0 ? dots[idx[0]].Rgba : new Rgba(0.8, 0.93, 1)).WithOpacity(1);
        GradientStop[] stops = MakeStops(idx, dots, seed, _builtDark);
        GradientStop[] glowStops = MakeGlowStops(idx, dots, accent);

        return new Stream
        {
            Idx = idx,
            Pts = pts,
            Pressure = pressure,
            Arc = arc,
            Seed = seed,
            Stops = stops,
            GlowStops = glowStops,
            Head = n > 0 ? pts[0] : default,
            Tail = n > 0 ? pts[n - 1] : default,
            Solid = solid,
            BodyBuf = n >= 2 ? new Vec2[2 * n] : Array.Empty<Vec2>(),
            CreaseBuf = new Vec2[n],
            N = n,
        };
    }

    private static GradientStop[] MakeStops(int[] idx, SwarmSubstrateDot[] dots, double seed, bool dark)
    {
        int n = idx.Length;
        if (n < 2) return Array.Empty<GradientStop>();
        int stopCount = System.Math.Min(8, n);
        var outp = new GradientStop[stopCount];
        for (int k = 0; k < stopCount; k++)
        {
            double u = stopCount == 1 ? 0 : (double)k / (stopCount - 1);
            int pi = idx[System.Math.Min(n - 1, (int)System.Math.Round(u * (n - 1)))];
            Rgba raw = dots[pi].Rgba;
            double mood = VNoise(u * 3.1 + seed * 1.3, seed);
            Rgba tone;
            if (dark)
            {
                if (mood > 0.5)
                {
                    var deep = new Rgba(raw.R * 0.5, raw.G * 0.5, raw.B * 0.52 + 8.0 / 255.0);
                    tone = raw.Mix(deep, (mood - 0.5) * 1.4);
                }
                else
                {
                    tone = raw.ToWhite((0.5 - mood) * 0.7);
                }
            }
            else
            {
                if (mood > 0.5)
                {
                    var deep = new Rgba(raw.R * 0.32, raw.G * 0.30, raw.B * 0.36 + 6.0 / 255.0);
                    tone = raw.Mix(deep, (mood - 0.5) * 1.5);
                }
                else
                {
                    var midC = new Rgba(raw.R * 0.60, raw.G * 0.60, raw.B * 0.66 + 10.0 / 255.0);
                    tone = raw.Mix(midC, (0.5 - mood) * 0.9);
                }
            }
            outp[k] = new GradientStop(u, tone.WithOpacity(1));
        }
        return outp;
    }

    private static GradientStop[] MakeGlowStops(int[] idx, SwarmSubstrateDot[] dots, Rgba accent)
    {
        int n = idx.Length;
        if (n < 2) return Array.Empty<GradientStop>();
        int stopCount = System.Math.Min(8, n);
        var outp = new GradientStop[stopCount];
        for (int k = 0; k < stopCount; k++)
        {
            double u = stopCount == 1 ? 0 : (double)k / (stopCount - 1);
            int pi = idx[System.Math.Min(n - 1, (int)System.Math.Round(u * (n - 1)))];
            Rgba raw = dots[pi].Rgba;
            double mood = VNoise(u * 3.1 + 7.0, 2.0);
            Rgba lit = raw.ToWhite(0.22 + 0.16 * mood).Mix(accent, 0.16);
            outp[k] = new GradientStop(u, lit.WithOpacity(1));
        }
        return outp;
    }

    private static double Hypot(double a, double b) => System.Math.Sqrt(a * a + b * b);

    // Self-contained coherent value noise (deterministic), ported from the Swift
    // integer-hash flavour used only by Silk Streamline.
    private static double VHash(int ix, int iy)
    {
        uint h = unchecked((uint)ix * 374761393u + (uint)iy * 668265263u);
        h = unchecked((h ^ (h >> 13)) * 1274126177u);
        h ^= h >> 16;
        return (h % 100000u) / 100000.0;
    }

    private static double VNoise(double x, double y)
    {
        int ix = (int)System.Math.Floor(x), iy = (int)System.Math.Floor(y);
        double fx = x - ix, fy = y - iy;
        double ux = fx * fx * (3 - 2 * fx);
        double uy = fy * fy * (3 - 2 * fy);
        double a = VHash(ix, iy), b = VHash(ix + 1, iy);
        double c = VHash(ix, iy + 1), d = VHash(ix + 1, iy + 1);
        return Lerp(Lerp(a, b, ux), Lerp(c, d, ux), uy);
    }
}
