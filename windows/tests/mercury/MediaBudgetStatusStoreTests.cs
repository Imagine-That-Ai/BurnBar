using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Mercury.Budget;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaBudgetStatusStoreTests
{
    private static MediaBudgetStatus NormalStatus() =>
        new(MediaBudgetLevel.Normal, 0, 0, DateTimeOffset.UnixEpoch, MediaBudgetEnvelope.Normal);

    [Fact]
    public void ColdStart_ResolvesToConservativeClosed_NotInitialNormal()
    {
        var store = new MediaBudgetStatusStore();
        Assert.Equal(MediaBudgetStatusStore.ConservativeClosed, store.EffectiveStatus);
        Assert.Equal(MediaBudgetLevel.HardCap, store.EffectiveStatus.Level);
        Assert.NotEqual(MediaBudgetStatusStore.InitialNormal, store.EffectiveStatus);
    }

    [Fact]
    public void ApplyPublicEnvelope_SetsLatestAndLastKnown_AndFiresCallback()
    {
        var store = new MediaBudgetStatusStore();
        MediaBudgetStatus? observed = null;
        store.OnStatusChanged = s => observed = s;

        store.ApplyPublicEnvelope(NormalStatus());

        Assert.Equal(NormalStatus(), store.LatestStatus);
        Assert.Equal(NormalStatus(), store.LastKnownStatus);
        Assert.Equal(NormalStatus(), store.EffectiveStatus);
        Assert.Equal(NormalStatus(), observed);
    }

    [Fact]
    public void PermissionDeniedWhileSignedIn_WithLastKnown_HoldsLastKnown()
    {
        var store = new MediaBudgetStatusStore();
        store.ApplyPublicEnvelope(NormalStatus());

        store.HandleListenerError(MediaBudgetListenerError.PermissionDenied, isSignedIn: true);

        Assert.True(store.FailClosedDueToPermissionDenied);
        Assert.Equal(NormalStatus(), store.EffectiveStatus);
    }

    [Fact]
    public void PermissionDeniedWhileSignedIn_WithoutLastKnown_FallsToConservativeClosed()
    {
        var store = new MediaBudgetStatusStore();

        store.HandleListenerError(MediaBudgetListenerError.PermissionDenied, isSignedIn: true);

        Assert.True(store.FailClosedDueToPermissionDenied);
        Assert.Null(store.LatestStatus);
        Assert.Equal(MediaBudgetStatusStore.ConservativeClosed, store.EffectiveStatus);
    }

    [Fact]
    public void PermissionDeniedWhileSignedOut_DoesNotFailClosed()
    {
        var store = new MediaBudgetStatusStore();
        store.ApplyPublicEnvelope(NormalStatus());

        store.HandleListenerError(MediaBudgetListenerError.PermissionDenied, isSignedIn: false);

        Assert.False(store.FailClosedDueToPermissionDenied);
    }

    [Fact]
    public void TransientOutage_PromotesLatestIntoLastKnown()
    {
        var store = new MediaBudgetStatusStore();
        store.ApplyPublicEnvelope(NormalStatus());

        store.HandleListenerError(MediaBudgetListenerError.Unavailable, isSignedIn: true);

        Assert.False(store.FailClosedDueToPermissionDenied);
        Assert.Equal(NormalStatus(), store.LastKnownStatus);
        Assert.Equal(NormalStatus(), store.EffectiveStatus);
    }

    [Fact]
    public void Rehydrate_ReadsLastKnownFromPersistence()
    {
        var persistence = new InMemoryMediaBudgetStatusPersistence();
        persistence.Save(NormalStatus());

        var store = new MediaBudgetStatusStore(persistence);

        Assert.Equal(NormalStatus(), store.LastKnownStatus);
        Assert.Equal(NormalStatus(), store.EffectiveStatus);
    }

    [Fact]
    public void ParsePublicEnvelope_ReadsLevelAndEnvelope()
    {
        var data = new Dictionary<string, object?>
        {
            ["level"] = "soft_cap",
            ["activeEnvelope"] = new Dictionary<string, object?>
            {
                ["screenShareDailyMinutes"] = 30,
                ["screenSharePerSessionMinutes"] = 30,
                ["videoCallDailyMinutes"] = 120,
                ["videoCallPerCallMinutes"] = 20,
                ["fileTransferDailyGBIn"] = 2,
                ["fileTransferDailyGBOut"] = 2,
            },
        };

        var status = MediaBudgetStatusStore.ParsePublicEnvelope(data);

        Assert.Equal(MediaBudgetLevel.SoftCap, status.Level);
        Assert.Equal(MediaBudgetEnvelope.SoftCap, status.ActiveEnvelope);
    }

    [Fact]
    public void ParsePublicEnvelope_MissingFields_DefaultToNormalAndZero()
    {
        var status = MediaBudgetStatusStore.ParsePublicEnvelope(new Dictionary<string, object?>());
        Assert.Equal(MediaBudgetLevel.Normal, status.Level);
        Assert.Equal(new MediaBudgetEnvelope(0, 0, 0, 0, 0, 0), status.ActiveEnvelope);
    }
}
