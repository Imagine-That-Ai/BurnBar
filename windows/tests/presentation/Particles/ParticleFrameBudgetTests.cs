using System;
using OpenBurnBar.App.Presentation.Particles;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Particles;

public sealed class ParticleFrameBudgetTests
{
    [Fact]
    public void Evaluate_16ms_Meets60FpsBudget()
    {
        ParticleFrameSample sample = ParticleFrameBudget.Evaluate(TimeSpan.FromMilliseconds(16.0));
        Assert.True(sample.MeetsBudget);
        Assert.InRange(sample.Fps, 55, 65);
    }

    [Fact]
    public void Evaluate_33ms_Misses60FpsBudget()
    {
        ParticleFrameSample sample = ParticleFrameBudget.Evaluate(TimeSpan.FromMilliseconds(33.0));
        Assert.False(sample.MeetsBudget);
    }

    [Fact]
    public void Simulate_ReportsAverage()
    {
        ParticleFrameReport report = ParticleFrameBudget.Simulate(10, TimeSpan.FromMilliseconds(16));
        Assert.Equal(10, report.Frames);
        Assert.Equal(10, report.FramesOnBudget);
        Assert.Equal(60.0, report.TargetFps);
    }
}
