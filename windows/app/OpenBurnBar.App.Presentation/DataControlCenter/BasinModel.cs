using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful) from the mercury-swirl geometry in
// AgentLens/Views/Settings/DataControlCenter/DataControlCenterBasin.swift (drawMercury /
// mercuryPath / sheenBand / bead loop / swirlPhase).
//
// The Basin is a live TimelineView + Canvas on macOS; on Windows it is a Win2D
// CanvasAnimatedControl (DataControlCenter/MercuryBasinHost.cs). The parity-critical part is the
// GEOMETRY — the meniscus wave, the sheen band, the drifting beads, and the fill→surface mapping.
// That math lives here so it is identical across platforms AND unit-tested on macOS, while the
// Win2D host is the thin GPU binding that only paints the returned points.

/// <summary>A 2-D point in canvas space.</summary>
public readonly record struct BasinPoint(double X, double Y);

/// <summary>A drifting mercury bead: centre + radius.</summary>
public readonly record struct BasinBead(double X, double Y, double Radius);

/// <summary>An axis-aligned rectangle (the specular sheen band).</summary>
public readonly record struct BasinRect(double X, double Y, double Width, double Height);

/// <summary>Pure mercury-basin geometry — deterministic in (size, fill, phase).</summary>
public static class BasinModel
{
    /// <summary>Swirl period default from the Pensieve <c>motionSwirlSeconds</c> token (18).</summary>
    public const double DefaultSwirlSeconds = 18.0;

    /// <summary>Meniscus wave amplitude (Swift <c>amplitude: CGFloat = 7</c>).</summary>
    public const double WaveAmplitude = 7.0;

    /// <summary>Wave sampling resolution (Swift <c>steps = 48</c>).</summary>
    public const int WaveSteps = 48;

    /// <summary>Drifting bead count (Swift <c>for index in 0..&lt;5</c>).</summary>
    public const int BeadCount = 5;

    /// <summary>Frozen phase used when reduce-motion is on (Swift <c>return 0.35</c>).</summary>
    public const double ReducedMotionPhase = 0.35;

    /// <summary>
    /// The 0…1 swirl phase at an elapsed time. When <paramref name="reduceMotion"/> is set the
    /// swirl is frozen at a representative phase. Swift: <c>swirlPhase(at:)</c>.
    /// </summary>
    public static double SwirlPhase(double elapsedSeconds, double swirlSeconds = DefaultSwirlSeconds, bool reduceMotion = false)
    {
        if (reduceMotion)
        {
            return ReducedMotionPhase;
        }

        double period = swirlSeconds <= 0 ? DefaultSwirlSeconds : swirlSeconds;
        double phase = (elapsedSeconds % period) / period;
        return phase < 0 ? phase + 1 : phase; // keep in [0,1) for negative elapsed
    }

    /// <summary>
    /// The mercury surface line height. Sits at (1 − fill) from the top but never quite full so the
    /// meniscus reads as liquid. Swift: <c>surfaceY = height * (1 - clamped * 0.92) - 6</c>.
    /// </summary>
    public static double SurfaceY(double height, double fill)
    {
        double clamped = fill < 0 ? 0 : fill > 1 ? 1 : fill;
        return (height * (1 - clamped * 0.92)) - 6;
    }

    /// <summary>
    /// The closed mercury body polygon: bottom-left → up to the surface → the swirling meniscus
    /// across the width → down to bottom-right → close. Faithful port of <c>mercuryPath</c>.
    /// </summary>
    public static IReadOnlyList<BasinPoint> MercuryOutline(double width, double height, double surfaceY, double phase)
    {
        var points = new List<BasinPoint>(WaveSteps + 4)
        {
            new(0, height),
            new(0, surfaceY),
        };

        for (int step = 0; step <= WaveSteps; step++)
        {
            double progress = (double)step / WaveSteps;
            double x = progress * width;
            double wave1 = Math.Sin((progress * Math.PI * 2) + (phase * Math.PI * 2)) * WaveAmplitude;
            double wave2 = Math.Sin((progress * Math.PI * 3) - (phase * Math.PI * 2)) * (WaveAmplitude * 0.5);
            points.Add(new BasinPoint(x, surfaceY + wave1 + wave2));
        }

        points.Add(new BasinPoint(width, height));
        return points;
    }

    /// <summary>
    /// The specular sheen band drifting across the surface. Swift: <c>sheenBand</c>
    /// (bandWidth = width*0.35; x = phase*(width+bandWidth) − bandWidth).
    /// </summary>
    public static BasinRect SheenBand(double width, double surfaceY, double phase)
    {
        double bandWidth = width * 0.35;
        double x = (phase * (width + bandWidth)) - bandWidth;
        return new BasinRect(x, surfaceY + 2, bandWidth, 5);
    }

    /// <summary>
    /// The drifting beads of mercury near the surface. Faithful port of the Swift bead loop
    /// (drift, bob, radius all derived from phase + index).
    /// </summary>
    public static IReadOnlyList<BasinBead> Beads(double width, double surfaceY, double phase)
    {
        var beads = new List<BasinBead>(BeadCount);
        for (int index = 0; index < BeadCount; index++)
        {
            double drift = (phase + ((double)index / BeadCount)) % 1.0;
            if (drift < 0)
            {
                drift += 1.0;
            }

            double x = drift * width;
            double bob = Math.Sin((phase + index) * Math.PI * 2) * 4;
            double y = surfaceY + 14 + bob + (index * 6);
            double radius = 2.5 + (index % 3);
            beads.Add(new BasinBead(x, y, radius));
        }

        return beads;
    }

    /// <summary>The overlaid caption ("<c>NN% sealed</c>"). Swift: <c>basinCaption</c>.</summary>
    public static string SealedCaption(double fill)
    {
        double clamped = fill < 0 ? 0 : fill > 1 ? 1 : fill;
        int pct = (int)Math.Round(clamped * 100, MidpointRounding.AwayFromZero);
        return $"{pct}% sealed";
    }
}
