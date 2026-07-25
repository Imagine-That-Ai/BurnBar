using System;
using OpenBurnBar.Updater.Core.Host;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class BackgroundUpdateCheckResultTests
{
    [Fact]
    public void UpToDateDoesNotExposeCandidateMetadata()
    {
        BackgroundUpdateCheckResult result = BackgroundUpdateCheckResult.UpToDate;

        Assert.False(result.CandidateAvailable);
        Assert.Null(result.CandidateVersion);
    }

    [Fact]
    public void AvailableRequiresAndPreservesVerifiedVersion()
    {
        BackgroundUpdateCheckResult result = BackgroundUpdateCheckResult.Available("2.4.1");

        Assert.True(result.CandidateAvailable);
        Assert.Equal("2.4.1", result.CandidateVersion);
        Assert.Throws<ArgumentException>(() => BackgroundUpdateCheckResult.Available(" "));
    }
}
