using OpenBurnBar.App.Dashboard.EasterEgg;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// Locks the SplitMix64 <see cref="SeededGenerator"/> — determinism is the property
/// the whole easter-egg field's reproducibility (and every physics test below) rests
/// on, so this is deliberately strict.
/// </summary>
public sealed class SeededGeneratorTests
{
    [Fact]
    public void SameSeed_ProducesIdenticalSequence()
    {
        var a = new SeededGenerator(SeededGenerator.SimulationSeed);
        var b = new SeededGenerator(SeededGenerator.SimulationSeed);
        for (int i = 0; i < 1000; i++)
        {
            Assert.Equal(a.Next(), b.Next());
        }
    }

    [Fact]
    public void DifferentSeed_Diverges()
    {
        var a = new SeededGenerator(1);
        var b = new SeededGenerator(2);
        bool anyDifferent = false;
        for (int i = 0; i < 100; i++)
        {
            if (a.Next() != b.Next())
            {
                anyDifferent = true;
                break;
            }
        }

        Assert.True(anyDifferent, "Distinct seeds must produce distinct streams.");
    }

    [Fact]
    public void ZeroSeed_DoesNotDegenerateToAllZeros()
    {
        // The Swift init substitutes a fixed non-zero state for a zero state; verify
        // the stream is live (all-zero would freeze every particle at the origin).
        var rng = new SeededGenerator(0);
        bool anyNonZero = false;
        for (int i = 0; i < 16; i++)
        {
            if (rng.Next() != 0)
            {
                anyNonZero = true;
                break;
            }
        }

        Assert.True(anyNonZero);
    }

    [Fact]
    public void NextDouble_StaysInHalfOpenRange()
    {
        var rng = new SeededGenerator(SeededGenerator.SimulationSeed);
        for (int i = 0; i < 10000; i++)
        {
            double v = rng.NextDouble(-3, 3);
            Assert.InRange(v, -3.0, 3.0);
        }
    }

    [Fact]
    public void NextIndex_StaysWithinBound()
    {
        var rng = new SeededGenerator(42);
        for (int i = 0; i < 10000; i++)
        {
            int v = rng.NextIndex(4);
            Assert.InRange(v, 0, 3);
        }
    }

    [Fact]
    public void NextIndex_NonPositiveBound_IsZero()
    {
        var rng = new SeededGenerator(42);
        Assert.Equal(0, rng.NextIndex(0));
        Assert.Equal(0, rng.NextIndex(-5));
    }
}
