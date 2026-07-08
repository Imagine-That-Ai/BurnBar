using System;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using static OpenBurnBar.Particles.Math.SubstrateKit;

namespace OpenBurnBar.Particles.Substrates.Flow;

/// <summary>
/// Petal Drift — C# port of Swift <c>Views/Substrate/Flow/PetalDriftSubstrate.swift</c>
/// (itself a port of imaginethat <c>flow/petal-drift.ts</c>). Each silhouette point is
/// one soft cherry-blossom petal: a filled bezier teardrop (two quadratic curves,
/// tessellated to a polygon) in the point's own color, with a cached cream sheen
/// glow floated on top. The local curl-wind tilts each petal's long axis, a ≤3px
/// curl orbit drifts the centroid, and a ~0.3 Hz flutter flips the petal edge-on↔
/// broadside. A fixed top-left key light dims back-facing petals toward a mauve fold.
/// </summary>
/// <remarks>
/// The colored teardrop body is source-over on both polarities; the cream sheen is
/// additive on dark, source-over on light. Depth reads as soft glow under → saturated
/// body → bright cream highlight on top. <c>reduced</c> → a poised still bloom;
/// <c>batteryThrottled</c> drops the sheen + the blurred depth pass. The bezier body
/// is tessellated to a 16-vertex polygon (visually indistinguishable from the source
/// curves at petal scale) so it forwards through the platform-agnostic seam.
/// </remarks>
public sealed class PetalDriftSubstrate : ISwarmSubstrate
{
    private const int TessPerCurve = 8; // segments per quadratic → 2*N = 16-gon body.

    // Soft cream sheen tint (the Swift baked-sprite's dominant cream stop). The Win2D
    // glow-sprite cache tints its soft radial ramp by this for the highlight-on-top.
    private static readonly Rgba Cream = new(1.0, 250.0 / 255, 252.0 / 255);

    private readonly Vec2[] _poly = new Vec2[2 * TessPerCurve];

    private readonly struct PetalGeom
    {
        public readonly double X, Y, Angle, Length, HalfWidth, Broadside, Lit, BodyAlpha;
        public readonly Rgba Color;

        public PetalGeom(double x, double y, double angle, double length, double halfWidth,
            double broadside, double lit, in Rgba color, double bodyAlpha)
        {
            X = x; Y = y; Angle = angle; Length = length; HalfWidth = halfWidth;
            Broadside = broadside; Lit = lit; Color = color; BodyAlpha = bodyAlpha;
        }
    }

    private static double WindAngle(double x, double y, double phase)
    {
        double a = System.Math.Sin(x * 0.013 + phase) + System.Math.Cos(y * 0.011 - phase * 0.7);
        double b = System.Math.Sin((x + y) * 0.008 - phase * 0.5);
        return System.Math.Atan2(a, b + 1.35);
    }

    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session)
    {
        SwarmSubstrateDot[] dots = frame.Dots;
        int count = dots.Length;
        if (count == 0) return true;

        bool dark = frame.Dark;
        bool reduced = frame.Reduced;
        bool lite = frame.BatteryThrottled;
        double t = frame.T;
        bool shapeMode = frame.IsShapeMode;

        double f = reduced ? 1.0 : ClampD(frame.SettleProgress, 0, 1);
        double present = shapeMode ? f : 1.0;
        double phase = reduced ? 1.1 : t * 0.22;

        double petalLen;
        if (shapeMode)
        {
            double spacing = frame.CloudRadius / System.Math.Max(8, System.Math.Sqrt(count));
            petalLen = ClampD(frame.SizePx * 3.4 + spacing * 1.05, 7, 15);
        }
        else
        {
            petalLen = ClampD(frame.SizePx * 4.6, 9, 15);
        }

        const double lightX = -0.62, lightY = -0.78;

        Rgba fold = dark
            ? new Rgba(70.0 / 255, 40.0 / 255, 58.0 / 255, 1)
            : new Rgba(150.0 / 255, 120.0 / 255, 140.0 / 255, 1);

        Rgba accent = frame.Stage.Accent;

        PetalGeom Geom(int i)
        {
            SwarmSubstrateDot d = dots[i];
            double tx = d.X, ty = d.Y;
            double seed = Shash(i * 1.93 + 0.27);
            double ph = seed * Tau;
            double wind = WindAngle(tx, ty, phase + seed * 0.6);

            double ox = 0, oy = 0, flutter = 1.0, spin = 0.0;
            if (!reduced)
            {
                double orbT = t * 0.55 + ph;
                double amp = 2.2 * present;
                ox = System.Math.Cos(orbT) * amp;
                oy = System.Math.Sin(orbT * 1.13 + 0.7) * amp * 0.8;
                flutter = System.Math.Sin(t * 1.9 + ph);
                spin = System.Math.Sin(t * 0.5 + ph * 1.7) * 0.22;
            }
            double x = tx + ox, y = ty + oy;

            double dirx = System.Math.Cos(wind), diry = System.Math.Sin(wind);
            if (!shapeMode && !reduced)
            {
                double sp = System.Math.Sqrt(d.Vx * d.Vx + d.Vy * d.Vy);
                if (sp > 0.02)
                {
                    double wgt = ClampD(sp * 0.45, 0, 0.6);
                    dirx += d.Vx / sp * wgt;
                    diry += d.Vy / sp * wgt;
                }
            }
            double ang = System.Math.Atan2(diry, dirx) + spin;
            double broad = 0.32 + 0.68 * System.Math.Abs(flutter);

            double nx = System.Math.Cos(ang + System.Math.PI / 2), ny = System.Math.Sin(ang + System.Math.PI / 2);
            double facing = nx * lightX + ny * lightY;
            double lit = 0.6 + 0.4 * Smoothstep(-1, 1, facing * (flutter >= 0 ? 1 : -1));

            double len = petalLen * (0.85 + 0.3 * seed);
            double halfW = len * 0.42 * broad;
            double dotA = shapeMode ? d.Rgba.A : System.Math.Max(d.Rgba.A, 0.9);
            double aBody = ClampD((0.62 + 0.34 * lit) * present, 0, 1) * dotA;
            Rgba cc = lit >= 0.999 ? d.Rgba : d.Rgba.Mix(fold, 1 - ClampD(lit, 0.4, 1));
            return new PetalGeom(x, y, ang, len, halfW, broad, lit, cc, aBody);
        }

        // PASS 1 · DEPTH UNDER — one blurred layer (bloom on dark, contact-shadow on light).
        if (!lite)
        {
            if (dark)
            {
                double bloomR = ClampD(petalLen * 0.5, 3, 9);
                using (session.PushBlurLayer(bloomR, SubstrateBlend.Add))
                {
                    session.Blend = SubstrateBlend.Add;
                    for (int i = 0; i < count; i++)
                    {
                        PetalGeom g = Geom(i);
                        double len = g.Length * 1.5;
                        double halfW = g.HalfWidth * 1.45 + g.Length * 0.14;
                        double off = g.Length * 0.18;
                        Tessellate(len, halfW, g.X - System.Math.Cos(g.Angle) * off,
                            g.Y - System.Math.Sin(g.Angle) * off, g.Angle);
                        Rgba glow = g.Color.Mix(accent, 0.35);
                        double aGlow = ClampD(g.BodyAlpha * 0.5 * g.Lit, 0, 0.6);
                        session.FillPolygon(_poly, glow.WithOpacity(aGlow));
                    }
                }
            }
            else
            {
                double shadowR = ClampD(petalLen * 0.42, 2, 7);
                Rgba ink = frame.Stage.Ink;
                using (session.PushBlurLayer(shadowR, SubstrateBlend.Normal))
                {
                    session.Blend = SubstrateBlend.Normal;
                    for (int i = 0; i < count; i++)
                    {
                        PetalGeom g = Geom(i);
                        double len = g.Length * 1.18;
                        double halfW = g.HalfWidth * 1.12 + g.Length * 0.08;
                        Tessellate(len, halfW, g.X + g.Length * 0.05, g.Y + g.Length * 0.10, g.Angle);
                        double aSh = ClampD(g.BodyAlpha * 0.22, 0, 0.3);
                        session.FillPolygon(_poly, ink.WithOpacity(aSh));
                    }
                }
            }
        }

        // PASS 2 · BODY + SHEEN.
        for (int i = 0; i < count; i++)
        {
            PetalGeom g = Geom(i);

            session.Blend = SubstrateBlend.Normal;
            Tessellate(g.Length, g.HalfWidth, g.X, g.Y, g.Angle);
            session.FillPolygon(_poly, g.Color.WithOpacity(g.BodyAlpha));

            if (!lite)
            {
                double aSheen = ClampD((dark ? 0.62 : 0.5) * g.Lit * present, 0, 0.85);
                if (aSheen > 0.003)
                {
                    // Soft cream highlight over the lit half of the petal (the Swift
                    // baked cream/specular sheen sprite → a tinted glow through the seam).
                    session.Blend = dark ? SubstrateBlend.Add : SubstrateBlend.Normal;
                    double sheenR = g.Length * 0.52;
                    double hx = g.X + System.Math.Cos(g.Angle) * g.Length * 0.34;
                    double hy = g.Y + System.Math.Sin(g.Angle) * g.Length * 0.34;
                    session.DrawGlowSprite(hx, hy, sheenR, Cream, aSheen);
                }
            }
        }

        return true;
    }

    /// <summary>
    /// Tessellate the two-quadratic teardrop (base at origin, tip at +len·x̂) into
    /// <see cref="_poly"/>, transformed by rotation <paramref name="ang"/> + translation.
    /// Byte-for-byte the same control points as the Swift <c>teardrop(len:halfW:…)</c>.
    /// </summary>
    private void Tessellate(double len, double halfW, double x, double y, double ang)
    {
        double ca = System.Math.Cos(ang), sa = System.Math.Sin(ang);
        int w = 0;
        // upper flank: P0=(0,0) → P1=(len,0), control (len*0.45,-halfW). include s=0..N-1.
        for (int s = 0; s < TessPerCurve; s++)
        {
            double u = (double)s / TessPerCurve;
            double omu = 1 - u;
            double lx = omu * omu * 0 + 2 * omu * u * (len * 0.45) + u * u * len;
            double ly = omu * omu * 0 + 2 * omu * u * (-halfW) + u * u * 0;
            _poly[w++] = new Vec2(x + lx * ca - ly * sa, y + lx * sa + ly * ca);
        }
        // lower flank: P0=(len,0) → P1=(0,0), control (len*0.45,halfW). include s=0..N-1.
        for (int s = 0; s < TessPerCurve; s++)
        {
            double u = (double)s / TessPerCurve;
            double omu = 1 - u;
            double lx = omu * omu * len + 2 * omu * u * (len * 0.45) + u * u * 0;
            double ly = omu * omu * 0 + 2 * omu * u * halfW + u * u * 0;
            _poly[w++] = new Vec2(x + lx * ca - ly * sa, y + lx * sa + ly * ca);
        }
    }
}
