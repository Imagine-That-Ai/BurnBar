using OpenBurnBar.CloudSync.AppCheck.Token;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>TTL / expiry / refresh-window arithmetic on the installed token.</summary>
public sealed class AppCheckTokenTests
{
    private const long Minute = 60 * 1000;

    private static AppCheckToken Token(long mintedAt, long ttl) => new()
    {
        Token = "jwt",
        TtlMillis = ttl,
        AppId = TestConstants.PlaceholderAppId,
        MintedAtMs = mintedAt,
    };

    [Fact]
    public void Expiry_is_minted_plus_ttl()
    {
        var t = Token(1000, 30 * Minute);
        Assert.Equal(1000 + 30 * Minute, t.ExpiresAtMs);
    }

    [Fact]
    public void Not_expired_before_expiry_expired_at_and_after()
    {
        var t = Token(0, 30 * Minute);
        Assert.False(t.IsExpired(30 * Minute - 1));
        Assert.True(t.IsExpired(30 * Minute));       // boundary: now == expiry is expired
        Assert.True(t.IsExpired(30 * Minute + 1));
    }

    [Fact]
    public void Remaining_millis_counts_down_and_goes_negative()
    {
        var t = Token(0, 30 * Minute);
        Assert.Equal(30 * Minute, t.RemainingMillis(0));
        Assert.Equal(Minute, t.RemainingMillis(29 * Minute));
        Assert.Equal(-Minute, t.RemainingMillis(31 * Minute));
    }

    [Fact]
    public void Should_refresh_only_once_inside_the_lead_window()
    {
        var t = Token(0, 30 * Minute);
        var lead = 5 * Minute;

        // 24 min in: 6 min remain, outside the 5-min lead -> no refresh.
        Assert.False(t.ShouldRefresh(24 * Minute, lead));
        // 25 min in: exactly 5 min remain == lead boundary -> refresh.
        Assert.True(t.ShouldRefresh(25 * Minute, lead));
        // 26 min in: 4 min remain, inside lead -> refresh.
        Assert.True(t.ShouldRefresh(26 * Minute, lead));
        // past expiry -> refresh.
        Assert.True(t.ShouldRefresh(31 * Minute, lead));
    }

    [Fact]
    public void Zero_lead_degenerates_to_refresh_only_when_expired()
    {
        var t = Token(0, 30 * Minute);
        Assert.False(t.ShouldRefresh(30 * Minute - 1, 0));
        Assert.True(t.ShouldRefresh(30 * Minute, 0));
    }
}
