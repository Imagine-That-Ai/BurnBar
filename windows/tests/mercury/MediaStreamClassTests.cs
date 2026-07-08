using OpenBurnBar.Integrations.Mercury.Sessions;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaStreamClassTests
{
    [Theory]
    [InlineData("media.blob.advertise", MediaFeature.FileTransfer)]
    [InlineData("media.blob.fetch", MediaFeature.FileTransfer)]
    [InlineData("media.blob", MediaFeature.FileTransfer)]
    [InlineData("media.screen.video", MediaFeature.ScreenShare)]
    [InlineData("media.audio.out", MediaFeature.VideoCall)]
    [InlineData("media.audio.in", MediaFeature.VideoCall)]
    [InlineData("media.video.out", MediaFeature.VideoCall)]
    [InlineData("media.video.in", MediaFeature.VideoCall)]
    [InlineData("control.surface.frame", MediaFeature.ComputerUse)]
    [InlineData("control.action.log", MediaFeature.ComputerUse)]
    [InlineData("control.input", MediaFeature.ComputerUse)]
    [InlineData("control.approval", MediaFeature.ComputerUse)]
    public void Feature_MapsClassOntoBucket(string raw, MediaFeature expected)
    {
        Assert.Equal(expected, new MediaStreamClass(raw).Feature);
    }

    [Theory]
    [InlineData("media.control")]
    [InlineData("media.classify")]
    [InlineData("some.future.class")]
    public void Feature_IsNullForNonChargedClasses(string raw)
    {
        Assert.Null(new MediaStreamClass(raw).Feature);
    }

    [Theory]
    [InlineData("media.blob", 1, true)]
    [InlineData("media.blob", 0, false)]
    [InlineData("media.screen.video", 3, true)]
    [InlineData("media.screen.video", 2, false)]
    [InlineData("media.audio.out", 4, true)]
    [InlineData("media.audio.out", 3, false)]
    [InlineData("media.video.out", 5, true)]
    [InlineData("media.video.out", 4, false)]
    [InlineData("control.surface.frame", 8, true)]
    [InlineData("control.surface.frame", 7, false)]
    [InlineData("control.input", 12, true)]
    [InlineData("control.input", 11, false)]
    public void IsAvailable_GatesOnRolloutPhase(string raw, int phase, bool expected)
    {
        Assert.Equal(expected, new MediaStreamClass(raw).IsAvailable(phase));
    }

    [Fact]
    public void UnknownClass_IsNeverAvailable()
    {
        Assert.False(new MediaStreamClass("brand.new.class").IsAvailable(99));
    }

    [Fact]
    public void Equality_IsByRawValue()
    {
        Assert.Equal(MediaStreamClass.ScreenVideo, new MediaStreamClass("media.screen.video"));
        Assert.NotEqual(MediaStreamClass.ScreenVideo, MediaStreamClass.AudioOut);
    }
}
