using System;
using System.Runtime.CompilerServices;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Math;

/// <summary>
/// C# port of the Swift Core substrate math kit
/// (<c>Views/Substrate/SubstrateKit.cs</c> ⟵ <c>SubstrateKit.swift</c>, itself a
/// port of imaginethat-llc <c>kit-math.ts</c>). Every bespoke painter writes
/// against these primitives with zero cross-coordination, and the hash / breathe
/// flavors are bit-for-bit identical to the Swift originals so a per-point phase
/// resolves to the same value on macOS and Windows.
/// </summary>
public static class SubstrateKit
{
    public const double Tau = System.Math.PI * 2;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double ClampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Lerp(double a, double b, double t) => a + (b - a) * t;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Frac(double x) => x - System.Math.Floor(x);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Smoothstep(double e0, double e1, double x)
    {
        double denom = (e1 - e0) == 0 ? 1 : (e1 - e0);
        double t = ClampD((x - e0) / denom, 0, 1);
        return t * t * (3 - 2 * t);
    }

    /// <summary>
    /// Cheap, well-distributed hash → 0…1. Matches the Swift <c>shash</c> flavor
    /// (<c>frac(sin(x*91.7+13.13)*43758.5453)</c>) exactly. Deterministic; good for
    /// per-point phase/jitter.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Shash(double x) => Frac(System.Math.Sin(x * 91.7 + 13.13) * 43758.5453);

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Shash2(double x, double y) => Frac(System.Math.Sin(x * 91.7 + y * 47.13 + 13.13) * 43758.5453);

    /// <summary>0…1 "breathing" oscillator. <paramref name="phase"/> offsets per-point; <paramref name="rate"/> scales speed.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public static double Breathe(double t, double phase = 0, double rate = 1) => 0.5 + 0.5 * System.Math.Sin(t * rate + phase);

    /// <summary>Tiny deterministic RNG for per-point variation that must be stable per layout (port of Swift <c>XorShift32</c>).</summary>
    public struct XorShift32
    {
        private uint _s;

        public XorShift32(uint seed = 0x1234_5678) => _s = seed == 0 ? 0x1234_5678 : seed;

        public uint NextU()
        {
            _s ^= _s << 13;
            _s ^= _s >> 17;
            _s ^= _s << 5;
            return _s;
        }

        /// <summary>Next double in [0, 1).</summary>
        public double Next() => (NextU() >> 8) / (double)(1 << 24);

        public double Range(double lo, double hi) => lo + (hi - lo) * Next();
    }

    /// <summary>6-stop iris jewel ramp used by the mesh/moire families (port of Swift <c>SubstrateRamp.iris</c>).</summary>
    public static readonly Rgba[] Iris =
    {
        new Rgba(0.42, 0.36, 1.0),   // iris
        new Rgba(0.30, 0.72, 0.96),  // cyan
        new Rgba(0.36, 0.95, 0.78),  // mint
        new Rgba(1.0, 0.82, 0.36),   // gold
        new Rgba(1.0, 0.45, 0.62),   // rose
        new Rgba(0.67, 0.40, 1.0),   // violet
    };

    /// <summary>Sample a ramp at 0…1 with linear interpolation (wraps). Port of Swift <c>SubstrateRamp.sample</c>.</summary>
    public static Rgba SampleRamp(Rgba[] ramp, double t)
    {
        if (ramp.Length <= 1) return ramp.Length == 1 ? ramp[0] : new Rgba(1, 1, 1);
        double x = Frac(t) * (ramp.Length - 1);
        int i = (int)System.Math.Floor(x);
        double f = x - i;
        Rgba a = ramp[i];
        Rgba b = ramp[System.Math.Min(ramp.Length - 1, i + 1)];
        return a.Mix(b, f);
    }
}
