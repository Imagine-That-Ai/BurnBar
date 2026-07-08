using System;

namespace OpenBurnBar.App.Theme;

// MARK: - Liquid Glass transparency preference (pure math core)
//
// This is the PLATFORM-AGNOSTIC, parity-critical half of the W6-DS-GLASS chokepoint —
// a byte-for-byte port of the Swift `enum LiquidGlassTransparency`
// (AgentLens/Theme/LiquidGlass.swift). It has ZERO WinUI dependency (only `System`), so
// it compiles and runs on any host and can be asserted against the Swift golden values
// (see windows/tests/theme/LiquidGlassTransparencyTests.cs). The WinUI adapters that
// consume these numbers live in LiquidGlass.cs; the OS-capability default for the
// content-surfaces toggle lives there too (LiquidGlass.DefaultContentSurfacesEnabled),
// mirroring how the Swift `defaultContentSurfacesEnabled` uses `#available(macOS 26)`.

/// <summary>
/// User-adjustable glass transparency, ported verbatim from the Swift
/// <c>LiquidGlassTransparency</c> enum. The math is intentionally identical so the
/// Windows and macOS builds resolve the same effective value for the same stored
/// preference.
///
/// Semantics of the stored value <c>t</c> (clamped to -1…1):
///   • <c>t == 0</c> — system default. Mica renders as the OS does (which already
///     honors System &gt; Accessibility &gt; Transparency effects).
///   • <c>t &gt; 0</c> — clearer. The backdrop switches to DesktopAcrylic (more
///     see-through than Mica), bridged by a faint scrim so content stays legible.
///   • <c>t &lt; 0</c> — frostier. Mica flips to the BaseAlt kind and a thick frost
///     scrim slides in between the backdrop and the content, approaching opaque at -1.
///
/// Reduce Transparency always wins over "clearer": when Windows reports transparency
/// effects OFF (<see cref="LiquidGlassEnvironment.ReduceTransparency"/>), positive
/// values resolve to 0 so glass never becomes MORE transparent than the system allows.
/// Frostier values still apply — they only add opacity, the direction the flag asks for.
/// </summary>
/// <remarks>Swift original: <c>enum LiquidGlassTransparency</c>.</remarks>
public static class LiquidGlassTransparency
{
    /// <summary>Preference key, shared spelling with the Swift/iOS mirror.
    /// Swift: <c>LiquidGlassTransparency.storageKey</c>.</summary>
    public const string StorageKey = "liquidGlassTransparency";

    /// <summary>Content-surface toggle key. Swift: <c>contentSurfacesEnabledKey</c>.</summary>
    public const string ContentSurfacesEnabledKey = "liquidGlassContentSurfacesEnabled";

    /// <summary>Lower bound of the stored preference. Swift: <c>range.lowerBound</c>.</summary>
    public const double RangeLowerBound = -1.0;

    /// <summary>Upper bound of the stored preference. Swift: <c>range.upperBound</c>.</summary>
    public const double RangeUpperBound = 1.0;

    /// <summary>
    /// Resolve the raw stored value against the accessibility state.
    /// Swift: <c>static func effective(_ raw:reduceTransparency:)</c> — a byte-for-byte port:
    /// non-finite -&gt; 0; clamp to [-1,1]; if reduce-transparency and <c>t &gt; 0</c> -&gt; 0.
    /// </summary>
    public static double Effective(double raw, bool reduceTransparency)
    {
        if (double.IsNaN(raw) || double.IsInfinity(raw))
        {
            return 0;
        }

        double t = Math.Min(Math.Max(raw, RangeLowerBound), RangeUpperBound);
        return (reduceTransparency && t > 0) ? 0 : t;
    }

    /// <summary>Whether the plate should use the clearer (Acrylic) variant.
    /// Swift: <c>usesClearGlass(_:)</c> — <c>t &gt; 0.001</c>.</summary>
    public static bool UsesClearGlass(double t) => t > 0.001;

    /// <summary>Opacity of the thick frost scrim between backdrop and content.
    /// Swift: <c>frostScrimOpacity(_:)</c> — <c>t &lt; 0 ? 0.9 * -t : 0</c>.</summary>
    public static double FrostScrimOpacity(double t) => t < 0 ? 0.9 * -t : 0;

    /// <summary>
    /// A faint scrim that bridges the Mica-&gt;Acrylic jump just past center, fading out
    /// as <c>t</c> approaches +1 but stopping at a small floor so the plate never
    /// disappears completely. Keeps the preference continuous and content legible even at
    /// 100% clear. Swift: <c>clearBridgeScrimOpacity(_:)</c> —
    /// <c>usesClearGlass ? max(0.06, 0.14 * (1 - t)) : 0</c>.
    /// </summary>
    public static double ClearBridgeScrimOpacity(double t)
    {
        if (!UsesClearGlass(t))
        {
            return 0;
        }

        return Math.Max(0.06, 0.14 * (1 - t));
    }

    /// <summary>Opacity of the solid fallback plate (when content surfaces are off, or on
    /// Windows 10 with no backdrop support). Swift: <c>fallbackPlateOpacity(_:)</c> —
    /// <c>t &gt; 0 ? 1 - 0.78 * t : 1</c>.</summary>
    public static double FallbackPlateOpacity(double t) => t > 0 ? 1 - 0.78 * t : 1;
}
