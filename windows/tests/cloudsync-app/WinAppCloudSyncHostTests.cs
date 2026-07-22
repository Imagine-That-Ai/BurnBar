using OpenBurnBar.App.CloudSync;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class WinAppCloudSyncHostTests
{
    [Fact]
    public void ValidCachedOAuthSessionIsRestorableWithoutStaticUid()
    {
        var session = new FirebaseOAuthSession
        {
            IdToken = "id-token",
            RefreshToken = "refresh-token",
            Uid = "oauth-user",
            MintedAtMs = 1_000,
            TtlMillis = 60_000,
        };

        FirebaseOAuthSession? selected = WinAppCloudSyncHost.SelectRestorableSession(session, 2_000);

        Assert.Same(session, selected);
        Assert.Null(WinAppCloudSyncHost.SelectRestorableSession(session, 61_000));
    }
}
