namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>
/// A plain 2-component double vector — the portable stand-in for the Swift
/// <c>CGPoint</c> / <c>CGVector</c> used throughout <c>EasterEggScene.swift</c>.
/// A <see langword="readonly"/> struct so glyph-target and position snapshots
/// marshal as one contiguous block and compare by value in tests.
/// </summary>
public readonly struct Vec2
{
    public Vec2(double x, double y)
    {
        X = x;
        Y = y;
    }

    public double X { get; }

    public double Y { get; }

    public static Vec2 Zero => new(0, 0);
}
