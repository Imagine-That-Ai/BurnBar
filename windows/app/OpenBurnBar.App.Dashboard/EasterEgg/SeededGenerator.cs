namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>
/// A tiny deterministic random generator — a faithful C# port of the SplitMix64
/// <c>SeededGenerator</c> in <c>EasterEggScene.swift</c>. Each simulation seeds
/// one of these so its "randomness" is stable across redraws yet varied between
/// summons; the deterministic sequence is what lets the tests step N frames and
/// assert exact particle positions.
/// </summary>
/// <remarks>
/// Swift's <c>&amp;+</c> / <c>&amp;*</c> are wrapping (overflow-truncating)
/// operators; C# <see langword="ulong"/> arithmetic wraps too, so the
/// <c>unchecked</c> block reproduces the Swift math bit-for-bit. The public
/// <see cref="NextDouble(double,double)"/> mirrors the website's <c>rand(a,b)</c>
/// used everywhere in the scene (radii, angles, jitter).
/// </remarks>
public struct SeededGenerator
{
    // The seed the on-screen simulation uses (Swift: 0x0BB_EA57E_E66).
    public const long SimulationSeed = 0x0BBEA57EE66L;

    private ulong _state;

    public SeededGenerator(long seed)
    {
        unchecked
        {
            _state = (ulong)seed ^ 0x9E3779B97F4A7C15UL;
        }

        if (_state == 0)
        {
            _state = 0xDEADBEEFCAFEF00DUL;
        }
    }

    /// <summary>The raw SplitMix64 step — matches Swift <c>next()</c> exactly.</summary>
    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            ulong z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>
    /// A uniform value in <c>[0, bound)</c> — the portable form of Swift's
    /// <c>next() % UInt64(bound)</c> index picks (logo index, shape rotation…).
    /// </summary>
    public int NextIndex(int bound)
    {
        if (bound <= 0)
        {
            return 0;
        }

        return (int)(Next() % (ulong)bound);
    }

    /// <summary>
    /// Uniform double in <c>[a, b)</c> — the <c>rand(a, b)</c> of the website and
    /// the Swift generator's <c>d(_:_:)</c> / <c>cg(_:_:)</c>. Uses the top 53
    /// bits so the mantissa is filled exactly like the Swift path.
    /// </summary>
    public double NextDouble(double a, double b)
    {
        double unit = (Next() >> 11) * (1.0 / 9007199254740992.0); // 2^53
        return a + (unit * (b - a));
    }
}
