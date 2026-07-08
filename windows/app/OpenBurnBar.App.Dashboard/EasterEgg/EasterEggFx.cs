namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>
/// Tunable constants for the easter-egg field — a verbatim port of the
/// <c>EasterEggFX</c> enum in <c>EasterEggScene.swift</c> (itself mirroring the
/// burnbar.ai <c>#bgFx</c> engine). Kept in one place so the simulation and the
/// Win2D host agree on counts, durations, and the shape set.
/// </summary>
public static class EasterEggFx
{
    /// <summary>Takeover length for both storm and rain, in milliseconds.</summary>
    public const double DurationMs = 5000;

    /// <summary>Takeover length in seconds.</summary>
    public const double DurationSeconds = DurationMs / 1000.0;

    /// <summary>The four shapes the logo storm converges into.</summary>
    public static readonly string[] Shapes = { "$", ":)", "</>", "{ }" };

    // Storm ------------------------------------------------------------------

    /// <summary>Number of sprites that burst in the logo storm.</summary>
    public const int SparkCount = 96;

    // Rain -------------------------------------------------------------------

    /// <summary>Number of drifting clouds in the token rain.</summary>
    public const int CloudCount = 7;

    /// <summary>Downward gravity for rain coins (points/s^2).</summary>
    public const double Gravity = 980;
}
