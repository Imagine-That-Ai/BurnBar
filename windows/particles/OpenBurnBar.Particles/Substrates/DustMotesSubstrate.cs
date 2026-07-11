using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// Dust Motes — "Motes In The Beam", faithful C# port of Swift
/// <c>Views/Substrate/Volumetric/DustMotesSubstrate.swift</c> (port of imaginethat
/// <c>volumetric/dust-motes.ts</c>). The mark rendered as suspended dust drifting in
/// still air, made visible only where one wide diagonal GAUSSIAN BEAM rakes across the
/// cloud. Each point is a tiny soft radial MOTE tinted across a 24-step accent→accent2
/// altitude ramp (biased toward white so motes read sun-caught).
/// </summary>
/// <remarks>
/// A mote's brightness is its dim ambient base PLUS a flare wherever the swept beam
/// passes over its projected diagonal axis. ~38% are spring-locked cores that DON'T
/// drift and hold a floored alpha; free dust drifts on a 2-octave value-noise flow
/// field + Brownian micro-wander, leashed to <c>radius·0.05</c>. The beam center sweeps
/// on <c>sin(t·0.045)</c>; a 1.8s breath inhales its width; ~10% "lit specks" catch a
/// thin additive 4-point cross glint. DARK: soft ink radial backing + additive motes;
/// LIGHT: no ink, lower-alpha cooler motes. The whole-canvas god-ray band is one
/// <see cref="ISubstrateDrawingSession.FillLinearGradientRect"/> laid perpendicular to
/// the beam axis. <c>reduced</c> freezes a poised raked still frame (no drift);
/// <c>batteryThrottled</c> locks drift + drops the cross sparkles + Gaussian bloom.
/// </remarks>
public sealed class DustMotesSubstrate : ISwarmSubstrate
{
    private const int HueSteps = 24;

    private Rgba[] _bucket = Array.Empty<Rgba>();
    private ulong _rampKey = ulong.MaxValue;

    private int _attrCount = -1;
    private double _attrCx, _attrCy, _attrR;
    private int[] _hueIdx = Array.Empty<int>();
    private double[] _seedA = Array.Empty<double>();
    private double[] _driftA = Array.Empty<double>();
    private double[] _dim = Array.Empty<double>();
    private bool[] _isCore = Array.Empty<bool>();
    private bool[] _isSpeck = Array.Empty<bool>();
    private double[] _bx = Array.Empty<double>();

    private double[] _pX = Array.Empty<double>();
    private double[] _pY = Array.Empty<double>();
    private double[] _pInten = Array.Empty<double>();
    private double[] _pBeam = Array.Empty<double>();
    private double[] _pTw = Array.Empty<double>();

    private static readonly Rgba InkColor = new(7.0 / 255, 10.0 / 255, 20.0 / 255, 1);

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;
        EnsureRamp(frame.Stage);
        EnsureAttrs(frame);
        EnsureScratch(count);

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool throttle = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        double radius = frame.CloudRadius, cx = frame.Cx, cy = frame.Cy;
        double invR = radius > 0 ? 1 / radius : 0;
        Rgba accent = frame.Stage.Accent;

        double env = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.55 + 0.45;

        double beamCenter = reduced ? -0.12 : System.Math.Sin(t * 0.045) * 0.95;
        double widthBreath = reduced ? 0.85 : 0.7 + 0.3 * Smoothstep(0, 1, 0.5 + 0.5 * System.Math.Sin(t * (Tau / 1.8)));
        double beamSigma = 0.42 * widthBreath;
        double invBeam2 = 1 / (2 * beamSigma * beamSigma);
        double leash = radius * 0.05;
        double tFlow = reduced ? 0 : t * 0.06;
        bool drift = !reduced && !throttle;

        double baseA = dark ? 0.54 : 0.18;
        double flareA = dark ? 0.82 : 0.40;
        double coreFloor = dark ? 0.60 : 0.34;
        double intenCap = dark ? 1.75 : 0.98;

        // ── PRECOMPUTE: drifted position + beam + twinkle + intensity per mote ──
        for (int i = 0; i < count; i++)
        {
            double ox = dots[i].X, oy = dots[i].Y;
            bool core = _isCore[i];
            double x = ox, y = oy;
            double axis = _bx[i];
            if (drift && !core)
            {
                double ph = _driftA[i];
                double fx = Fbm(ox * 0.012, oy * 0.012, tFlow);
                double fy = Fbm(ox * 0.012 + 31.7, oy * 0.012 + 11.3, tFlow);
                double wob = 0.4 + 0.6 * System.Math.Sin(t * 0.5 + ph);
                double dxo = (fx + 0.35 * System.Math.Cos(t * 0.23 + ph)) * leash * wob;
                double dyo = (fy + 0.35 * System.Math.Sin(t * 0.19 + ph * 1.3)) * leash * wob;
                x = ox + dxo; y = oy + dyo;
                axis += (dxo * 0.788 + dyo * 0.616) * invR;
            }
            double dd = axis - beamCenter;
            double beam = System.Math.Exp(-(dd * dd) * invBeam2);
            double tw = reduced ? 0.6 + 0.4 * System.Math.Sin(_seedA[i]) : 0.55 + 0.45 * System.Math.Sin(t * 1.2 + _seedA[i]);
            double inten = baseA * (0.6 + 0.4 * _dim[i]) * (0.8 + 0.2 * tw)
                + flareA * beam * (0.6 + 0.4 * tw);
            if (core) inten = System.Math.Max(inten, coreFloor * (0.85 + 0.15 * tw));
            inten = ClampD(inten * env, 0, intenCap);
            _pX[i] = x; _pY[i] = y; _pBeam[i] = beam; _pTw[i] = tw; _pInten[i] = inten;
        }

        // ── dark page: soft centered ink field so additive bloom has somewhere to sum. ──
        if (dark)
        {
            double rr = System.Math.Max(radius * 1.85, 1);
            session.Blend = SubstrateBlend.Normal;
            session.DrawGlowSprite(cx, cy, rr, InkColor, ClampD(0.55 * env, 0, 0.6));
        }

        // ── VOLUMETRIC GOD-RAY SHAFT: one global gaussian band across the whole canvas. ──
        {
            double ux = 0.788, uy = 0.616;
            double s0 = beamCenter * radius;
            double diag = System.Math.Sqrt(frame.Width * frame.Width + frame.Height * frame.Height);
            double sigmaPx = ClampD(beamSigma * radius, 80, System.Math.Max(diag * 0.30, 80));
            double span = sigmaPx * 3.2;
            double spx = cx + ux * (s0 - span), spy = cy + uy * (s0 - span);
            double epx = cx + ux * (s0 + span), epy = cy + uy * (s0 + span);
            Rgba shaftCol = dark
                ? accent.Mix(frame.Stage.Accent2, 0.35).ToWhite(0.30)
                : accent.Mix(frame.Stage.Accent2, 0.55).ToWhite(0.55);
            double breath = reduced ? 0.85 : 0.72 + 0.28 * (0.5 + 0.5 * System.Math.Sin(t * (Tau / 1.8)));
            double peak = (dark ? 0.34 : 0.15) * env * breath;
            ReadOnlySpan<double> ts = stackalloc double[] { 0.0, 0.16, 0.30, 0.40, 0.5, 0.60, 0.70, 0.84, 1.0 };
            Span<GradientStop> stops = stackalloc GradientStop[ts.Length];
            for (int si = 0; si < ts.Length; si++)
            {
                double tt = ts[si];
                double dd = (tt - 0.5) * 6.4;
                double g = System.Math.Exp(-(dd * dd) * 0.5);
                stops[si] = new GradientStop(tt, shaftCol.WithOpacity(ClampD(peak * g, 0, 0.6)));
            }
            session.Blend = SubstrateBlend.Add;
            session.FillLinearGradientRect(0, 0, frame.Width, frame.Height, stops, spx, spy, epx, epy);
        }

        double moteD = System.Math.Max(3.2, sizePx * 3.15);

        // ── PASS A: TRUE GAUSSIAN BLOOM (dark, not throttled) ──
        if (dark && !throttle)
        {
            double bloomR = sizePx * 2.8;
            using (session.PushBlurLayer(sizePx * 2.8, SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int i = 0; i < count; i++)
                {
                    double inten = _pInten[i];
                    if (inten <= 0.008) continue;
                    double beam = _pBeam[i];
                    double r = bloomR * (0.95 + 0.6 * beam);
                    Rgba glowCol = dots[i].Rgba.Mix(accent, 0.30).ToWhite(0.12 + 0.34 * beam);
                    double a = ClampD(inten * 0.58, 0, 0.72);
                    session.FillCircle(_pX[i], _pY[i], r, glowCol.WithOpacity(a));
                }
            }
        }

        // ── motes body + cores: additive on dark, source-over on light. ──
        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
        double bodyCap = dark ? 0.95 : 0.6;
        double coreCap = dark ? 0.98 : 0.78;

        Span<LineSegment> cross = stackalloc LineSegment[2];
        for (int i = 0; i < count; i++)
        {
            double inten = _pInten[i];
            if (inten <= 0.004) continue;
            double beam = _pBeam[i];
            double tw = _pTw[i];
            bool core = _isCore[i];
            double x = _pX[i], y = _pY[i];

            // soft tinted body skirt.
            double sz = moteD * (core ? 0.95 : 0.82 + 0.55 * beam);
            session.DrawGlowSprite(x, y, sz / 2, _bucket[_hueIdx[i]], ClampD(inten * 0.95, 0, bodyCap));

            // hot core.
            double coreA = dark ? ClampD((inten - 0.05) * 1.35, 0, coreCap) : ClampD(inten * 1.05, 0, coreCap);
            if (coreA > 0.01)
            {
                double cr = System.Math.Max(0.7, sizePx * 0.5) * (core ? 1.05 : 0.85 + 0.45 * beam);
                Rgba coreCol = dark
                    ? dots[i].Rgba.ToWhite(0.5 + 0.42 * beam).WithOpacity(coreA)
                    : dots[i].Rgba.WithOpacity(coreA);
                session.FillCircle(x, y, cr, coreCol);
            }

            // sparse "lit specks" inside the beam catch a thin 4-point cross glint.
            if (_isSpeck[i] && beam > 0.5 && !throttle)
            {
                double gg = ClampD((beam - 0.5) / 0.5, 0, 1) * (0.6 + 0.4 * tw);
                double len = sz * (0.6 + 0.85 * gg);
                double sa = ClampD((dark ? 0.55 : 0.32) * gg * env, 0, 0.75);
                double aSp = _seedA[i] * 0.5;
                double c1 = System.Math.Cos(aSp), s1 = System.Math.Sin(aSp);
                cross[0] = new LineSegment(x - c1 * len, y - s1 * len, x + c1 * len, y + s1 * len);
                cross[1] = new LineSegment(x + s1 * len, y - c1 * len, x - s1 * len, y + c1 * len);
                Rgba sc = dark ? new Rgba(1, 1, 1, sa) : dots[i].Rgba.WithOpacity(sa);
                session.DrawLineBatch(cross, sc, 0.8);
            }
        }

        // ── PASS C: small-radius crispening — a hard source-over dot on each locked core. ──
        if (radius < 70)
        {
            session.Blend = SubstrateBlend.Normal;
            double ca = ClampD((dark ? 0.85 : 0.72) * env, 0, 1);
            for (int i = 0; i < count; i++)
            {
                if (!_isCore[i]) continue;
                Rgba c = dots[i].Rgba;
                Rgba col = (dark ? c.ToWhite(0.35) : c).WithOpacity(ca);
                session.FillCircle(dots[i].X, dots[i].Y, 0.8, col);
            }
        }

        return true;
    }

    /// <summary>Deterministic 2-octave value-noise-ish flow field (~[-0.9, 0.9]).</summary>
    private static double Fbm(double x, double y, double tz)
    {
        double amp = 0.6, freq = 1.0, sum = 0.0;
        for (int o = 0; o < 2; o++)
        {
            double nx = x * freq + tz * (0.5 + o * 0.27);
            double ny = y * freq - tz * 0.31;
            sum += amp * System.Math.Sin(nx + 1.7 * System.Math.Cos(ny)) * System.Math.Cos(ny - 1.3 * System.Math.Sin(nx));
            freq *= 2.03; amp *= 0.5;
        }
        return sum;
    }

    private void EnsureScratch(int count)
    {
        if (_pX.Length == count) return;
        _pX = new double[count]; _pY = new double[count];
        _pInten = new double[count]; _pBeam = new double[count]; _pTw = new double[count];
    }

    private void EnsureRamp(SubstrateStage stage)
    {
        ulong key = HashKey(stage.Accent.BucketKey, stage.Accent2.BucketKey);
        if (key == _rampKey && _bucket.Length == HueSteps) return;
        _rampKey = key;
        _bucket = new Rgba[HueSteps];
        for (int i = 0; i < HueSteps; i++)
        {
            if (i == 0) { _bucket[i] = stage.Accent; continue; }
            double tt = i / (double)(HueSteps - 1);
            _bucket[i] = stage.Accent.Mix(stage.Accent2, tt).ToWhite(0.12);
        }
    }

    private void EnsureAttrs(SwarmSubstrateFrame frame)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == _attrCount && frame.Cx == _attrCx && frame.Cy == _attrCy && frame.CloudRadius == _attrR) return;
        _attrCount = count; _attrCx = frame.Cx; _attrCy = frame.Cy; _attrR = frame.CloudRadius;
        _hueIdx = new int[count]; _seedA = new double[count]; _driftA = new double[count];
        _dim = new double[count]; _isCore = new bool[count]; _isSpeck = new bool[count]; _bx = new double[count];
        double invR = frame.CloudRadius > 0 ? 1 / frame.CloudRadius : 0;
        int steps = HueSteps;
        for (int i = 0; i < count; i++)
        {
            double dx = (dots[i].X - frame.Cx) * invR;
            double dy = (dots[i].Y - frame.Cy) * invR;
            double tt = ClampD(0.5 - dy * 0.5, 0, 1);
            _hueIdx[i] = System.Math.Min(steps - 1, System.Math.Max(0, (int)(tt * (steps - 1) + 0.5)));
            _seedA[i] = Shash(i * 1.37 + 0.5) * Tau;
            _driftA[i] = Shash(i * 2.71 + 9.1) * Tau;
            _dim[i] = 0.5 + 0.5 * Shash(i * 3.13 + 4.4);
            _isCore[i] = Shash(i * 0.917 + 3.3) < 0.38;
            _isSpeck[i] = Shash(i * 5.21 + 1.7) < 0.1;
            _bx[i] = dx * 0.788 + dy * 0.616;
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
