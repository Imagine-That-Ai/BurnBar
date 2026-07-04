using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Math;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Aurora;

/// <summary>
/// Aurora Filament — C# port of Swift <c>Views/Substrate/Aurora/AuroraFilamentSubstrate.swift</c>
/// (itself a port of imaginethat <c>aurora/filament.ts</c>). The whole mark is one
/// continuous glowing thread — a single luminous wire snaking through every silhouette
/// point in nearest-neighbour order (from the shared structure walk), so the logo reads
/// as one living line of cold light. Hence <see cref="SuppressesGlyphs"/> is <c>true</c>.
/// </summary>
/// <remarks>
/// Each vertex rides a 2-octave domain-warped flow field at low amplitude (clamped below
/// point spacing so the wire never self-crosses); any segment far longer than the local
/// mean is broken into a new sub-path. The single broken polyline is stroked in stacked
/// passes: DARK (additive) a true Gaussian bloom (wide halo + inner thread) → a saturated
/// mid-glow body → a hot near-white core → a crawling dash "charge"; LIGHT a soft
/// under-glow → a crisp ink core → a travelling sheen. The stroke color is a screen-space
/// vertical amber→teal→violet gradient. <c>reduced</c> → a poised straight still wire;
/// <c>batteryThrottled</c> drops the wide blur bloom + charge. <c>count &lt; 2</c>
/// degenerates to a single soft aurora seed.
/// </remarks>
public sealed class AuroraFilamentSubstrate : ISwarmSubstrate
{
    private static readonly Rgba HueCrown = new(255.0 / 255, 196.0 / 255, 120.0 / 255);
    private static readonly Rgba HueMid = new(120.0 / 255, 240.0 / 255, 210.0 / 255);
    private static readonly Rgba HueHem = new(150.0 / 255, 170.0 / 255, 255.0 / 255);

    private readonly SubstrateStructure _structure = new();

    private double[] _px = Array.Empty<double>();
    private double[] _py = Array.Empty<double>();
    private bool[] _brk = Array.Empty<bool>();
    private Vec2[] _pts = Array.Empty<Vec2>();
    private readonly GradientStop[] _stops = new GradientStop[3];

    public bool SuppressesGlyphs => true;

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;
        SubstrateStage stage = frame.Stage;

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        if (count < 2)
        {
            DrawSeed(frame, session);
            return true;
        }

        SubstrateStructure.Structure s = _structure.Get(dots, 6);
        int[] order = s.Order.Length == count ? s.Order : Identity(count);

        bool isShape = frame.IsShapeMode;
        double formGate = reduced ? 1.0 : (isShape ? ClampD(frame.SettleProgress, 0, 1) : 1.0);

        double spacing = System.Math.Max(2.0, frame.CloudRadius / System.Math.Max(1.0, System.Math.Sqrt(count)));
        double amp = reduced ? 0.0 : System.Math.Min(spacing * 0.42, 5.5);

        Grow(count);

        double prevX = 0, prevY = 0, total = 0;
        for (int step = 0; step < count; step++)
        {
            SwarmSubstrateDot d = dots[order[step]];
            double vx = d.X, vy = d.Y;
            if (amp > 0)
            {
                (double fx, double fy) = Flow(d.X, d.Y, t);
                vx = d.X + fx * amp;
                vy = d.Y + fy * amp;
            }
            _px[step] = vx;
            _py[step] = vy;
            if (step > 0)
            {
                double dx = vx - prevX, dy = vy - prevY;
                total += System.Math.Sqrt(dx * dx + dy * dy);
            }
            prevX = vx; prevY = vy;
        }
        double arcTotal = total > 0 ? total : 1;

        double meanStep = total / System.Math.Max(1, count - 1);
        double breakThresh = System.Math.Max(meanStep * 3.4, spacing * 4);
        _brk[0] = false;
        for (int step = 1; step < count; step++)
        {
            double dx = _px[step] - _px[step - 1], dy = _py[step] - _py[step - 1];
            _brk[step] = System.Math.Sqrt(dx * dx + dy * dy) > breakThresh;
        }

        for (int step = 0; step < count; step++)
            _pts[step] = new Vec2(_px[step], _py[step]);

        double top = System.Math.Max(0.0, frame.Cy - frame.CloudRadius * 1.15);
        double bot = frame.Cy + frame.CloudRadius * 1.15;
        Rgba crown = HueCrown.Mix(stage.Accent, Smoothstep(0, 1, 0.32));
        Rgba mid = HueMid.Mix(stage.Accent2, Smoothstep(0, 1, 0.32));
        Rgba hem = HueHem.Mix(stage.Accent, Smoothstep(0, 1, 0.28));

        double breath = reduced ? 0.9 : 0.78 + 0.22 * (0.5 + 0.5 * System.Math.Sin(t * 0.9));
        double chargePhase = reduced ? 0.0 : Frac(t * 0.2);
        double w = System.Math.Max(1.0, frame.SizePx);

        void Grad(double width, double alpha, DashPattern? dash)
        {
            if (alpha <= 0.001 || width <= 0) return;
            _stops[0] = new GradientStop(0.0, crown.WithOpacity(alpha));
            _stops[1] = new GradientStop(0.5, mid.WithOpacity(alpha));
            _stops[2] = new GradientStop(1.0, hem.WithOpacity(alpha));
            session.StrokePolylineGradient(_pts.AsSpan(0, count), _stops, 0, top, 0, bot, width,
                closed: false, dash: dash, breakBefore: _brk.AsSpan(0, count));
        }
        void Solid(Rgba baseColor, double width, double alpha, DashPattern? dash)
        {
            if (alpha <= 0.001 || width <= 0) return;
            session.StrokePolyline(_pts.AsSpan(0, count),
                baseColor.WithOpacity(ClampD(baseColor.A * alpha, 0, 1)),
                width, closed: false, dash: dash, breakBefore: _brk.AsSpan(0, count));
        }

        if (dark)
        {
            if (!lite)
            {
                double bloomR = isShape ? System.Math.Max(6.0, w * 3.2) : System.Math.Max(8.0, w * 5.0);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    if (!isShape)
                        Grad(w * 3.6, ClampD(0.40 * formGate, 0, 0.7), null);
                    Grad(w * 2.1, ClampD(0.55 * formGate, 0, 0.9), null);
                    Grad(w * 0.95, ClampD(0.62 * formGate * breath, 0, 0.95), null);
                }
                session.Blend = SubstrateBlend.Add;
            }
            else
            {
                Grad(w * 3.4, ClampD(0.14 * formGate, 0, 0.32), null);
            }
            Grad(w * 1.6, ClampD(0.32 * formGate, 0, 0.62), null);
            Solid(Rgba.White.WithOpacity(0.97), System.Math.Max(0.85, w * 0.6),
                ClampD(0.96 * formGate * breath, 0, 1), null);
            if (!reduced && !lite && arcTotal > 4)
            {
                double dash = System.Math.Max(14.0, arcTotal * 0.07);
                double phase = -chargePhase * arcTotal;
                var dp = new DashPattern(dash, System.Math.Max(0.001, arcTotal - dash), phase);
                Grad(System.Math.Max(1.0, w * 1.3), ClampD(0.5 * formGate, 0, 0.7), dp);
                Solid(Rgba.White.WithOpacity(0.95), System.Math.Max(0.8, w * 0.7),
                    ClampD(0.55 * formGate, 0, 0.8), dp);
            }
        }
        else
        {
            Grad(w * 2.8, ClampD(0.21 * formGate, 0, 0.34), null);
            Solid(stage.Ink, System.Math.Max(0.9, w * 0.7), ClampD(0.85 * formGate * breath, 0, 1), null);
            if (!reduced && arcTotal > 4)
            {
                double dash = System.Math.Max(14.0, arcTotal * 0.06);
                var dp = new DashPattern(dash, System.Math.Max(0.001, arcTotal - dash), -chargePhase * arcTotal);
                Grad(System.Math.Max(0.9, w * 0.85), ClampD(0.4 * formGate, 0, 0.6), dp);
            }
        }

        return true;
    }

    private static (double, double) Flow(double x, double y, double t)
    {
        const double k1 = 0.012, k2 = 0.027;
        double a1 = System.Math.Sin(x * k1 + t * 0.55) + System.Math.Cos(y * k1 * 1.3 - t * 0.4);
        double b1 = System.Math.Cos(x * k1 * 1.1 - t * 0.45) + System.Math.Sin(y * k1 - t * 0.5);
        double a2 = System.Math.Sin((x + b1 * 30) * k2 + t * 0.9);
        double b2 = System.Math.Cos((y + a1 * 30) * k2 - t * 0.8);
        return (a1 * 0.7 + a2 * 0.45, b1 * 0.7 + b2 * 0.45);
    }

    private void DrawSeed(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot d = frame.Dots[0];
        bool dark = frame.Dark;
        double k = frame.Reduced ? 0.9 : 0.7 + 0.3 * (0.5 + 0.5 * System.Math.Sin(frame.T * 1.2));
        Rgba glow = HueMid.Mix(frame.Stage.Accent2, Smoothstep(0, 1, 0.3));
        double gr = frame.SizePx * 3 * k;
        session.FillCircle(d.X, d.Y, gr, glow.WithOpacity(0.3 * k));
        double cr = System.Math.Max(0.9, frame.SizePx * 0.7);
        Rgba core = dark ? Rgba.White.WithOpacity(0.95 * 0.95) : frame.Stage.Ink.WithOpacity(0.85);
        session.FillCircle(d.X, d.Y, cr, core);
    }

    private static int[] Identity(int n)
    {
        var a = new int[n];
        for (int i = 0; i < n; i++) a[i] = i;
        return a;
    }

    private void Grow(int n)
    {
        if (_px.Length >= n) return;
        _px = new double[n];
        _py = new double[n];
        _brk = new bool[n];
        _pts = new Vec2[n];
    }
}
