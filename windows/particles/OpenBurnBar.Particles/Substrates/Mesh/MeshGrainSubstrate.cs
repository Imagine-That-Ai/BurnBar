using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Mesh;

/// <summary>
/// Living Grain — faithful C# port of Swift
/// <c>Views/Substrate/Mesh/MeshGrainSubstrate.swift</c>. The brand mark rendered as a
/// drifting cloud of iridescent micro-grain: a PER-GRAIN particle system (≤ budget
/// motes, ~2.6 per silhouette point) that perpetually CONDENSES onto the mark and
/// sheds back out. Each grain owns a HOME (a silhouette point → inherits that point's
/// resolved brand colour) and a persistent DRIFT offset integrated every frame:
/// a spring toward home scaled by a global COHESION that breathes 0.35→1.0, an
/// analytic divergence-free curl "breeze", a tiny perpetual orbit, drag, plus a
/// non-accumulating sub-pixel film-grain jitter. Settled grain keeps its bright brand
/// hue; wandering grain lerps by far² toward a cool iris jewel tint and dims.
/// </summary>
/// <remarks>
/// DARK → additive, four layered passes: a WIDE Gaussian bloom BED, a tighter
/// per-mote bloom halo, saturated brand-hued bodies, then hot whitened cores. LIGHT →
/// a soft blurred colored haze under crisp cool ink motes with a deep micro-core.
/// <c>reduced</c> fixes cohesion at 0.92 (a poised still stipple); <c>batteryThrottled</c>
/// drops the heaviest pass (the wide bloom bed). Persistent grain arrays are seeded
/// ONCE per point-count. The exact constants ARE the look.
/// </remarks>
public sealed class MeshGrainSubstrate : ISwarmSubstrate
{
    private const double GrainsPerPoint = 2.6;
    private const int GrainBudget = 880;
    private const double CohesionFloor = 0.35;

    private int _n;
    private int[] _home = Array.Empty<int>();
    private double[] _dx = Array.Empty<double>();
    private double[] _dy = Array.Empty<double>();
    private double[] _dvx = Array.Empty<double>();
    private double[] _dvy = Array.Empty<double>();
    private double[] _gseed = Array.Empty<double>();
    private int _builtFor = -1;

    private double[] _px = Array.Empty<double>();
    private double[] _py = Array.Empty<double>();
    private double[] _pk = Array.Empty<double>();
    private double[] _pfar = Array.Empty<double>();
    private double[] _psz = Array.Empty<double>();
    private double[] _pcr = Array.Empty<double>();
    private double[] _pcg = Array.Empty<double>();
    private double[] _pcb = Array.Empty<double>();
    private double[] _poa = Array.Empty<double>();

    private static double CurlX(double x, double y, double t)
        => System.Math.Cos(x * 0.013 + t * 0.20) * System.Math.Cos(y * 0.017 - t * 0.15) * 0.9
           + System.Math.Cos(y * 0.029 + t * 0.27) * 0.5;

    private static double CurlY(double x, double y, double t)
        => System.Math.Sin(x * 0.013 + t * 0.20) * System.Math.Sin(y * 0.017 - t * 0.15) * 0.9
           + System.Math.Sin(x * 0.023 - t * 0.24) * 0.5;

    private static (double, double, double) Iris(double phase)
        => ((150 + 95 * System.Math.Sin(phase)) / 255,
            (150 + 95 * System.Math.Sin(phase + 2.2)) / 255,
            (170 + 85 * System.Math.Sin(phase + 4.3)) / 255);

    private void EnsureGrains(int count)
    {
        if (_builtFor == count && _home.Length > 0) return;
        int want = System.Math.Min(GrainBudget, System.Math.Max(1, (int)System.Math.Round(count * GrainsPerPoint)));
        _n = want;
        _home = new int[want];
        _dvx = new double[want]; _dvy = new double[want];
        _dx = new double[want]; _dy = new double[want];
        _gseed = new double[want];
        _px = new double[want]; _py = new double[want]; _pk = new double[want];
        _pfar = new double[want]; _psz = new double[want];
        _pcr = new double[want]; _pcg = new double[want]; _pcb = new double[want]; _poa = new double[want];
        for (int i = 0; i < want; i++)
        {
            _home[i] = i % count;
            double s = Shash(i * 1.713 + 0.31);
            _gseed[i] = s;
            double a = s * Tau;
            double r = 6 + s * 22;
            _dx[i] = System.Math.Cos(a) * r;
            _dy[i] = System.Math.Sin(a) * r;
        }
        _builtFor = count;
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        int count = frame.Dots.Length;
        if (count == 0) return true;

        EnsureGrains(count);

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;
        double radius = frame.CloudRadius;
        double sizePx = frame.SizePx;

        double form = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1) * 0.45 + 0.55;

        double cohesion;
        if (reduced)
        {
            cohesion = 0.92;
        }
        else
        {
            double breath = 0.5 + 0.5 * System.Math.Sin(t * (0.12 * Tau));
            double c = CohesionFloor + (1 - CohesionFloor) * (0.55 + 0.45 * breath);
            cohesion = ClampD(c, CohesionFloor * 0.6, 1.15);
        }

        double dtf = reduced ? 0 : ClampD(frame.Dt, 0, 3);
        double spring = (0.05 + 0.22 * cohesion) * dtf;
        double drag = System.Math.Pow(0.86, dtf);
        double curlGain = (1 - cohesion) * 1.6;
        double looseR = radius * (0.10 + 0.42 * (1 - cohesion));
        double irisPhase = t * (Tau / 14);
        double jf = System.Math.Floor(t * 24);

        Rgba accent = frame.Stage.Accent;

        // ── PASS 1 — integrate the particle system & bake per-grain draw state. ──
        for (int i = 0; i < _n; i++)
        {
            int hi = _home[i];
            SwarmSubstrateDot d = frame.Dots[hi];
            double hx = d.X;
            double hy = d.Y;
            double seed = _gseed[i];
            double phase = seed * Tau;

            double ox = _dx[i];
            double oy = _dy[i];

            if (!reduced && dtf > 0)
            {
                double vx = _dvx[i] + (-ox * spring);
                double vy = _dvy[i] + (-oy * spring);

                if (curlGain > 0.001)
                {
                    vx += CurlX(hx + ox, hy + oy, t) * curlGain * dtf;
                    vy += CurlY(hx + ox, hy + oy, t) * curlGain * dtf;
                }

                double wob = t * (0.9 + seed * 0.7) + phase;
                vx += System.Math.Cos(wob) * 0.10 * dtf;
                vy += System.Math.Sin(wob * 1.07 + 0.6) * 0.10 * dtf;

                vx *= drag;
                vy *= drag;
                ox += vx * dtf;
                oy += vy * dtf;

                _dvx[i] = vx;
                _dvy[i] = vy;
                _dx[i] = ox;
                _dy[i] = oy;
            }

            double jx = 0.0, jy = 0.0;
            if (!reduced)
            {
                jx = (Shash(i * 2.13 + jf) - 0.5) * 0.9;
                jy = (Shash(i * 3.71 + jf * 1.7) - 0.5) * 0.9;
            }

            double dist = System.Math.Sqrt(ox * ox + oy * oy);
            double far = ClampD(dist / (looseR + 1), 0, 1);

            Rgba brand = d.Rgba;
            (double tr, double tg, double tb) = Iris(irisPhase + phase * 0.3 + far * 1.4);
            double mixT = far * far;
            double jr = tr + (accent.R - tr) * 0.30;
            double jg = tg + (accent.G - tg) * 0.30;
            double jb = tb + (accent.B - tb) * 0.30;
            double cr = brand.R + (jr - brand.R) * mixT;
            double cg = brand.G + (jg - brand.G) * mixT;
            double cb = brand.B + (jb - brand.B) * mixT;

            double br = reduced ? 0.5 + 0.5 * System.Math.Sin(phase * 11) : 0.5 + 0.5 * System.Math.Sin(t * 1.7 + phase);
            double k = ClampD((0.72 + 0.5 * br) * (1 - 0.34 * far) * form, 0, 1.8);

            _px[i] = hx + ox + jx;
            _py[i] = hy + oy + jy;
            _pk[i] = k;
            _pfar[i] = far;
            _psz[i] = sizePx * (1.05 + 0.6 * seed) * (1 - 0.18 * far);
            _pcr[i] = cr;
            _pcg[i] = cg;
            _pcb[i] = cb;
            _poa[i] = brand.A;
        }

        session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;

        if (dark)
        {
            // ── PASS 2a — WIDE BLOOM BED (heaviest; dropped under throttle). ──
            if (!lite)
            {
                double bedR = System.Math.Max(8.0, sizePx * 6.5);
                using (session.PushBlurLayer(bedR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < _n; i++)
                    {
                        double k = _pk[i];
                        if (k <= 0.02) continue;
                        double sz = _psz[i];
                        double r = sz * 4.4;
                        double gr = _pcr[i] + (1 - _pcr[i]) * 0.34;
                        double gg = _pcg[i] + (1 - _pcg[i]) * 0.34;
                        double gb = _pcb[i] + (1 - _pcb[i]) * 0.34;
                        double a = ClampD(0.16 * k, 0, 0.4) * _poa[i];
                        session.FillCircle(_px[i], _py[i], r, new Rgba(gr, gg, gb, a));
                    }
                }
                session.Blend = SubstrateBlend.Add;
            }

            // ── PASS 2b — TIGHTER GRAIN BLOOM (kept under throttle). ──
            {
                double bloomR = System.Math.Max(3.0, sizePx * 2.6);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < _n; i++)
                    {
                        double k = _pk[i];
                        if (k <= 0.02) continue;
                        double far = _pfar[i];
                        double sz = _psz[i];
                        double r = sz * (2.9 + 1.5 * (1 - far));
                        double lift = 0.34 + 0.32 * (1 - far);
                        double gr = _pcr[i] + (1 - _pcr[i]) * lift;
                        double gg = _pcg[i] + (1 - _pcg[i]) * lift;
                        double gb = _pcb[i] + (1 - _pcb[i]) * lift;
                        double a = ClampD(0.5 * k, 0, 0.95) * _poa[i];
                        session.FillCircle(_px[i], _py[i], r, new Rgba(gr, gg, gb, a));
                    }
                }
                session.Blend = SubstrateBlend.Add;
            }

            // ── PASS 3 — crisp saturated bodies + hot whitened cores. ──
            for (int i = 0; i < _n; i++)
            {
                double k = _pk[i];
                if (k <= 0.02) continue;
                double far = _pfar[i];
                double sz = _psz[i];
                double oa = _poa[i];
                double x = _px[i], y = _py[i];

                double bodyR = System.Math.Max(0.6, sz * 1.0);
                session.FillCircle(x, y, bodyR, new Rgba(_pcr[i], _pcg[i], _pcb[i], ClampD(0.82 * k, 0, 1.0) * oa));

                if (far < 0.55)
                {
                    double coreR = System.Math.Max(0.4, sz * 0.52);
                    double wr = _pcr[i] + (1 - _pcr[i]) * 0.74;
                    double wg = _pcg[i] + (1 - _pcg[i]) * 0.74;
                    double wb = _pcb[i] + (1 - _pcb[i]) * 0.74;
                    session.FillCircle(x, y, coreR, new Rgba(wr, wg, wb, ClampD(0.92 * k * (1 - far / 0.55), 0, 1.0) * oa));
                }
            }
        }
        else
        {
            // ── PASS 2 (light) — soft colored HAZE (layer opacity 0.55). ──
            if (!lite)
            {
                double hazeR = System.Math.Max(3.0, sizePx * 2.0);
                using (session.PushBlurLayer(hazeR, SubstrateBlend.Normal, 0.55))
                {
                    session.Blend = SubstrateBlend.Normal;
                    for (int i = 0; i < _n; i++)
                    {
                        double k = _pk[i];
                        if (k <= 0.02) continue;
                        double far = _pfar[i];
                        double r = _psz[i] * (1.8 + 0.9 * (1 - far));
                        double a = ClampD(0.22 * k * (1 - 0.4 * far), 0, 0.4) * _poa[i];
                        session.FillCircle(_px[i], _py[i], r, new Rgba(_pcr[i], _pcg[i], _pcb[i], a));
                    }
                }
                session.Blend = SubstrateBlend.Normal;
            }

            // ── PASS 3 (light) — crisp cool ink motes. ──
            for (int i = 0; i < _n; i++)
            {
                double k = _pk[i];
                if (k <= 0.02) continue;
                double far = _pfar[i];
                double sz = _psz[i];
                double oa = _poa[i];
                double x = _px[i], y = _py[i];

                double bodyR = System.Math.Max(0.6, sz * 0.98);
                session.FillCircle(x, y, bodyR, new Rgba(_pcr[i], _pcg[i], _pcb[i], ClampD((0.42 + 0.5 * (1 - far)) * k, 0, 0.95) * oa));

                if (far < 0.45)
                {
                    double coreR = System.Math.Max(0.4, sz * 0.46);
                    double dr = _pcr[i] * 0.7, dg = _pcg[i] * 0.7, db = _pcb[i] * 0.7;
                    session.FillCircle(x, y, coreR, new Rgba(dr, dg, db, ClampD(0.4 * k * (1 - far / 0.45), 0, 0.6) * oa));
                }
            }
        }

        return true;
    }
}
