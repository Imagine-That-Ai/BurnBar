using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Crepuscular Shafts — faithful C# port of Swift
/// <c>Views/Substrate/Volumetric/SunshaftSubstrate.swift</c> (port of imaginethat
/// <c>volumetric/sunshaft.ts</c>). Each silhouette point is the FOOT of a soft
/// volumetric god-ray: a tall tinted luminance-mask shaft, pre-tinted across a 32-step
/// OKLab accent→accent2 altitude ramp (cyan foot → rose crown). The whole cloud reads
/// as raked by a SINGLE sun: every shaft leans along one slowly-swivelling global light
/// direction (<c>sin(t·0.05)·8°</c>).
/// </summary>
/// <remarks>
/// Compositing &amp; depth (DARK): one soft centered ink radial source-over first (gives
/// additive bloom a field to sum into), then the layered foot light — (2a) a TRUE
/// Gaussian bloom plate of altitude-tinted glows pooled at the locked feet; (2b) the
/// near-white core sprites (the saturated body); (2c) a tiny pure-white hot pinpoint.
/// LIGHT skips the ink/bloom and rides the shafts + saturated cores at a lifted alpha.
/// A per-core crisp definition dot fires every frame. <c>reduced</c> freezes one poised
/// raked still frame; <c>batteryThrottled</c> drops the ink halo AND the bloom plate.
/// The anisotropic tall shaft goes through
/// <see cref="ISubstrateDrawingSession.DrawShaftSprite"/>; the isotropic ink/core/hot/
/// bloom glows through <see cref="ISubstrateDrawingSession.DrawGlowSprite"/>.
/// </remarks>
public sealed class SunshaftSubstrate : ISwarmSubstrate
{
    private const int HueSteps = 32;

    // Per-hue tint LUTs (rebuilt on palette change). Shaft + bloom use the saturated
    // altitude color; the core uses a polarity-aware whitened variant.
    private Rgba[] _rampCols = Array.Empty<Rgba>();  // shaft + bloom-halo tint
    private Rgba[] _coreCols = Array.Empty<Rgba>();   // hot foot (whitened per polarity)
    private ulong _rampKey = ulong.MaxValue;

    // Per-point static attributes (rebuilt on count/geometry change).
    private int _attrCount = -1;
    private double _attrCx, _attrCy, _attrR;
    private int[] _hueIdx = Array.Empty<int>();
    private double[] _seedA = Array.Empty<double>();
    private double[] _lenJit = Array.Empty<double>();
    private bool[] _isCore = Array.Empty<bool>();

    private static readonly Rgba InkColor = new(6.0 / 255, 9.0 / 255, 18.0 / 255, 1);

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;
        EnsureRamp(frame.Stage);
        EnsureAttrs(frame);

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttle = frame.BatteryThrottled;
        double t = frame.T;
        double radius = frame.CloudRadius, cx = frame.Cx, cy = frame.Cy;
        double sizePx = frame.SizePx;

        double env = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.6 + 0.4;

        // one global single-sun direction, swivelling ~8° on a slow sin.
        double swivel = reduced ? 0 : System.Math.Sin(t * 0.05) * (8 * System.Math.PI / 180);
        double baseAng = -System.Math.PI / 2 + swivel;
        double lx = System.Math.Cos(baseAng), ly = System.Math.Sin(baseAng);
        double rot = System.Math.Atan2(lx, -ly);
        double widthBreath = reduced ? 1.0
            : 0.86 + 0.28 * Smootherstep(0, 1, 0.5 + 0.5 * System.Math.Sin(t * (Tau / 1.8)));

        double shaftH = radius * 1.2;
        double shaftW = System.Math.Max(2.0, radius * 0.18);
        double shaftAlpha = dark ? 0.22 : 0.17;
        double coreAlpha = 0.62;

        // ── dark page: soft centered ink field so 'lighter' has somewhere to sum. ──
        if (dark && !throttle)
        {
            double rr = System.Math.Max(radius * 1.9, 1);
            session.Blend = SubstrateBlend.Normal;
            session.DrawGlowSprite(cx, cy, rr, InkColor, ClampD(0.5 * env, 0, 0.6));
        }

        // additive on dark, source-over on light.
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        // ── PASS 1: the SHAFTS — one tall god-ray per point along the light dir. ──
        for (int i = 0; i < count; i++)
        {
            double x = dots[i].X, y = dots[i].Y;
            double sh = _seedA[i];
            double breath = reduced ? 0.62 + 0.2 * System.Math.Sin(sh) : 0.5 + 0.5 * System.Math.Sin(t * 0.3 + sh);
            bool core = _isCore[i];
            double lenK = _lenJit[i] * (core ? 0.62 : 1) * (0.62 + 0.55 * breath) * env;
            double h = shaftH * lenK;
            double w = shaftW * widthBreath * (core ? 0.78 : 1);
            double a = ClampD(shaftAlpha * (0.45 + 0.85 * breath) * env, 0, 0.5);
            if (a <= 0.003 || h <= 0.5) continue;
            session.DrawShaftSprite(x, y, w, h, rot, _rampCols[_hueIdx[i]], a);
        }

        double coreR = System.Math.Max(1.4, sizePx * 1.5);
        double coreD = coreR * 2.4;

        // ── PASS 2a: TRUE GAUSSIAN BLOOM (dark only). ──
        if (dark && !throttle)
        {
            double bloomD = coreR * 6.0;
            double bloomBlur = System.Math.Max(2.5, coreR * 1.4);
            using (session.PushBlurLayer(bloomBlur, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < count; i++)
                {
                    if (!_isCore[i]) continue;
                    double x = dots[i].X, y = dots[i].Y;
                    double k = reduced ? 0.85 : 0.7 + 0.3 * (0.5 + 0.5 * System.Math.Sin(t * 1.4 + _seedA[i]));
                    double a = ClampD(0.55 * k * env, 0, 1);
                    if (a <= 0.004) continue;
                    session.DrawGlowSprite(x, y, bloomD / 2, _rampCols[_hueIdx[i]], a);
                }
            }
            session.Blend = SubstrateBlend.Add;
        }

        // ── PASS 2b: the CORES — the legible silhouette (saturated body). ──
        for (int i = 0; i < count; i++)
        {
            if (!_isCore[i]) continue;
            double x = dots[i].X, y = dots[i].Y;
            double k = reduced ? 0.85 : 0.78 + 0.22 * (0.5 + 0.5 * System.Math.Sin(t * 1.4 + _seedA[i]));
            double a = ClampD(coreAlpha * k * env, 0, 1);
            if (a <= 0.003) continue;
            session.DrawGlowSprite(x, y, coreD / 2, _coreCols[_hueIdx[i]], a);
        }

        // ── PASS 2c: the HOT CORE (dark only) — a tiny pure-white pinpoint. ──
        if (dark)
        {
            double hotD = System.Math.Max(2.4, coreR * 1.7);
            for (int i = 0; i < count; i++)
            {
                if (!_isCore[i]) continue;
                double x = dots[i].X, y = dots[i].Y;
                double k = reduced ? 0.85 : 0.72 + 0.28 * (0.5 + 0.5 * System.Math.Sin(t * 1.4 + _seedA[i]));
                double a = ClampD(0.7 * k * env, 0, 1);
                if (a <= 0.004) continue;
                session.DrawGlowSprite(x, y, hotD / 2, Rgba.White, a);
            }
        }

        // ── PASS 3: crispening — a hard definition dot on each locked core. ──
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        double ca2 = ClampD((dark ? 0.7 : 0.95) * env, 0, 1);
        double dotR = dark ? 0.7 : System.Math.Max(0.9, sizePx * 0.7);
        for (int i = 0; i < count; i++)
        {
            if (!_isCore[i]) continue;
            Rgba c = dots[i].Rgba;
            Rgba tint = new Rgba(c.R, c.G, c.B, 1).ToWhite(dark ? 0.65 : 0.18).WithOpacity(ca2);
            session.FillCircle(dots[i].X, dots[i].Y, dotR, tint);
        }

        return true;
    }

    private void EnsureAttrs(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == _attrCount && frame.Cx == _attrCx && frame.Cy == _attrCy && frame.CloudRadius == _attrR) return;
        _attrCount = count; _attrCx = frame.Cx; _attrCy = frame.Cy; _attrR = frame.CloudRadius;
        _hueIdx = new int[count];
        _seedA = new double[count];
        _lenJit = new double[count];
        _isCore = new bool[count];
        double invR = frame.CloudRadius > 0 ? 1 / frame.CloudRadius : 0;
        int steps = HueSteps;
        for (int i = 0; i < count; i++)
        {
            double ny = (dots[i].Y - frame.Cy) * invR;
            double tt = ClampD(0.5 - ny * 0.5, 0, 1);
            _hueIdx[i] = System.Math.Min(steps - 1, System.Math.Max(0, (int)(tt * (steps - 1) + 0.5)));
            _seedA[i] = Shash(i * 1.37 + 0.5) * Tau;
            _lenJit[i] = 0.7 + 0.6 * Shash(i * 2.71 + 9.1);
            _isCore[i] = Shash(i * 0.917 + 3.3) < 0.38;
        }
    }

    private void EnsureRamp(SubstrateStage stage)
    {
        ulong key = HashKey(stage.Accent.BucketKey, stage.Accent2.BucketKey, stage.Dark);
        if (key == _rampKey && _rampCols.Length == HueSteps) return;
        _rampKey = key;
        var white = new Rgba(1, 1, 1, 1);
        double coreWhiten = stage.Dark ? 0.6 : 0.26;
        _rampCols = new Rgba[HueSteps];
        _coreCols = new Rgba[HueSteps];
        for (int i = 0; i < HueSteps; i++)
        {
            double tt = i / (double)(HueSteps - 1);
            Rgba col = OklabColor.Mix(stage.Accent, stage.Accent2, tt);
            _rampCols[i] = col;
            _coreCols[i] = OklabColor.Mix(col, white, coreWhiten);
        }
    }

    private static ulong HashKey(uint a, uint b, bool dark)
    {
        ulong h = 1469598103934665603UL;
        h = (h ^ a) * 1099511628211UL;
        h = (h ^ b) * 1099511628211UL;
        h = (h ^ (dark ? 1UL : 0UL)) * 1099511628211UL;
        return h;
    }
}
