using System;
using System.Collections.Generic;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Stellar Plasma — faithful C# port of Swift
/// <c>Views/Substrate/Constellation/StarfireSubstrate.swift</c> (itself a port of
/// imaginethat <c>constellation/starfire.ts</c> drawBody). The flagship
/// Constellation bespoke painter, proving the full Win2D idiom set: additive
/// (<see cref="SubstrateBlend.Add"/>) compositing, a Gaussian-blurred under-glow
/// layer, cached radial glow sprites, chromatic plasma discs, near-white hot
/// cores, and batched diffraction-cross strokes.
/// </summary>
/// <remarks>
/// Each silhouette point is a long-exposure star. On a DARK canvas (additive) every
/// point stacks, in z-order: (0) a deep Gaussian-blurred under-glow wash; (1) a
/// cached white radial-glow bloom; (2) a chromatic plasma disc in the point's own
/// color; (3) a near-white hot core (the legible silhouette point); (4) for the
/// brightest ~20% (seed &gt; 0.8) a slowly-rotating pure-white diffraction cross.
/// On a LIGHT canvas it collapses to a soft colored halo + colored core. Twinkle is
/// brightness/size only — no positional drift — driven purely from <c>frame.T</c> +
/// a per-point seed, with an occasional sharp scintillation flare. <c>reduced</c>
/// freezes to a poised still star-field; <c>batteryThrottled</c> drops the bloom +
/// cross passes. The exact alpha/radius constants ARE the look — they match the
/// Swift original line-for-line.
/// </remarks>
public sealed class StarfireSubstrate : ISwarmSubstrate
{
    private const int CrossTiers = 5;
    private const double CrossAlphaMax = 0.4;

    // Per-instance scratch reused across frames (the substrate is cached by the
    // renderer, so this never re-allocates in the steady state).
    private readonly List<LineSegment>[] _crossTiers;

    public StarfireSubstrate()
    {
        _crossTiers = new List<LineSegment>[CrossTiers];
        for (int i = 0; i < CrossTiers; i++) _crossTiers[i] = new List<LineSegment>(64);
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        // forming gain — settleProgress is the source `formed` (0…1).
        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.5 + 0.5;

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // (0) DEEP GAUSSIAN BLOOM — a real blurred under-glow: each star's color,
        // pushed toward the stage accent and lifted toward white, drawn additively
        // into one blurred layer so the whole field rests in one luminous wash
        // beneath the crisp sprite bloom and hot cores. Heaviest pass → dropped when
        // batteryThrottled (the cached sprite bloom alone still reads richly).
        if (dark && !lite)
        {
            Rgba accent = frame.Stage.Accent;
            double bloomDisc = sizePx * 1.85;
            using (session.PushBlurLayer(sizePx * 2.6, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < count; i++)
                {
                    SwarmSubstrateDot d = dots[i];
                    double seed = Shash(i * 1.37 + 0.5);
                    double k = 0.82 + 0.18 * (reduced ? 0.5 + 0.5 * System.Math.Sin(seed * 19) : System.Math.Sin(t * 1.6 + seed * Tau));
                    if (!reduced)
                    {
                        double s = System.Math.Sin(t * (1.1 + seed) + seed * 7.0);
                        if (s > 0.93) k += (s - 0.93) / 0.07 * 0.7;
                    }
                    k = ClampD(k, 0.35, 1.7) * f;
                    // glow hue: brand color biased to accent, kissed toward white.
                    Rgba glowCol = d.Rgba.Mix(accent, 0.34).ToWhite(0.16);
                    session.FillCircle(d.X, d.Y, bloomDisc, glowCol.WithOpacity(ClampD(0.20 * k, 0, 0.5)));
                }
            }
            session.Blend = SubstrateBlend.Add;
        }

        // Bucketed diffraction-cross paths (dark, brightest ~20%, not throttled).
        for (int i = 0; i < CrossTiers; i++) _crossTiers[i].Clear();
        bool crossUsed = false;

        for (int i = 0; i < count; i++)
        {
            SwarmSubstrateDot d = dots[i];
            double x = d.X, y = d.Y;
            double seed = Shash(i * 1.37 + 0.5);

            // per-star twinkle: gentle breathe + occasional scintillation flare.
            double k = 0.82 + 0.18 * (reduced ? 0.5 + 0.5 * System.Math.Sin(seed * 19) : System.Math.Sin(t * 1.6 + seed * Tau));
            if (!reduced)
            {
                double s = System.Math.Sin(t * (1.1 + seed) + seed * 7.0);
                if (s > 0.93) k += (s - 0.93) / 0.07 * 0.7;
            }
            k = ClampD(k, 0.35, 1.7) * f;

            Rgba col = d.Rgba;

            if (dark)
            {
                // (1) additive white bloom (cached sprite) — skip when throttled.
                if (!lite)
                {
                    double bloomR = sizePx * 3.4 * (0.7 + 0.5 * k);
                    session.DrawGlowSprite(x, y, bloomR, Rgba.White, 0.13 * k);
                }
                // (2) chromatic plasma disc.
                double discR = sizePx * 1.5;
                session.FillCircle(x, y, discR, col.WithOpacity(ClampD(0.30 * k, 0, 0.6)));
                // (3) near-white hot core — the legible silhouette point.
                double coreR = System.Math.Max(0.8, sizePx * 0.62);
                session.FillCircle(x, y, coreR, col.ToWhite(0.6).WithOpacity(ClampD(0.85 * k, 0, 1)));
                // (4) diffraction cross for the brightest ~20%, slowly rotating.
                if (!lite && seed > 0.8)
                {
                    double len = sizePx * (3 + 3 * (k - 0.5));
                    double a = reduced ? seed * Tau : t * 0.05 + seed * Tau;
                    double cx0 = System.Math.Cos(a) * len, cy0 = System.Math.Sin(a) * len;
                    double cx1 = System.Math.Cos(a + System.Math.PI / 2) * len, cy1 = System.Math.Sin(a + System.Math.PI / 2) * len;
                    // per-star spike alpha (source L121) — bin into a tier so the
                    // bright stars keep their flare instead of the field average.
                    double crossA = ClampD(0.16 * k, 0, CrossAlphaMax);
                    int tier = (int)(crossA / CrossAlphaMax * CrossTiers);
                    if (tier >= CrossTiers) tier = CrossTiers - 1;
                    if (tier < 0) tier = 0;
                    _crossTiers[tier].Add(new LineSegment(x - cx0, y - cy0, x + cx0, y + cy0));
                    _crossTiers[tier].Add(new LineSegment(x - cx1, y - cy1, x + cx1, y + cy1));
                    crossUsed = true;
                }
            }
            else
            {
                // LIGHT canvas: soft colored halo + colored core (source-over).
                double haloR = sizePx * 2.2;
                session.FillCircle(x, y, haloR, col.WithOpacity(ClampD(0.16 * k, 0, 0.3)));
                double coreR = System.Math.Max(0.9, sizePx * 0.72);
                session.FillCircle(x, y, coreR, col.WithOpacity(ClampD(0.95 * f, 0, 1)));
            }
        }

        // One batched stroke per alpha tier — preserves per-star spike twinkle
        // (white, additive) without a stroke call per dot.
        if (crossUsed)
        {
            for (int tier = 0; tier < CrossTiers; tier++)
            {
                List<LineSegment> segs = _crossTiers[tier];
                if (segs.Count == 0) continue;
                double a = (tier + 0.5) / CrossTiers * CrossAlphaMax;
                session.DrawLineBatch(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(segs), Rgba.White.WithOpacity(a), 0.8);
            }
        }

        return true;
    }
}
