using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Silk Filament — faithful C# port of Swift
/// <c>Views/Substrate/Volumetric/SilkFilamentSubstrate.swift</c> (port of imaginethat
/// <c>volumetric/silk-filament.ts</c>). The whole mark is ONE continuous spider-silk
/// strand threaded through every silhouette point in nearest-neighbour order (via
/// <see cref="SubstrateStructure"/>), so the logo reads as a single living thread of
/// light — hence <see cref="SuppressesGlyphs"/> = true.
/// </summary>
/// <remarks>
/// The thread is mostly dim; a soft travelling GLINT (two wrapped gaussian lobes in
/// arc-length) rakes down its length, igniting a few segments at a time. Colour is a
/// 24-step OKLab altitude ramp (cyan foot → rose crown) woven with the brand accents,
/// baked once per palette change into <c>rampCore</c> (bloom/dim), <c>rampHot</c>
/// (near-white where the rake hits, dark core) and <c>rampInk</c> (light-page strand).
/// Transverse SILK SWAY nudges each vertex along its local normal; long NN leaps are
/// BROKEN so gaps read as gaps. Three depth layers: a TRUE Gaussian bloom (dark), a
/// soft body halo, and the crisp CORE — all bucketed by (altitude hue × quantized rake
/// band) into ONE geometry set per bucket, stroked a few times so the glint stays
/// smooth while stroke calls stay ≤ a few hundred. <c>reduced</c> parks the rake mid-
/// strand and zeroes the sway; <c>batteryThrottled</c> drops only the Gaussian bloom.
/// </remarks>
public sealed class SilkFilamentSubstrate : ISwarmSubstrate
{
    private static readonly Rgba Foot = new(96.0 / 255, 214.0 / 255, 255.0 / 255);  // cyan
    private static readonly Rgba Crown = new(255.0 / 255, 168.0 / 255, 196.0 / 255); // rose
    private const int RampSteps = 24;
    private const int RakeBands = 10;
    private const double BandWidth = 0.14;

    private readonly SubstrateStructure _structure = new();

    private Rgba[] _rampCore = Array.Empty<Rgba>();
    private Rgba[] _rampHot = Array.Empty<Rgba>();
    private Rgba[] _rampInk = Array.Empty<Rgba>();
    private ulong _bakedKey = ulong.MaxValue;

    private double[] _px = Array.Empty<double>();
    private double[] _py = Array.Empty<double>();
    private double[] _sArc = Array.Empty<double>();
    private int[] _hueIdx = Array.Empty<int>();
    private bool[] _brk = Array.Empty<bool>();

    private List<LineSegment>[]? _coreBuckets;

    public bool SuppressesGlyphs => true;

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        double t = frame.T;
        SubstrateStage stage = frame.Stage;
        double sizePx = frame.SizePx;

        EnsureRamp(stage.Accent, stage.Accent2);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        if (count < 2)
        {
            DrawSeed(frame, session);
            return true;
        }

        SubstrateStructure.Structure s = _structure.Get(dots, 6);
        int[] order = (s.Order.Length == count && AllInRange(s.Order, count)) ? s.Order : Identity(count);

        if (_px.Length != count)
        {
            _px = new double[count]; _py = new double[count]; _sArc = new double[count];
            _hueIdx = new int[count]; _brk = new bool[count];
        }

        double formGate = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.5 + 0.5;
        double baseDim = dark ? 0.24 : 0.36;
        double invR = frame.CloudRadius > 0 ? 1.0 / frame.CloudRadius : 0.0;
        double cy = frame.Cy;

        double rakePhase = reduced ? 0.0 : Frac(t * 0.07);
        double p1 = reduced ? 0.5 : rakePhase;
        double p2 = reduced ? 0.18 : Frac(rakePhase * 0.6 + 0.37);

        double spacing = System.Math.Max(2.0, frame.CloudRadius / System.Math.Max(1.0, System.Math.Sqrt(count)));
        double sway = reduced ? 0.0 : System.Math.Min(spacing * 0.3, frame.CloudRadius * 0.035);

        // ── PASS A: lay out vertices, arc-length, altitude hue (un-swayed first) ──
        double prevX = 0.0, prevY = 0.0, total = 0.0;
        for (int step = 0; step < count; step++)
        {
            SwarmSubstrateDot d = dots[order[step]];
            double bx = d.X, by = d.Y;
            _px[step] = bx; _py[step] = by;
            if (step == 0) { _sArc[step] = 0; }
            else
            {
                double dx = bx - prevX, dy = by - prevY;
                total += System.Math.Sqrt(dx * dx + dy * dy);
                _sArc[step] = total;
            }
            double ay = ClampD(0.5 - (by - cy) * invR * 0.5, 0, 1);
            _hueIdx[step] = System.Math.Min(RampSteps - 1, System.Math.Max(0, (int)(ay * (RampSteps - 1) + 0.5)));
            prevX = bx; prevY = by;
        }
        double arcTotal = total > 0 ? total : 1;
        double invArc = 1.0 / arcTotal;
        for (int step = 0; step < count; step++) _sArc[step] *= invArc;

        double meanStep = total / System.Math.Max(1, count - 1);
        double breakThresh = System.Math.Max(meanStep * 3.2, spacing * 4);
        _brk[0] = true;
        for (int step = 1; step < count; step++)
        {
            double segLen = (_sArc[step] - _sArc[step - 1]) * arcTotal;
            _brk[step] = segLen > breakThresh;
        }

        if (sway > 0)
        {
            for (int step = 0; step < count; step++)
            {
                double sParam = _sArc[step];
                int a = step > 0 ? step - 1 : step;
                int c2 = step < count - 1 ? step + 1 : step;
                double tx = _px[c2] - _px[a];
                double ty = _py[c2] - _py[a];
                double tl = System.Math.Sqrt(tx * tx + ty * ty);
                if (tl > 0) { tx /= tl; ty /= tl; }
                double nx = -ty, ny = tx;
                double shimmer = System.Math.Sin(sParam * 9 + t * 1.1) * 0.7 + System.Math.Sin(sParam * 21 - t * 0.7) * 0.3;
                double off = shimmer * sway;
                _px[step] += nx * off;
                _py[step] += ny * off;
            }
        }

        // ── geometry constants ──
        bool tiny = frame.CloudRadius < 56;
        double wCore = ClampD(sizePx * 0.6, 0.7, 1.6);
        double wBody = System.Math.Max(1.0, sizePx) * 1.9;
        double wHalo = System.Math.Max(1.0, sizePx) * 3.2;
        double wBloom = System.Math.Max(1.5, sizePx) * 4.0;
        double bloomR = ClampD(sizePx * 2.8, 6, 14);
        double coreMax = dark ? 1.0 : 0.92;
        bool drawBloom = dark && !tiny && !throttled;
        bool drawHalo = dark && !tiny;

        // ── PASS B: bucket segments by (altitude hue × rake band) ──
        int nBuckets = RampSteps * RakeBands;
        if (_coreBuckets == null || _coreBuckets.Length != nBuckets)
        {
            _coreBuckets = new List<LineSegment>[nBuckets];
            for (int i = 0; i < nBuckets; i++) _coreBuckets[i] = new List<LineSegment>();
        }
        else
        {
            for (int i = 0; i < nBuckets; i++) _coreBuckets[i].Clear();
        }

        for (int step = 1; step < count; step++)
        {
            if (_brk[step]) continue;
            double sMid = (_sArc[step - 1] + _sArc[step]) * 0.5;
            double rk = RakeAt(sMid, p1, p2);
            double lit = ClampD(baseDim + rk, 0, 1.35) * formGate;
            if (lit <= 0.02) continue;
            int band = System.Math.Min(RakeBands - 1, System.Math.Max(0, (int)(rk / BandWidth)));
            int bucket = _hueIdx[step] * RakeBands + band;
            _coreBuckets[bucket].Add(new LineSegment(_px[step - 1], _py[step - 1], _px[step], _py[step]));
        }

        (double rk, double lit) BandLit(int band)
        {
            double rkRep = (band + 0.5) * BandWidth;
            return (rkRep, ClampD(baseDim + rkRep, 0, 1.35) * formGate);
        }

        // ── DEPTH PASS 1: true GAUSSIAN bloom ──
        if (drawBloom)
        {
            using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int hi = 0; hi < RampSteps; hi++)
                {
                    Rgba cBloom = _rampCore[hi];
                    for (int band = 0; band < RakeBands; band++)
                    {
                        int bucket = hi * RakeBands + band;
                        if (_coreBuckets[bucket].Count == 0) continue;
                        (double rkRep, double litRep) = BandLit(band);
                        double ab = ClampD(litRep * 0.5, 0, 0.8);
                        if (ab <= 0.01) continue;
                        session.DrawLineBatch(CollectionsMarshal.AsSpan(_coreBuckets[bucket]),
                            cBloom.WithOpacity(ab), wBloom * (0.8 + 0.6 * rkRep));
                    }
                }
            }
            session.Blend = SubstrateBlend.Add;
        }

        // ── DEPTH PASS 2: soft body halo ──
        double throttleBoost = (throttled && dark) ? 1.5 : 1.0;
        for (int hi = 0; hi < RampSteps; hi++)
        {
            Rgba cHalo = _rampCore[hi];
            for (int band = 0; band < RakeBands; band++)
            {
                int bucket = hi * RakeBands + band;
                if (_coreBuckets[bucket].Count == 0) continue;
                (double rkRep, double litRep) = BandLit(band);
                if (dark)
                {
                    if (!drawHalo) continue;
                    double ah = ClampD(litRep * 0.34 * throttleBoost, 0, 0.6);
                    if (ah <= 0.01) continue;
                    session.DrawLineBatch(CollectionsMarshal.AsSpan(_coreBuckets[bucket]),
                        cHalo.WithOpacity(ah), wHalo * (0.7 + 0.5 * rkRep) * throttleBoost);
                }
                else
                {
                    double ah = ClampD(litRep * 0.16, 0, 0.28);
                    if (ah <= 0.01) continue;
                    session.DrawLineBatch(CollectionsMarshal.AsSpan(_coreBuckets[bucket]),
                        cHalo.WithOpacity(ah), wBody * (0.8 + 0.4 * rkRep));
                }
            }
        }

        // ── DEPTH PASS 3: the crisp CORE on top ──
        for (int hi = 0; hi < RampSteps; hi++)
        {
            for (int band = 0; band < RakeBands; band++)
            {
                int bucket = hi * RakeBands + band;
                if (_coreBuckets[bucket].Count == 0) continue;
                (double rkRep, double litRep) = BandLit(band);
                Rgba cCore = dark ? (rkRep > 0.18 ? _rampHot[hi] : _rampCore[hi]) : _rampInk[hi];
                double alpha = ClampD(litRep * (dark ? 0.95 : 0.9), 0, coreMax);
                if (alpha <= 0.01) continue;
                double width = tiny ? System.Math.Max(0.7, wCore * 0.9) : wCore * (1 + 0.6 * rkRep);
                session.DrawLineBatch(CollectionsMarshal.AsSpan(_coreBuckets[bucket]),
                    cCore.WithOpacity(alpha), width);
            }
        }

        return true;
    }

    private static bool AllInRange(int[] arr, int count)
    {
        foreach (int v in arr) if (v < 0 || v >= count) return false;
        return true;
    }

    private static int[] Identity(int count)
    {
        var a = new int[count];
        for (int i = 0; i < count; i++) a[i] = i;
        return a;
    }

    // ── Rake: two travelling gaussian lobes wrapped on the unit circle ──
    private static double RakeAt(double s, double p1, double p2)
    {
        double g1 = Gauss(CircDist(s, p1), 0.075) * 0.95;
        double g2 = Gauss(CircDist(s, p2), 0.05) * 0.4;
        return g1 + g2;
    }

    private static double Gauss(double d, double sigma)
    {
        double x = d / sigma;
        return System.Math.Exp(-x * x);
    }

    private static double CircDist(double a, double b)
    {
        double d = System.Math.Abs(a - b);
        if (d > 0.5) d = 1 - d;
        return d;
    }

    private void DrawSeed(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot d = frame.Dots[0];
        bool dark = frame.Dark;
        double k = frame.Reduced ? 0.9 : 0.7 + 0.3 * (0.5 + 0.5 * System.Math.Sin(frame.T * 1.2));
        Rgba glow = _rampCore.Length == 0 ? frame.Stage.Accent : _rampCore[RampSteps >> 1];
        double gr = frame.SizePx * 3 * k;
        if (dark)
        {
            using (session.PushBlurLayer(System.Math.Max(3, frame.SizePx * 2), SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                session.FillCircle(d.X, d.Y, gr, glow.WithOpacity(0.55 * k));
            }
            session.Blend = SubstrateBlend.Add;
        }
        else
        {
            session.FillCircle(d.X, d.Y, gr, glow.WithOpacity(0.22 * k));
        }
        double cr = System.Math.Max(0.8, frame.SizePx * 0.7);
        Rgba core = dark ? Rgba.White.WithOpacity(0.95) : frame.Stage.Ink.WithOpacity(0.85);
        session.FillCircle(d.X, d.Y, cr, core);
    }

    private void EnsureRamp(in Rgba accent, in Rgba accent2)
    {
        ulong key = HashKey(accent.BucketKey, accent2.BucketKey);
        if (key == _bakedKey && _rampCore.Length == RampSteps) return;
        _bakedKey = key;

        Rgba footC = OklabColor.Mix(Foot, accent, 0.4);
        Rgba crownC = OklabColor.Mix(Crown, accent2, 0.4);
        var white = new Rgba(1, 1, 1);

        _rampCore = new Rgba[RampSteps];
        _rampHot = new Rgba[RampSteps];
        _rampInk = new Rgba[RampSteps];
        for (int i = 0; i < RampSteps; i++)
        {
            double tt = i / (double)(RampSteps - 1);
            Rgba c = OklabColor.Mix(footC, crownC, tt);
            _rampCore[i] = c;
            _rampHot[i] = OklabColor.Mix(c, white, 0.72);
            _rampInk[i] = new Rgba(c.R * 0.45, c.G * 0.45, c.B * 0.5);
        }
    }

    private static ulong HashKey(uint a, uint b)
    {
        ulong h = 1469598103934665603UL;
        h = (h ^ a) * 1099511628211UL;
        h = (h ^ b) * 1099511628211UL;
        return h;
    }
}
