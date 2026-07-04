using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Dendritic Frost — faithful C# port of Swift
/// <c>Views/Substrate/Constellation/RimefrostSubstrate.swift</c> (port of imaginethat
/// <c>constellation/rimefrost.ts</c>, held "melt 0" look). Each silhouette point
/// nucleates a six-armed rime crystal, drawn in depth-ordered passes so it reads as
/// luminous frost spreading across cold glass.
/// </summary>
/// <remarks>
/// (0) DARK deep Gaussian under-wash — every crystal's own brand color, lightly iced,
/// filled additively into one blurred layer so each cluster glows in its hue.
/// (1) icy BODY bloom — a cached white-blue frost radial per crystal, tinted to the
/// dot's brand color (via <see cref="ISubstrateDrawingSession.DrawGlowSprite"/>'s
/// tint), with a smaller untinted white-blue sheen cap on top. (2) SIX dendrite arms —
/// 3 tapering spines + two forward side-branches each, batched per alpha-bin ×
/// width-group into a handful of line batches. (3) hot frozen CORE. (4) near-white
/// frost GLINT cross on the brightest seeds (dark). Crystals grow &amp; melt on a slow
/// <c>sin(0.5·t + seed·τ + posPhase)</c> wave under an imperceptible global rotation
/// (<c>t·0.03</c>). <c>reduced</c> holds a poised grown frost-field; <c>batteryThrottled</c>
/// drops only the heaviest under-wash pass.
/// </remarks>
public sealed class RimefrostSubstrate : ISwarmSubstrate
{
    private const int Bins = 4;
    private static readonly double[] Widths = { 1.5, 0.9, 0.4, 0.55 }; // spine0,1,2, branches

    // Frost sprite center color (white-blue) — the untinted cap tint.
    private static readonly Rgba FrostSprite = new(232.0 / 255, 244.0 / 255, 1.0);

    private readonly struct Crystal
    {
        public readonly double X, Y, Grow, G, Radius, BaseRot, Seed, Seed2, Br, BodyA, CoreSheenA;
        public readonly Rgba Frost, Glow, BodyTint;
        public Crystal(double x, double y, double grow, double g, double radius, double baseRot,
            double seed, double seed2, double br, double bodyA, double coreSheenA,
            in Rgba frost, in Rgba glow, in Rgba bodyTint)
        {
            X = x; Y = y; Grow = grow; G = g; Radius = radius; BaseRot = baseRot;
            Seed = seed; Seed2 = seed2; Br = br; BodyA = bodyA; CoreSheenA = coreSheenA;
            Frost = frost; Glow = glow; BodyTint = bodyTint;
        }
    }

    private readonly List<Crystal> _crystals = new();
    private readonly List<LineSegment>[][] _armPaths;
    private readonly double[] _binR = new double[Bins];
    private readonly double[] _binG = new double[Bins];
    private readonly double[] _binB = new double[Bins];
    private readonly double[] _binA = new double[Bins];
    private readonly int[] _binN = new int[Bins];
    private readonly List<LineSegment> _glint = new();

    private readonly struct Core
    {
        public readonly double X, Y, R;
        public readonly Rgba Rgba;
        public Core(double x, double y, double r, in Rgba rgba) { X = x; Y = y; R = r; Rgba = rgba; }
    }
    private readonly List<Core> _cores = new();

    public RimefrostSubstrate()
    {
        _armPaths = new List<LineSegment>[Bins][];
        for (int b = 0; b < Bins; b++)
        {
            _armPaths[b] = new List<LineSegment>[4];
            for (int w = 0; w < 4; w++) _armPaths[b][w] = new List<LineSegment>();
        }
    }

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
        Rgba accent = frame.Stage.Accent;

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.45 + 0.55;

        double spacing = frame.CloudRadius / System.Math.Max(2.0, System.Math.Sqrt(count));
        double armCap = ClampD(spacing * 0.42, sizePx * 2.4, sizePx * 6);
        double armMin = ClampD(spacing * 0.16, sizePx * 1.2, armCap);
        double spin = reduced ? 0.0 : t * 0.03;

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        const double iceR = 224.0 / 255, iceG = 238.0 / 255, iceB = 1.0;
        var ice = new Rgba(iceR, iceG, iceB, 1);

        // ── precompute per-crystal state once (shared by every pass) ──
        _crystals.Clear();
        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            double seed = Shash(i * 1.37 + 0.5);
            double seed2 = Shash(i * 2.91 + 7.3);

            double phase = seed * Tau + (x * 0.012 + y * 0.016);
            double grow = reduced ? 0.84 + 0.12 * System.Math.Sin(seed * 9.1)
                                  : 0.5 + 0.5 * System.Math.Sin(t * 0.5 + phase);
            double g = ClampD(0.22 + grow * grow * 0.78, 0, 1) * f;

            Rgba c = d.Rgba;
            var frost = new Rgba(c.R + (iceR - c.R) * 0.55, c.G + (iceG - c.G) * 0.55, c.B + (iceB - c.B) * 0.60, 1);
            Rgba glow = c.Mix(ice, 0.16).Mix(accent, 0.10);
            Rgba bodyTint = c.Mix(ice, 0.28).ToWhite(0.08);

            double radius = Lerp(armMin, armCap, 0.45 + seed2 * 0.55) * (0.6 + 0.4 * grow);
            double br = (sizePx * 2.8 + radius * 0.52) * (0.72 + 0.28 * grow);
            double bodyBase = dark ? (throttled ? 0.54 : 0.42) : 0.26;
            double bodyA = ClampD(bodyBase * (0.5 + g), 0, dark ? 0.74 : 0.50);
            double coreSheenA = dark ? ClampD(0.34 * (0.45 + g), 0, 0.6) : ClampD(0.13 * (0.4 + g), 0, 0.22);

            _crystals.Add(new Crystal(x, y, grow, g, radius, spin + seed * Tau, seed, seed2, br, bodyA, coreSheenA,
                frost, glow, bodyTint));
        }

        // ── 0. DEEP GAUSSIAN UNDER-WASH (dark, premium presence) ──
        if (dark && !throttled)
        {
            using (session.PushBlurLayer(sizePx * 2.4, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                foreach (Crystal c in _crystals)
                {
                    double r = (sizePx * 2.0 + c.Radius * 0.40) * (0.7 + 0.3 * c.Grow);
                    double a = ClampD(0.44 * c.G, 0, 0.7);
                    session.FillCircle(c.X, c.Y, r, c.Glow.WithOpacity(a));
                }
            }
            session.Blend = SubstrateBlend.Add;
        }

        // ── 1. body bloom — cached frost sprite tinted to the dot's brand color ──
        foreach (Crystal c in _crystals)
        {
            session.DrawGlowSprite(c.X, c.Y, c.Br, c.BodyTint, c.BodyA);
            double wr = c.Br * 0.42;
            session.DrawGlowSprite(c.X, c.Y, wr, FrostSprite, c.CoreSheenA);
        }

        // ── 2. six feathery dendrite spines (batched by alpha × width-group) ──
        for (int b = 0; b < Bins; b++)
        {
            for (int w = 0; w < 4; w++) _armPaths[b][w].Clear();
            _binR[b] = _binG[b] = _binB[b] = _binA[b] = 0;
            _binN[b] = 0;
        }
        _glint.Clear();
        double glintA = 0.0;
        int glintN = 0;
        _cores.Clear();

        double armAlphaBase = dark ? 0.40 : 0.30;
        for (int i = 0; i < count; i++)
        {
            Crystal c = _crystals[i];
            double x = c.X, y = c.Y, grow = c.Grow, g = c.G;
            double radius = c.Radius, baseRot = c.BaseRot, seed = c.Seed, seed2 = c.Seed2;

            double armAlpha = ClampD(armAlphaBase * g, 0, 0.66);
            if (armAlpha > 0.01 && radius > sizePx * 0.55)
            {
                int bin = System.Math.Min(Bins - 1, (int)(armAlpha / 0.66 * Bins));
                double r0 = radius * grow;
                for (int a = 0; a < 6; a++)
                {
                    double jitter = (Shash(i * 3.1 + a * 1.7) - 0.5) * 0.18;
                    double ang = baseRot + a / 6.0 * Tau + jitter;
                    double ca = System.Math.Cos(ang), sa = System.Math.Sin(ang);
                    double x45 = x + ca * r0 * 0.45, y45 = y + sa * r0 * 0.45;
                    double x78 = x + ca * r0 * 0.78, y78 = y + sa * r0 * 0.78;
                    double x100 = x + ca * r0, y100 = y + sa * r0;
                    _armPaths[bin][0].Add(new LineSegment(x, y, x45, y45));
                    _armPaths[bin][1].Add(new LineSegment(x45, y45, x78, y78));
                    _armPaths[bin][2].Add(new LineSegment(x78, y78, x100, y100));
                    double perpC = -sa, perpS = ca, fwd = 0.5;
                    for (int bI = 0; bI < 2; bI++)
                    {
                        double along = (bI == 0 ? 0.42 : 0.66) * r0;
                        double bx = x + ca * along, by = y + sa * along;
                        double blen = r0 * (0.2 - bI * 0.06) * (0.7 + seed2 * 0.6);
                        _armPaths[bin][3].Add(new LineSegment(bx, by,
                            bx + (perpC * 0.83 + ca * fwd) * blen, by + (perpS * 0.83 + sa * fwd) * blen));
                        _armPaths[bin][3].Add(new LineSegment(bx, by,
                            bx + (-perpC * 0.83 + ca * fwd) * blen, by + (-perpS * 0.83 + sa * fwd) * blen));
                    }
                }
                _binR[bin] += c.Frost.R; _binG[bin] += c.Frost.G; _binB[bin] += c.Frost.B;
                _binA[bin] += armAlpha; _binN[bin]++;
            }

            // ── 3. bright frozen core — the legible silhouette point ──
            double coreA = ClampD((dark ? 0.94 : 0.96) * f * (0.7 + 0.3 * g), 0, 1);
            double fr = c.Frost.R, fg = c.Frost.G, fb = c.Frost.B;
            Rgba coreCol = dark
                ? new Rgba(fr + (1 - fr) * 0.55, fg + (1 - fg) * 0.55, fb + (1 - fb) * 0.50, coreA)
                : dots[i].Rgba.WithOpacity(coreA);
            _cores.Add(new Core(x, y, System.Math.Max(0.9, sizePx * 0.7), coreCol));

            // ── 4. frost glint for the brightest seeds (dark only) ──
            if (dark && seed > 0.86)
            {
                double tw = reduced ? 0.5 : 0.5 + 0.5 * System.Math.Sin(t * 2.2 + seed * 31);
                double len = sizePx * (1.7 + 1.5 * tw);
                double ga = baseRot * 0.5;
                double cga = System.Math.Cos(ga), sga = System.Math.Sin(ga);
                double cga2 = System.Math.Cos(ga + System.Math.PI / 2), sga2 = System.Math.Sin(ga + System.Math.PI / 2);
                _glint.Add(new LineSegment(x - cga * len, y - sga * len, x + cga * len, y + sga * len));
                _glint.Add(new LineSegment(x - cga2 * len, y - sga2 * len, x + cga2 * len, y + sga2 * len));
                glintA += ClampD(0.34 * g * (0.4 + tw), 0, 0.55);
                glintN++;
            }
        }

        // ── batched arm strokes: ≤ bins × 4 batches total ──
        for (int bin = 0; bin < Bins; bin++)
        {
            if (_binN[bin] <= 0) continue;
            double nb = _binN[bin];
            var col = new Rgba(_binR[bin] / nb, _binG[bin] / nb, _binB[bin] / nb, _binA[bin] / nb);
            for (int wg = 0; wg < 4; wg++)
            {
                List<LineSegment> segs = _armPaths[bin][wg];
                if (segs.Count == 0) continue;
                session.DrawLineBatch(CollectionsMarshal.AsSpan(segs), col, Widths[wg]);
            }
        }

        // ── cores on top ──
        foreach (Core core in _cores)
            session.FillCircle(core.X, core.Y, core.R, core.Rgba);

        // ── one batched glint stroke (near-white) ──
        if (glintN > 0)
        {
            var glintCol = new Rgba(244.0 / 255, 250.0 / 255, 1.0, glintA / glintN);
            session.DrawLineBatch(CollectionsMarshal.AsSpan(_glint), glintCol, 0.7);
        }

        return true;
    }
}
