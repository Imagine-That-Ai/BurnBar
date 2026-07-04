// The fail-closed update decision (Phase 5 · signed distribution).
//
// The single most important property: an entry that does NOT verify under the pinned key can
// never become UpdateAvailability.Available, regardless of how new it claims to be.

using System.Collections.Generic;
using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class UpdateDecisionTests
{
    private static UpdateHostContext Host(
        string installed = "1.0.28",
        UpdatePlatform platform = UpdatePlatform.WinX64,
        UpdateChannel channel = UpdateChannel.Stable,
        int osBuild = 22631) => new()
        {
            InstalledVersion = installed,
            Platform = platform,
            Channel = channel,
            OsBuild = osBuild,
        };

    private static UpdateDecisionEngine EngineFor(UpdateSigningKeyPair keys) =>
        new(DistTestSupport.VerifierFor(keys));

    [Fact]
    public void AuthenticNewerEntry_IsAvailable()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29"), keys);

        var result = EngineFor(keys).Decide(Host(), new[] { entry });

        Assert.Equal(UpdateAvailability.Available, result.Availability);
        Assert.Equal("1.0.29", result.Entry!.Version);
    }

    [Fact]
    public void UnsignedNewerEntry_IsNeverAvailable_FailClosed()
    {
        var keys = DistTestSupport.NewKeyPair();
        var unsigned = DistTestSupport.SampleEntry(version: "9.9.9"); // no signature

        var result = EngineFor(keys).Decide(Host(), new[] { unsigned });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
        Assert.Null(result.Entry);
    }

    [Fact]
    public void EntrySignedByWrongKey_IsNeverAvailable_FailClosed()
    {
        var pinned = DistTestSupport.NewKeyPair();
        var attacker = DistTestSupport.NewKeyPair();
        var forged = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "9.9.9"), attacker);

        var result = EngineFor(pinned).Decide(Host(), new[] { forged });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public void EqualVersion_IsUpToDate()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.28"), keys);

        var result = EngineFor(keys).Decide(Host(installed: "1.0.28"), new[] { entry });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public void OlderVersion_IsUpToDate_NoDowngrade()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.27"), keys);

        var result = EngineFor(keys).Decide(Host(installed: "1.0.28"), new[] { entry });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public void NewerButOsTooOld_IsBlockedByOsFloor()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29", minOsBuild: 26100), keys);

        var result = EngineFor(keys).Decide(Host(osBuild: 22631), new[] { entry });

        Assert.Equal(UpdateAvailability.BlockedByOsFloor, result.Availability);
        Assert.Equal("1.0.29", result.Entry!.Version);
    }

    [Fact]
    public void PlatformMismatch_IsDropped()
    {
        var keys = DistTestSupport.NewKeyPair();
        var armOnly = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29", platform: UpdatePlatform.WinArm64), keys);

        var result = EngineFor(keys).Decide(Host(platform: UpdatePlatform.WinX64), new[] { armOnly });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public void StableHost_DoesNotSeeBetaEntry()
    {
        var keys = DistTestSupport.NewKeyPair();
        var beta = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.1.0", channel: UpdateChannel.Beta), keys);

        var result = EngineFor(keys).Decide(Host(channel: UpdateChannel.Stable), new[] { beta });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public void BetaHost_SeesBetaAndStable()
    {
        var keys = DistTestSupport.NewKeyPair();
        var beta = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.1.0", channel: UpdateChannel.Beta), keys);

        var result = EngineFor(keys).Decide(Host(channel: UpdateChannel.Beta), new[] { beta });

        Assert.Equal(UpdateAvailability.Available, result.Availability);
    }

    [Fact]
    public void HighestAuthenticSurvivor_IsChosen()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entries = new List<UpdateFeedEntry>
        {
            DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29"), keys),
            DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.31"), keys),
            DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.30"), keys),
        };

        var result = EngineFor(keys).Decide(Host(installed: "1.0.28"), entries);

        Assert.Equal(UpdateAvailability.Available, result.Availability);
        Assert.Equal("1.0.31", result.Entry!.Version);
    }

    [Fact]
    public void ForgedHigherAmongGenuine_DoesNotWin()
    {
        var pinned = DistTestSupport.NewKeyPair();
        var attacker = DistTestSupport.NewKeyPair();
        var entries = new List<UpdateFeedEntry>
        {
            DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29"), pinned),   // genuine
            DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "9.9.9"), attacker),  // forged, higher
        };

        var result = EngineFor(pinned).Decide(Host(installed: "1.0.28"), entries);

        Assert.Equal(UpdateAvailability.Available, result.Availability);
        Assert.Equal("1.0.29", result.Entry!.Version); // the forged 9.9.9 is dropped
    }

    [Fact]
    public void UnparseableInstalledVersion_FailsClosedToUpToDate()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.Sign(DistTestSupport.SampleEntry(version: "1.0.29"), keys);

        var result = EngineFor(keys).Decide(Host(installed: "not-a-version"), new[] { entry });

        Assert.Equal(UpdateAvailability.UpToDate, result.Availability);
    }
}
