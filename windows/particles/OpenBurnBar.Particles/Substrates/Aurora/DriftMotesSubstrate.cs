using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Aurora;

/// <summary>
/// Drift Motes — C# port of Swift <c>Views/Substrate/Aurora/DriftMotesSubstrate.swift</c>
/// (itself a port of imaginethat <c>aurora/drift-motes.ts</c>). The only aurora member
/// whose grains genuinely move: ~1.6 luminescent motes per silhouette point (cap 900),
/// the first <c>count</c> mapping 1:1 as a bright foreground layer and the rest
/// scattering as a dim background haze, each orbiting its anchor on its own slow
/// Lissajous loop under one shared 2-octave domain-warped ribbon drift with parallax.
/// </summary>
/// <remarks>
/// DARK (additive): a true Gaussian under-glow, then per mote a colored body disc, a
/// cached soft white grain bloom, a whitened hot core, and for ~5% the brightest a
/// slowly-rotating white diffraction cross (batched into one stroke, averaged alpha).
/// LIGHT: a soft colored halo + saturated body + crisp deepened core. <c>reduced</c>
/// freezes the orbit; <c>batteryThrottled</c> drops the grain bloom + sparkle passes.
/// Constants match the Swift original line-for-line.
/// </remarks>
public sealed class DriftMotesSubstrate : ISwarmSubstrate
{
    private const double MotesPerPoint = 1.6;
    private const int MaxMotes = 900;

    private int _builtCount = -1;
    private int[] _anchor = Array.Empty<int>();
    private double[] _depth = Array.Empty<double>();
    private double[] _orad = Array.Empty<double>();
    private double[] _ofx = Array.Empty<double>();
    private double[] _ofy = Array.Empty<double>();
    private double[] _opx = Array.Empty<double>();
    private double[] _opy = Array.Empty<double>();
    private double[] _twk = Array.Empty<double>();
    private bool[] _spark = Array.Empty<bool>();
    private double[] _msz = Array.Empty<double>();

    private double[] _mx = Array.Empty<double>();
    private double[] _my = Array.Empty<double>();
    private double[] _mb = Array.Empty<double>();

    private readonly List<LineSegment> _cross = new(64);

    private static double Flow(double x, double y, double t)
    {
        double a = System.Math.Sin(x * 0.012 + t * 0.55) + System.Math.Cos(y * 0.016 - t * 0.4);
        double b = System.Math.Sin((x + y) * 0.02 - t * 0.33) * 0.45;
        return a + b;
    }

    private void BuildMotes(int count)
    {
        if (count == _builtCount) return;
        _builtCount = count;
        int m = count <= 0 ? 0 : System.Math.Min(MaxMotes, (int)System.Math.Round(count * MotesPerPoint));
        _anchor = new int[m];
        _depth = new double[m];
        _orad = new double[m];
        _ofx = new double[m];
        _ofy = new double[m];
        _opx = new double[m];
        _opy = new double[m];
        _twk = new double[m];
        _spark = new bool[m];
        _msz = new double[m];
        _mx = new double[m];
        _my = new double[m];
        _mb = new double[m];
        if (count <= 0) return;

        for (int k = 0; k < m; k++)
        {
            double kd = k;
            bool fore = k < count;
            _anchor[k] = fore ? k : (int)(Shash(kd * 1.93 + 0.7) * count) % count;

            double s0 = Shash(kd * 2.11 + 0.13);
            double s1 = Shash(kd * 3.77 + 1.31);
            double s2 = Shash(kd * 5.39 + 2.57);
            double s3 = Shash(kd * 7.13 + 3.91);

            _depth[k] = fore ? 0.62 + s0 * 0.3 : 0.3 + s0 * 0.34;
            _orad[k] = fore ? 0.7 + s1 * 1.1 : 1.0 + s1 * 1.6;
            _ofx[k] = Tau / (4 + s2 * 5);
            _ofy[k] = Tau / (4 + s3 * 5);
            _opx[k] = s2 * Tau;
            _opy[k] = s3 * Tau;
            _twk[k] = s0 * Tau;
            _spark[k] = s1 > 0.95;
            _msz[k] = 0.7 + s3 * 0.7;
        }
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;
        BuildMotes(count);
        int m = _anchor.Length;
        if (m == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double sizePx = frame.SizePx;
        double t = frame.T;
        SubstrateStage stage = frame.Stage;
        double cyc = frame.Cy;
        double RR = System.Math.Max(1.0, frame.CloudRadius);

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.45 + 0.55;
        double driftAmp = reduced ? 0.0 : ClampD(frame.CloudRadius * 0.02, 1.6, 5.0);

        // Pass 0: resolve every mote's live orbit + drift + twinkle ONCE.
        for (int k = 0; k < m; k++)
        {
            int ai = _anchor[k];
            double hx = dots[ai].X, hy = dots[ai].Y;
            double d = _depth[k];

            double r = _orad[k] * sizePx;
            double ox, oy;
            if (reduced)
            {
                ox = System.Math.Cos(_opx[k]) * r;
                oy = System.Math.Sin(_opy[k]) * r * 0.85;
            }
            else
            {
                ox = System.Math.Cos(t * _ofx[k] + _opx[k]) * r;
                oy = System.Math.Sin(t * _ofy[k] + _opy[k]) * r * 0.85;
            }

            double dx = 0, dy = 0;
            if (!reduced)
            {
                double lag = (1 - d) * 0.9;
                double fv = Flow(hx, hy, t - lag);
                double par = 0.45 + d * 0.7;
                dx = System.Math.Sin(fv + _opx[k] * 0.3) * driftAmp * par;
                dy = System.Math.Cos(fv * 0.7 + _opy[k] * 0.3) * driftAmp * 0.55 * par;
            }

            _mx[k] = hx + ox + dx;
            _my[k] = hy + oy + dy;
            _mb[k] = reduced
                ? 0.6 + 0.4 * (0.5 + 0.5 * System.Math.Sin(_twk[k]))
                : 0.62 + 0.38 * (0.5 + 0.5 * System.Math.Sin(t * 1.3 + _twk[k]));
        }

        if (dark)
            PaintDark(frame, session, m, sizePx, t, f, reduced, lite, stage, cyc, RR);
        else
            PaintLight(frame, session, m, sizePx, f);

        return true;
    }

    private void PaintDark(SwarmSubstrateFrame frame, ISubstrateDrawingSession session,
        int m, double sizePx, double t, double f, bool reduced, bool lite,
        SubstrateStage stage, double cyc, double RR)
    {
        SwarmSubstrateDot[] dots = frame.Dots;

        Rgba GlowTint(int ai)
        {
            double hy = dots[ai].Y;
            double vT = ClampD((hy - (cyc - RR)) / (2 * RR), 0, 1);
            Rgba aurora = stage.Accent2.Mix(stage.Accent, vT);
            return dots[ai].Rgba.Mix(aurora, 0.34);
        }

        // Pass A — TRUE GAUSSIAN under-glow.
        if (!lite)
        {
            using (session.PushBlurLayer(System.Math.Max(3.0, sizePx * 2.6), SubstrateBlend.Add))
            {
                session.Blend = SubstrateBlend.Add;
                for (int k = 0; k < m; k++)
                {
                    int ai = _anchor[k];
                    double d = _depth[k];
                    double bright = _mb[k];
                    double sz = sizePx * _msz[k] * (1.1 + 0.45 * d);
                    double gR = sz * (1.5 + 0.9 * bright);
                    double gA = ClampD(0.12 + 0.20 * d * bright, 0, 0.6) * f;
                    session.FillCircle(_mx[k], _my[k], gR, GlowTint(ai).WithOpacity(gA));
                }
            }
        }

        // Body + core passes (additive).
        session.Blend = SubstrateBlend.Add;
        bool haveGrain = !lite;

        _cross.Clear();
        double crossK = 0;
        int crossN = 0;

        for (int k = 0; k < m; k++)
        {
            int ai = _anchor[k];
            double d = _depth[k];
            double bright = _mb[k];
            Rgba col = dots[ai].Rgba;
            double x = _mx[k], y = _my[k];
            double sz = sizePx * _msz[k] * (1.1 + 0.45 * d);

            double discA = ClampD(0.20 + 0.22 * d * bright, 0, 0.62) * f;
            double discR = sz * 1.25;
            session.FillCircle(x, y, discR, col.WithOpacity(discA));

            if (haveGrain)
            {
                double bloomR = sz * (2.5 + 1.5 * bright);
                session.DrawGlowSprite(x, y, bloomR, Rgba.White, ClampD(0.16 + 0.26 * d * bright, 0, 0.7) * f);
            }

            double coreA = ClampD((0.52 + 0.5 * d) * bright, 0, 1) * f;
            double w = 0.48 + 0.32 * bright;
            double coreR = System.Math.Max(0.7, sz * 0.52);
            session.FillCircle(x, y, coreR, col.ToWhite(w).WithOpacity(coreA));

            if (!lite && _spark[k] && bright > 0.7)
            {
                double len = sz * (2.4 + 2.2 * (bright - 0.5));
                double ang = reduced ? _twk[k] : t * 0.18 + _twk[k];
                double cx0 = System.Math.Cos(ang) * len, cy0 = System.Math.Sin(ang) * len;
                double cx1 = System.Math.Cos(ang + System.Math.PI / 2) * len, cy1 = System.Math.Sin(ang + System.Math.PI / 2) * len;
                _cross.Add(new LineSegment(x - cx0, y - cy0, x + cx0, y + cy0));
                _cross.Add(new LineSegment(x - cx1, y - cy1, x + cx1, y + cy1));
                crossK += ClampD(0.18 * d * bright, 0, 0.4) * f;
                crossN += 1;
            }
        }

        if (crossN > 0)
        {
            session.DrawLineBatch(CollectionsMarshal.AsSpan(_cross),
                Rgba.White.WithOpacity(ClampD(crossK / crossN, 0, 0.5)), 0.8);
        }
    }

    private void PaintLight(SwarmSubstrateFrame frame, ISubstrateDrawingSession session,
        int m, double sizePx, double f)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        session.Blend = SubstrateBlend.Normal;
        for (int k = 0; k < m; k++)
        {
            int ai = _anchor[k];
            double d = _depth[k];
            double bright = _mb[k];
            Rgba col = dots[ai].Rgba;
            double x = _mx[k], y = _my[k];
            double sz = sizePx * _msz[k] * (1.1 + 0.45 * d);

            double haloA = ClampD(0.10 + 0.11 * d * bright, 0, 0.26) * f;
            double haloR = sz * 2.2;
            session.FillCircle(x, y, haloR, col.WithOpacity(haloA));

            double bodyA = ClampD(0.16 + 0.18 * d * bright, 0, 0.5) * f;
            double bodyR = sz * 1.1;
            session.FillCircle(x, y, bodyR, col.WithOpacity(bodyA));

            double coreA = ClampD((0.50 + 0.5 * d) * bright, 0, 0.95) * f;
            double coreR = System.Math.Max(0.6, sz * 0.5);
            session.FillCircle(x, y, coreR, col.Darkened(0.12).WithOpacity(coreA));
        }
    }
}
