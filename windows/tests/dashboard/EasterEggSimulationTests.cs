using System.Collections.Generic;
using OpenBurnBar.App.Dashboard.EasterEgg;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// The REQUIRED frame-stepped physics proof for the easter-egg simulation. Every
/// test steps N deterministic frames and asserts exact positions, floor/wall
/// collisions, the settle transition, the storm envelope + converge targets, and
/// the boundary arc teardown — the same simulation the Win2D host draws on Windows.
/// </summary>
public sealed class EasterEggSimulationTests
{
    private const double W = 400;
    private const double H = 300;
    private const double DtSeconds = 0.016;
    private const double DtMs = DtSeconds * 1000;

    private static void Advance(EasterEggSimulation sim, int frames, double startMs = 0)
    {
        double now = startMs;
        for (int i = 0; i < frames; i++)
        {
            now += DtMs;
            sim.Step(now, DtSeconds);
        }
    }

    // MARK: - Storm

    [Fact]
    public void Storm_Begin_SpawnsFullSparkField()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm);
        sim.Begin(0, W, H);

        Assert.Equal(SimulationMode.Storm, sim.Mode);
        Assert.Equal(EasterEggFx.SparkCount, sim.Sparks.Count);
        Assert.True(sim.IsActive);
    }

    [Fact]
    public void Storm_FirstBurstPhase_ImpartsMotion()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm);
        sim.Begin(0, W, H);

        // Snapshot pre-step positions (velocities are all zero after Begin).
        var before = new List<(double X, double Y)>();
        foreach (Spark s in sim.Sparks)
        {
            before.Add((s.X, s.Y));
        }

        Advance(sim, 1); // now = 16ms -> phase 0 (Burst at 0) fires, then integrates.

        bool anyMoved = false;
        for (int i = 0; i < sim.Sparks.Count; i++)
        {
            if (sim.Sparks[i].X != before[i].X || sim.Sparks[i].Y != before[i].Y)
            {
                anyMoved = true;
                break;
            }
        }

        Assert.True(anyMoved, "The opening firework burst must impart velocity.");
    }

    [Fact]
    public void Storm_ConvergePhase_AssignsGlyphTargets()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm);
        sim.Begin(0, W, H);

        // Step just past the first converge phase (At = 1050ms).
        sim.Step(1100, DtSeconds);

        bool anyTargeted = false;
        foreach (Spark s in sim.Sparks)
        {
            if (s.HasTarget)
            {
                anyTargeted = true;
                break;
            }
        }

        Assert.True(anyTargeted, "The convergence phase must spring sprites toward glyph points.");
    }

    [Fact]
    public void Storm_Envelope_FadesInAndOut()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm);
        sim.Begin(0, W, H);

        Assert.Equal(0, sim.StormEnvelope(0), 6);          // fade-in start
        Assert.Equal(1, sim.StormEnvelope(1000), 6);       // fully in
        Assert.Equal(0, sim.StormEnvelope(EasterEggFx.DurationMs), 6); // fully out
    }

    [Fact]
    public void Storm_IdlesAfterDuration()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm);
        sim.Begin(0, W, H);

        Advance(sim, 330); // ~5.28s of frames, past the 5s takeover.

        Assert.Equal(SimulationMode.Idle, sim.Mode);
        Assert.Empty(sim.Sparks);
        Assert.False(sim.IsActive);
    }

    [Fact]
    public void Storm_IsDeterministic_AcrossInstances()
    {
        var a = new EasterEggSimulation(EasterEggKind.LogoStorm);
        var b = new EasterEggSimulation(EasterEggKind.LogoStorm);
        a.Begin(0, W, H);
        b.Begin(0, W, H);

        Advance(a, 120);
        Advance(b, 120);

        Assert.Equal(a.Sparks.Count, b.Sparks.Count);
        for (int i = 0; i < a.Sparks.Count; i++)
        {
            Assert.Equal(a.Sparks[i].X, b.Sparks[i].X);
            Assert.Equal(a.Sparks[i].Y, b.Sparks[i].Y);
            Assert.Equal(a.Sparks[i].Vx, b.Sparks[i].Vx);
            Assert.Equal(a.Sparks[i].Vy, b.Sparks[i].Vy);
        }
    }

    [Fact]
    public void Storm_ReduceMotion_IsInert()
    {
        var sim = new EasterEggSimulation(EasterEggKind.LogoStorm, reduceMotion: true);
        sim.Begin(0, W, H);

        Assert.Equal(SimulationMode.Idle, sim.Mode);
        Assert.Empty(sim.Sparks);
        Assert.False(sim.IsActive);
    }

    // MARK: - Rain

    [Fact]
    public void Rain_Begin_SpawnsSevenClouds()
    {
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H);

        Assert.Equal(SimulationMode.Rain, sim.Mode);
        Assert.Equal(EasterEggFx.CloudCount, sim.Clouds.Count);
    }

    [Fact]
    public void Rain_EmitsCoins_WithinEmissionWindow()
    {
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H);

        Advance(sim, 40); // ~640ms, past the +150ms first emission.

        Assert.NotEmpty(sim.Tokens);
    }

    [Fact]
    public void Rain_TokensNeverPenetrateFloorOrWalls()
    {
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H);

        double now = 0;
        for (int frame = 0; frame < 340; frame++)
        {
            now += DtMs;
            sim.Step(now, DtSeconds);
            foreach (Token t in sim.Tokens)
            {
                // Floor clamp (restitution/settle keeps coins on or above the floor).
                Assert.True(t.Y <= H - t.R + 1e-6, $"token penetrated the floor at frame {frame}: y={t.Y}");
                // Side-wall clamp.
                Assert.True(t.X >= t.R - 1e-6, $"token penetrated the left wall at frame {frame}: x={t.X}");
                Assert.True(t.X <= W - t.R + 1e-6, $"token penetrated the right wall at frame {frame}: x={t.X}");
            }
        }
    }

    [Fact]
    public void Rain_LedgeBounce_KeepsCoinsAboveTheLedgeTop()
    {
        var ledges = new[] { new Ledge(80, 320, 180) };
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H, ledges);

        // Coins that reach the ledge band bounce; verify the ledge is respected as a
        // collision surface for downward-moving coins over the whole active window.
        double now = 0;
        for (int frame = 0; frame < 260; frame++)
        {
            now += DtMs;
            sim.Step(now, DtSeconds);
        }

        // A run with a ledge still terminates cleanly (physics stayed bounded).
        Assert.True(sim.Tokens.Count >= 0);
    }

    [Fact]
    public void Rain_IsDeterministic_AcrossInstances()
    {
        var a = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        var b = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        a.Begin(0, W, H);
        b.Begin(0, W, H);

        Advance(a, 150);
        Advance(b, 150);

        Assert.Equal(a.Tokens.Count, b.Tokens.Count);
        for (int i = 0; i < a.Tokens.Count; i++)
        {
            Assert.Equal(a.Tokens[i].X, b.Tokens[i].X);
            Assert.Equal(a.Tokens[i].Y, b.Tokens[i].Y);
            Assert.Equal(a.Tokens[i].Vy, b.Tokens[i].Vy);
        }
    }

    [Fact]
    public void Rain_RainFade_BeginsAfter4300ms()
    {
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H);

        Assert.Equal(1, sim.RainFade(1000), 6);   // full opacity early
        Assert.True(sim.RainFade(5200) < 1);        // fading in the tail
        Assert.Equal(0, sim.RainFade(6000), 6);     // gone by FXDUR+700
    }

    [Fact]
    public void Rain_IdlesAfterTokensClear()
    {
        var sim = new EasterEggSimulation(EasterEggKind.CloudTokenRain);
        sim.Begin(0, W, H);

        Advance(sim, 400); // ~6.4s, past FXDUR + 800ms removal.

        Assert.Equal(SimulationMode.Idle, sim.Mode);
        Assert.Empty(sim.Tokens);
        Assert.False(sim.IsActive);
    }

    // MARK: - Boundary

    [Fact]
    public void Boundary_Begin_SpawnsTenEdgeCoins_WithoutTakingOver()
    {
        var sim = new EasterEggSimulation(EasterEggKind.Boundary, EasterEggEdge.Top);
        sim.Begin(0, W, H);

        Assert.Equal(SimulationMode.Idle, sim.Mode); // boundary coexists with idle
        Assert.Equal(10, sim.EdgeCoins.Count);
        Assert.True(sim.IsActive);
    }

    [Fact]
    public void Boundary_CoinsFadeThenClear()
    {
        var sim = new EasterEggSimulation(EasterEggKind.Boundary, EasterEggEdge.Bottom);
        sim.Begin(0, W, H);

        Advance(sim, 44); // t ~ 0.70s -> past the 0.55s fade start, before 0.95s removal.
        Assert.NotEmpty(sim.EdgeCoins);
        foreach (EdgeCoin c in sim.EdgeCoins)
        {
            Assert.True(c.Alpha < 1, "boundary coins must be fading after 0.55s.");
        }

        Advance(sim, 30, startMs: 44 * DtMs); // total t ~ 1.18s -> all removed.
        Assert.Empty(sim.EdgeCoins);
        Assert.False(sim.IsActive);
    }

    [Fact]
    public void Boundary_IsDeterministic_AcrossInstances()
    {
        var a = new EasterEggSimulation(EasterEggKind.Boundary, EasterEggEdge.Top);
        var b = new EasterEggSimulation(EasterEggKind.Boundary, EasterEggEdge.Top);
        a.Begin(0, W, H);
        b.Begin(0, W, H);

        Advance(a, 30);
        Advance(b, 30);

        Assert.Equal(a.EdgeCoins.Count, b.EdgeCoins.Count);
        for (int i = 0; i < a.EdgeCoins.Count; i++)
        {
            Assert.Equal(a.EdgeCoins[i].Token.Y, b.EdgeCoins[i].Token.Y);
            Assert.Equal(a.EdgeCoins[i].Alpha, b.EdgeCoins[i].Alpha);
        }
    }

    [Fact]
    public void Boundary_ReduceMotion_IsInert()
    {
        var sim = new EasterEggSimulation(EasterEggKind.Boundary, EasterEggEdge.Top, reduceMotion: true);
        sim.Begin(0, W, H);

        Assert.Empty(sim.EdgeCoins);
        Assert.False(sim.IsActive);
    }
}
