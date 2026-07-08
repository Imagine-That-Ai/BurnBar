using System;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Ambient particle backdrop for the Mission Control console. Feeds the landed Win2D
/// <see cref="OpenBurnBar.App.Particles.SwarmCanvasHost"/> a per-frame
/// <see cref="SwarmSubstrateFrame"/> of gently-drifting ember motes so the console canvas
/// stays alive behind the glass — the Windows analog of the SwiftUI console backdrop's soft
/// ember/aureate glow. It uses the plain-dots render path (the substrate painter defers to
/// the host's built-in dot loop), so no GPU substrate is required for this ambient layer.
/// </summary>
/// <remarks>
/// Deterministic + allocation-light: dot seeds are computed once; each frame advances a
/// curl-ish sine drift. In production a richer field can be swapped in by pointing the
/// canvas host's substrate at any landed <c>ISwarmSubstrate</c>; this provider only supplies
/// the frame snapshot the renderer consumes.
/// </remarks>
public sealed class MissionBackdropFrameProvider
{
    private const int DotCount = 90;

    private readonly double[] _seedX = new double[DotCount];
    private readonly double[] _seedY = new double[DotCount];
    private readonly double[] _phase = new double[DotCount];
    private readonly double[] _size = new double[DotCount];
    private readonly double[] _colorIndex = new double[DotCount];

    // Ember / aureate ambient palette (matches the macOS console backdrop glow).
    private static readonly Rgba Ember = new(0.98, 0.42, 0.02, 1.0);
    private static readonly Rgba Aureate = new(0.91, 0.66, 0.24, 1.0);

    public MissionBackdropFrameProvider()
    {
        var rng = new Random(0x8EED);
        for (int i = 0; i < DotCount; i++)
        {
            _seedX[i] = rng.NextDouble();
            _seedY[i] = rng.NextDouble();
            _phase[i] = rng.NextDouble() * Math.PI * 2;
            _size[i] = 0.8 + (rng.NextDouble() * 1.5); // 0.8..2.3, matching the engine seed range
            _colorIndex[i] = rng.NextDouble();
        }
    }

    /// <summary>Build the ambient frame for a canvas of the given size at <paramref name="seconds"/>.</summary>
    public SwarmSubstrateFrame Build(double width, double height, double seconds)
    {
        if (width <= 0 || height <= 0)
        {
            width = 1;
            height = 1;
        }

        var dots = new SwarmSubstrateDot[DotCount];
        double t = seconds;
        double sumX = 0;
        double sumY = 0;

        for (int i = 0; i < DotCount; i++)
        {
            // Curl-ish drift: two out-of-phase sines nudge each seed around its home.
            double driftX = Math.Sin((t * 0.13) + _phase[i]) * 22.0;
            double driftY = Math.Cos((t * 0.11) + (_phase[i] * 1.3)) * 18.0;

            double x = (_seedX[i] * width) + driftX;
            double y = (_seedY[i] * height) + driftY;
            sumX += x;
            sumY += y;

            double radius = Math.Max(0.4, _size[i] * 0.85);
            double opacity = 0.10 + (0.10 * (0.5 + (0.5 * Math.Sin((t * 0.5) + _phase[i]))));
            Rgba color = Ember.Mix(Aureate, _colorIndex[i]);
            var tinted = new Rgba(color.R, color.G, color.B, opacity);

            dots[i] = new SwarmSubstrateDot(
                x: x, y: y, vx: driftX, vy: driftY,
                radius: radius, baseSize: _size[i], rgba: tinted, opacity: opacity,
                inShape: false, colorIndex: _colorIndex[i], flowProgress: 0);
        }

        double cx = sumX / DotCount;
        double cy = sumY / DotCount;

        var stage = new SubstrateStage(Ember, Aureate, new Rgba(0.09, 0.03, 0.02, 1.0), dark: true);

        return new SwarmSubstrateFrame(
            width: width, height: height, dark: true, reduced: false, batteryThrottled: false,
            uiMode: UIMode.Standard, isShapeMode: false, formed: false, settleProgress: 0,
            t: t, dt: 1.0, stage: stage, backdrop: null,
            dots: dots, cx: cx, cy: cy, cloudRadius: Math.Min(width, height) * 0.5,
            sizePx: 1.2);
    }
}
