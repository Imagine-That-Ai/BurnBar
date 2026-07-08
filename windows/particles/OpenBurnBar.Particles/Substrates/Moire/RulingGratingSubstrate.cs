using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Moire;

/// <summary>
/// Ruling Grating — faithful C# port of Swift
/// <c>Views/Substrate/Moire/RulingGratingSubstrate.swift</c>. The only INK / line
/// idiom in the family: the mark is engraved as a diffraction grating. Every
/// silhouette point becomes a short oriented ink stroke at ruling angle A; a SECOND
/// ruling (angle B = A + drift) is drawn over it. Where the two rulings phase-align
/// they thicken and brighten into classic line-on-line moiré beat-bands (the product
/// of two crossed cosines, sharpened to crisp ruled fringes). As drift breathes and
/// a scroll term crawls the dark fringes, the hatch ripples like watered silk.
/// </summary>
/// <remarks>
/// DARK layers three lights: a TRUE GAUSSIAN BLOOM of the bright crossing strokes;
/// the saturated body ruling; a hot near-white core on the brightest crossings.
/// LIGHT is crisp opaque ink. In the SPARSE Atelier free-swarm two continuous ruling
/// FAMILIES are struck edge-to-edge across the canvas (their real crossing IS the
/// moiré field), feathered into the swarm by a radial alpha mask
/// (<see cref="ISubstrateDrawingSession.PushRadialMaskLayer"/>). Strokes are batched
/// into one <see cref="ISubstrateDrawingSession.DrawLineBatch"/> per (brightness-band,
/// colour-bucket) so the whole field is a few dozen stroke calls, not thousands.
/// Owns the whole silhouette → suppresses the glyph pass. The exact constants ARE
/// the look.
/// </remarks>
public sealed class RulingGratingSubstrate : ISwarmSubstrate
{
    private const int Bands = 6;
    private const int ColorBuckets = 125;

    public bool SuppressesGlyphs => true;

    private sealed class Buckets
    {
        public readonly Dictionary<int, List<LineSegment>> Body = new();
        public readonly Dictionary<int, double> BodySumA = new();
        public readonly Dictionary<int, int> BodyN = new();
        public readonly Dictionary<int, Rgba> BodyColor = new();
        public readonly Dictionary<int, List<LineSegment>> Bloom = new();
        public readonly Dictionary<int, double> BloomSumS = new();
        public readonly Dictionary<int, int> BloomN = new();
        public readonly Dictionary<int, Rgba> BloomColor = new();
        public readonly List<LineSegment> Core = new();
        public bool HasCore;
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        double radius = frame.CloudRadius;
        if (count == 0 || radius <= 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttled = frame.BatteryThrottled;
        double t = frame.T;
        double cx = frame.Cx, cy = frame.Cy;
        double sizePx = frame.SizePx;
        Rgba accent = frame.Stage.Accent;
        Rgba accent2 = frame.Stage.Accent2;
        Rgba ink = frame.Stage.Ink;
        Rgba white = Rgba.White;

        double baseAngle = -22.0 * System.Math.PI / 180.0;
        double restDrift = 7.0 * System.Math.PI / 180.0;
        double breath = reduced ? 0 : System.Math.Sin(t * 0.55) * 3.2 * System.Math.PI / 180.0;
        double drift = restDrift + breath;
        double driftedAngle = baseAngle + drift;
        double cosA = System.Math.Cos(baseAngle), sinA = System.Math.Sin(baseAngle);
        double cosB = System.Math.Cos(driftedAngle), sinB = System.Math.Sin(driftedAngle);
        double nAx = -sinA, nAy = cosA;
        double nBx = -sinB, nBy = cosB;
        double pitch = ClampD(sizePx * 5.5, 9.0, 15.0);
        double kA = Tau / pitch;
        double kB = kA;
        double scroll = reduced ? 0 : t * 0.6;

        double seg = ClampD(sizePx * 2.2, 2.6, 6.4);
        double baseW = ClampD(sizePx * 0.55, 0.8, 1.6);
        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.5 + 0.5;

        int inShapeN = 0;
        for (int i = 0; i < count; i++) if (dots[i].InShape) inShapeN++;
        double shapeFrac = (double)inShapeN / count;
        double fieldW = frame.IsShapeMode ? 0.0 : 1.0 - ClampD((shapeFrac - 0.25) / 0.45, 0, 1);

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        double Beat(double x, double y)
        {
            double lx = x - cx, ly = y - cy;
            double pa = (lx * nAx + ly * nAy) * kA + scroll;
            double pb = (lx * nBx + ly * nBy) * kB - scroll * 0.8;
            double m0 = 0.5 + 0.5 * System.Math.Cos(pa) * System.Math.Cos(pb);
            double m1 = m0 * m0 * (3 - 2 * m0);
            return Smoothstep(0.22, 0.96, m1);
        }
        double Twinkle(double x, double y, int i)
        {
            if (reduced) return 1;
            double s = Shash(i * 1.27 + 0.31);
            return 0.86 + 0.14 * System.Math.Sin(t * 1.4 + s * Tau + x * 0.02 + y * 0.015);
        }

        const double troughFloor = 0.16;
        const double beatAmp = 0.80;
        double foldedFloor = throttled ? 0.16 * form : 0;
        bool wantBloom = dark && !throttled;

        var b = new Buckets();

        // floor pass: faint single ruling at A so the mark is always inked.
        if (!throttled)
        {
            Collect(b, dots, count, dark, wantBloom: false, cosA, sinA, seg * 0.92,
                (x, y, i) => (ClampD(0.16 * form, 0, 1), 0.0));
        }

        (double, double) BeatAlpha(double x, double y, int i)
        {
            double mb = Beat(x, y);
            double a = (troughFloor + beatAmp * mb) * Twinkle(x, y, i) * form + foldedFloor;
            return (ClampD(a, 0, 1), mb);
        }
        Collect(b, dots, count, dark, wantBloom, cosA, sinA, seg, BeatAlpha);
        Collect(b, dots, count, dark, wantBloom, cosB, sinB, seg, BeatAlpha);

        // ── FULL-FIELD MOIRÉ ──
        if (fieldW > 0.004)
        {
            double w = frame.Width, h = frame.Height;
            if (w > 1 && h > 1)
            {
                double ctrX = w * 0.5, ctrY = h * 0.5;
                double shiftA = reduced ? 0 : pitch * Frac(scroll / Tau);
                double shiftB = reduced ? 0 : pitch * Frac(-scroll * 0.8 / Tau);
                var famA = new List<LineSegment>();
                var famB = new List<LineSegment>();
                BuildFamily(cosA, sinA, shiftA, pitch, w, h, ctrX, ctrY, famA);
                BuildFamily(cosB, sinB, shiftB, pitch, w, h, ctrX, ctrY, famB);

                bool freeSwarm = !frame.IsShapeMode;
                double halfDiag = System.Math.Sqrt(w * w + h * h) * 0.5;
                // mask params: alpha 1 within whiteR, feathered to 0 at clearR.
                double maskCx, maskCy, whiteR, clearR;
                if (freeSwarm)
                {
                    maskCx = ctrX; maskCy = ctrY;
                    clearR = halfDiag * 1.12;
                    whiteR = clearR * 0.80;
                }
                else
                {
                    maskCx = cx; maskCy = cy;
                    double mInner = System.Math.Max(24.0, radius * 0.18);
                    double mOuter = System.Math.Max(mInner + 64.0, radius * 1.32);
                    whiteR = mInner; clearR = mOuter;
                }

                double lwF = baseW * (freeSwarm ? 1.28 : 1.0) * (dark ? 1.0 : 0.95);
                double floorMul = freeSwarm ? 1.0 : fieldW;
                double aF = ClampD((dark ? 0.46 : 0.34) * floorMul * form, 0, 1);
                Rgba col1 = dark ? accent : ink;
                Rgba col2 = dark ? accent2 : ink;

                ReadOnlySpan<LineSegment> famASpan = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(famA);
                ReadOnlySpan<LineSegment> famBSpan = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(famB);

                // GLOW · blurred masked copy of both families (dark; heaviest pass).
                if (dark && !throttled)
                {
                    double bloomR = ClampD(pitch * 0.85, 4, 10);
                    session.Blend = SubstrateBlend.Add;
                    using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                    using (session.PushRadialMaskLayer(maskCx, maskCy, whiteR, clearR))
                    {
                        session.Blend = SubstrateBlend.Add;
                        Rgba g1 = col1.Mix(accent, 0.30).ToWhite(0.26);
                        Rgba g2 = col2.Mix(accent, 0.30).ToWhite(0.26);
                        session.DrawLineBatch(famASpan, g1.WithOpacity(aF * 0.72), lwF * 1.9);
                        session.DrawLineBatch(famBSpan, g2.WithOpacity(aF * 0.72), lwF * 1.9);
                    }
                    session.Blend = SubstrateBlend.Add;
                }

                // BODY · the crisp ruling lines themselves — the moiré field proper.
                session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                using (session.PushRadialMaskLayer(maskCx, maskCy, whiteR, clearR))
                {
                    session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                    session.DrawLineBatch(famASpan, col1.WithOpacity(aF), lwF);
                    session.DrawLineBatch(famBSpan, col2.WithOpacity(aF), lwF);
                }
            }
        }

        // ── render the layered light ──
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        if (dark)
        {
            // PASS 1 · TRUE GAUSSIAN BLOOM.
            if (wantBloom && b.Bloom.Count > 0)
            {
                double bloomR = ClampD(seg * 1.6, 5, 12);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    foreach (int key in SortedKeys(b.Bloom))
                    {
                        int lvl = key / ColorBuckets;
                        int nb = b.BloomN.TryGetValue(key, out int bn) ? bn : 1;
                        double sAvg = (b.BloomSumS.TryGetValue(key, out double bs) ? bs : 0) / nb;
                        Rgba baseC = b.BloomColor.TryGetValue(key, out Rgba bc) ? bc : accent;
                        Rgba glow = baseC.Mix(accent, 0.32).ToWhite(0.42);
                        double lw = baseW * (2.0 + lvl * 0.95);
                        session.DrawLineBatch(Span(b.Bloom[key]), glow.WithOpacity(ClampD(sAvg * 0.85, 0, 0.9)), lw);
                    }
                }
                session.Blend = SubstrateBlend.Add;
            }

            // PASS 2 · SATURATED BODY.
            foreach (int key in SortedKeys(b.Body))
            {
                int nb = b.BodyN.TryGetValue(key, out int bn) ? bn : 1;
                double aAvg = (b.BodySumA.TryGetValue(key, out double bs) ? bs : 0) / nb;
                Rgba baseC = b.BodyColor.TryGetValue(key, out Rgba bc) ? bc : accent;
                Rgba col = baseC.ToWhite(0.18 + 0.42 * aAvg);
                double lw = baseW * (0.85 + 1.1 * aAvg);
                session.DrawLineBatch(Span(b.Body[key]), col.WithOpacity(ClampD(aAvg, 0, 1)), lw);
            }

            // PASS 3 · HOT CORE.
            if (b.HasCore)
            {
                Rgba coreCol = white.Mix(accent, 0.16);
                session.DrawLineBatch(Span(b.Core), coreCol.WithOpacity(0.85), baseW * 0.85);
            }
        }
        else
        {
            foreach (int key in SortedKeys(b.Body))
            {
                int nb = b.BodyN.TryGetValue(key, out int bn) ? bn : 1;
                double aAvg = (b.BodySumA.TryGetValue(key, out double bs) ? bs : 0) / nb;
                Rgba baseC = b.BodyColor.TryGetValue(key, out Rgba bc) ? bc : ink;
                Rgba col = baseC.Darkened(0.50 * aAvg);
                double lw = baseW * (0.95 + 1.0 * aAvg);
                double strokeA = ClampD(0.40 + 0.60 * aAvg, 0, 1);
                session.DrawLineBatch(Span(b.Body[key]), col.WithOpacity(strokeA), lw);
            }
        }

        return true;
    }

    private static ReadOnlySpan<LineSegment> Span(List<LineSegment> l)
        => System.Runtime.InteropServices.CollectionsMarshal.AsSpan(l);

    /// <summary>Deterministic key order so the parity checksum + Mac↔Windows render match.</summary>
    private static List<int> SortedKeys(Dictionary<int, List<LineSegment>> d)
    {
        var keys = new List<int>(d.Keys);
        keys.Sort();
        return keys;
    }

    // ── build one continuous ruling family spanning the whole canvas ──
    private static void BuildFamily(double dirCos, double dirSin, double normalOffset,
        double pitch, double w, double h, double centerX, double centerY, List<LineSegment> outSegs)
    {
        if (pitch <= 0.5) return;
        double nx = -dirSin, ny = dirCos;
        double ox = centerX + nx * normalOffset;
        double oy = centerY + ny * normalOffset;
        double ext = System.Math.Abs(w * 0.5 * nx) + System.Math.Abs(h * 0.5 * ny) + pitch;
        double half = System.Math.Sqrt(w * w + h * h) * 0.5 + pitch;
        double p = -ext;
        while (p <= ext)
        {
            double lcx = ox + nx * p, lcy = oy + ny * p;
            outSegs.Add(new LineSegment(lcx - dirCos * half, lcy - dirSin * half,
                                        lcx + dirCos * half, lcy + dirSin * half));
            p += pitch;
        }
    }

    // ── collect one ruling pass into the shared buckets ──
    private static void Collect(Buckets b, SwarmSubstrateDot[] dots, int count, bool dark, bool wantBloom,
        double dirCos, double dirSin, double seg, Func<double, double, int, (double, double)> alpha)
    {
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            (double a, double mb) = alpha(x, y, i);
            if (a < 0.012) continue;

            double j = 0.82 + 0.36 * Shash(i * 0.73 + dirSin * 3.1);
            double half = seg * j;
            double x0 = x - dirCos * half, y0 = y - dirSin * half;
            double x1 = x + dirCos * half, y1 = y + dirSin * half;

            int cb = ColorBucket(d.Rgba);
            int band = System.Math.Min(Bands - 1, System.Math.Max(0, (int)(a * Bands)));
            int key = band * ColorBuckets + cb;
            GetList(b.Body, key).Add(new LineSegment(x0, y0, x1, y1));
            b.BodySumA[key] = (b.BodySumA.TryGetValue(key, out double sa) ? sa : 0) + a;
            b.BodyN[key] = (b.BodyN.TryGetValue(key, out int bn) ? bn : 0) + 1;
            if (!b.BodyColor.ContainsKey(key)) b.BodyColor[key] = d.Rgba;

            if (!dark || mb <= 0) continue;
            double s = Smoothstep(0.46, 1.0, mb);
            if (wantBloom && s > 0.04)
            {
                int lvl = System.Math.Min(2, System.Math.Max(0, (int)(s * 3)));
                int bkey = lvl * ColorBuckets + cb;
                GetList(b.Bloom, bkey).Add(new LineSegment(x0, y0, x1, y1));
                b.BloomSumS[bkey] = (b.BloomSumS.TryGetValue(bkey, out double bsum) ? bsum : 0) + s;
                b.BloomN[bkey] = (b.BloomN.TryGetValue(bkey, out int bnn) ? bnn : 0) + 1;
                if (!b.BloomColor.ContainsKey(bkey)) b.BloomColor[bkey] = d.Rgba;
            }
            if (Smoothstep(0.78, 1.0, mb) > 0.12)
            {
                b.Core.Add(new LineSegment(x0, y0, x1, y1));
                b.HasCore = true;
            }
        }
    }

    private static List<LineSegment> GetList(Dictionary<int, List<LineSegment>> d, int key)
    {
        if (!d.TryGetValue(key, out List<LineSegment>? l)) { l = new List<LineSegment>(); d[key] = l; }
        return l;
    }

    private static int ColorBucket(in Rgba c)
    {
        int qr = System.Math.Min(4, System.Math.Max(0, (int)System.Math.Round(c.R * 4)));
        int qg = System.Math.Min(4, System.Math.Max(0, (int)System.Math.Round(c.G * 4)));
        int qb = System.Math.Min(4, System.Math.Max(0, (int)System.Math.Round(c.B * 4)));
        return qr * 25 + qg * 5 + qb;
    }
}
