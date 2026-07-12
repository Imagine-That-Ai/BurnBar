using OpenBurnBar.Integrations.Mercury.Budget;
using OpenBurnBar.Integrations.Mercury.Sessions;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaBudgetTests
{
    [Fact]
    public void NormalEnvelope_MatchesCapabilityMatrix()
    {
        var e = MediaBudgetEnvelope.Normal;
        Assert.Equal(120, e.ScreenShareDailyMinutes);
        Assert.Equal(60, e.ScreenSharePerSessionMinutes);
        Assert.Equal(240, e.VideoCallDailyMinutes);
        Assert.Equal(30, e.VideoCallPerCallMinutes);
        Assert.Equal(5, e.FileTransferDailyGbIn);
        Assert.Equal(5, e.FileTransferDailyGbOut);
    }

    [Fact]
    public void SoftCapEnvelope_TightensCaps()
    {
        var e = MediaBudgetEnvelope.SoftCap;
        Assert.Equal(30, e.ScreenShareDailyMinutes);
        Assert.Equal(30, e.ScreenSharePerSessionMinutes);
        Assert.Equal(120, e.VideoCallDailyMinutes);
        Assert.Equal(20, e.VideoCallPerCallMinutes);
        Assert.Equal(2, e.FileTransferDailyGbIn);
        Assert.Equal(2, e.FileTransferDailyGbOut);
    }

    [Fact]
    public void HardCapEnvelope_IsAllZero_AndDeniesEverySession()
    {
        var e = MediaBudgetEnvelope.HardCap;
        Assert.Equal(0, e.ScreenShareDailyMinutes);
        Assert.False(e.AllowsSession(MediaFeature.FileTransfer));
        Assert.False(e.AllowsSession(MediaFeature.ScreenShare));
        Assert.False(e.AllowsSession(MediaFeature.VideoCall));
        Assert.False(e.AllowsSession(MediaFeature.ComputerUse));
    }

    [Fact]
    public void AllowsSession_NormalEnvelope_AllowsAllFeatures()
    {
        var e = MediaBudgetEnvelope.Normal;
        Assert.True(e.AllowsSession(MediaFeature.FileTransfer));
        Assert.True(e.AllowsSession(MediaFeature.ScreenShare));
        Assert.True(e.AllowsSession(MediaFeature.VideoCall));
        Assert.True(e.AllowsSession(MediaFeature.ComputerUse));
    }

    [Fact]
    public void AllowsSession_FileTransfer_TrueIfEitherDirectionHasBudget()
    {
        Assert.True(new MediaBudgetEnvelope(0, 0, 0, 0, 1, 0).AllowsSession(MediaFeature.FileTransfer));
        Assert.True(new MediaBudgetEnvelope(0, 0, 0, 0, 0, 1).AllowsSession(MediaFeature.FileTransfer));
        Assert.False(new MediaBudgetEnvelope(0, 0, 0, 0, 0, 0).AllowsSession(MediaFeature.FileTransfer));
    }

    [Theory]
    [InlineData("normal", MediaBudgetLevel.Normal)]
    [InlineData("soft_cap", MediaBudgetLevel.SoftCap)]
    [InlineData("hard_cap", MediaBudgetLevel.HardCap)]
    [InlineData("garbage", MediaBudgetLevel.Normal)]
    [InlineData(null, MediaBudgetLevel.Normal)]
    public void LevelWire_ParsesWithNormalFallback(string? raw, MediaBudgetLevel expected)
    {
        Assert.Equal(expected, MediaBudgetLevelWire.Parse(raw));
    }

    [Theory]
    [InlineData(MediaBudgetLevel.Normal, "normal")]
    [InlineData(MediaBudgetLevel.SoftCap, "soft_cap")]
    [InlineData(MediaBudgetLevel.HardCap, "hard_cap")]
    public void LevelWire_SerializesToWireString(MediaBudgetLevel level, string expected)
    {
        Assert.Equal(expected, MediaBudgetLevelWire.ToWire(level));
    }
}
