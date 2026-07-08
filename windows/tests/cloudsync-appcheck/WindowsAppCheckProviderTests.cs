using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.AppCheck.Token;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>
/// End-to-end lifecycle of <see cref="WindowsAppCheckProvider"/>: mock-claim →
/// mint → install; TTL-aware refresh BEFORE expiry; header attach; and the
/// fail-closed contract (no valid token ⇒ request blocked, no header).
/// </summary>
public sealed class WindowsAppCheckProviderTests
{
    private const long Minute = 60 * 1000;
    private static readonly AppCheckMintEndpoint Endpoint = AppCheckMintEndpoint.ForProject("proj");

    private static WindowsAppCheckProvider Build(
        FakeMintTransport transport,
        MutableClock clock,
        out CountingAttestationProducer producer,
        out StubIdTokenSource idTokens,
        string? idToken = TestConstants.SampleIdToken,
        long refreshLeadMillis = 5 * Minute,
        long? requestedTtl = null)
    {
        producer = new CountingAttestationProducer(new MockAttestationProducer());
        idTokens = new StubIdTokenSource(idToken);
        var client = new AppCheckMintClient(Endpoint, transport);
        var options = new AppCheckProviderOptions
        {
            AppId = TestConstants.PlaceholderAppId,
            RefreshLeadMillis = refreshLeadMillis,
            RequestedTtlMillis = requestedTtl,
        };
        return new WindowsAppCheckProvider(producer, client, idTokens, options, clock);
    }

    [Fact]
    public async Task Mints_installs_and_returns_a_token()
    {
        var clock = new MutableClock(1_000_000);
        var transport = FakeMintTransport.Success("jwt-1", 30 * Minute, TestConstants.PlaceholderAppId);
        using var provider = Build(transport, clock, out var producer, out _);

        var token = await provider.GetTokenAsync();

        Assert.Equal("jwt-1", token.Token);
        Assert.Equal(1_000_000, token.MintedAtMs);
        Assert.Equal(1_000_000 + 30 * Minute, token.ExpiresAtMs);
        Assert.Equal(1, transport.CallCount);
        Assert.Equal(1, producer.ProduceCount);
        Assert.Same(token, provider.CurrentToken);
    }

    [Fact]
    public async Task Caches_the_token_no_second_mint_within_ttl()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Sequence(30 * Minute, TestConstants.PlaceholderAppId, "jwt-1", "jwt-2");
        using var provider = Build(transport, clock, out _, out _);

        var a = await provider.GetTokenAsync();
        clock.Advance(10 * Minute); // well inside TTL, outside refresh window
        var b = await provider.GetTokenAsync();

        Assert.Equal("jwt-1", a.Token);
        Assert.Same(a, b);
        Assert.Equal(1, transport.CallCount);
    }

    [Fact]
    public async Task Refreshes_BEFORE_expiry_once_inside_the_lead_window()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Sequence(30 * Minute, TestConstants.PlaceholderAppId, "jwt-1", "jwt-2");
        using var provider = Build(transport, clock, out _, out _, refreshLeadMillis: 5 * Minute);

        var first = await provider.GetTokenAsync();
        Assert.Equal("jwt-1", first.Token);

        // 26 min in: 4 min remain (< 5-min lead) but token is NOT yet expired.
        clock.Advance(26 * Minute);
        Assert.False(first.IsExpired(clock.NowMillis)); // proves this is a PROACTIVE refresh
        var refreshed = await provider.GetTokenAsync();

        Assert.Equal("jwt-2", refreshed.Token);
        Assert.Equal(26 * Minute, refreshed.MintedAtMs);
        Assert.Equal(2, transport.CallCount);
    }

    [Fact]
    public async Task Attaches_token_as_x_firebase_appcheck_header()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Success("jwt-hdr", 30 * Minute, TestConstants.PlaceholderAppId);
        using var provider = Build(transport, clock, out _, out _);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var decision = await provider.AuthorizeRequestAsync(headers);

        Assert.True(decision.IsAttached);
        Assert.Equal("X-Firebase-AppCheck", AppCheckHeader.Name);
        Assert.Equal("jwt-hdr", headers["X-Firebase-AppCheck"]);
        Assert.Equal("jwt-hdr", decision.Token!.Token);
    }

    [Fact]
    public async Task Missing_id_token_blocks_the_request_no_header()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Success("never", 30 * Minute, TestConstants.PlaceholderAppId);
        using var provider = Build(transport, clock, out _, out _, idToken: null);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var decision = await provider.AuthorizeRequestAsync(headers);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AppCheckMintFailure.MissingIdToken, decision.Failure);
        Assert.False(headers.ContainsKey("X-Firebase-AppCheck")); // fail-closed: no header
        Assert.Equal(0, transport.CallCount);                      // never minted
    }

    [Fact]
    public async Task Mint_rejection_blocks_the_request_no_header()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Rejecting(403);
        using var provider = Build(transport, clock, out _, out _);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var decision = await provider.AuthorizeRequestAsync(headers);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AppCheckMintFailure.Rejected, decision.Failure);
        Assert.False(headers.ContainsKey("X-Firebase-AppCheck"));
        Assert.Null(provider.CurrentToken); // nothing cached
    }

    [Fact]
    public async Task GetToken_throws_fail_closed_when_no_token_available()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Throwing(AppCheckMintException.Transport("connection refused"));
        using var provider = Build(transport, clock, out _, out _);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(() => provider.GetTokenAsync());
        Assert.Equal(AppCheckMintFailure.Transport, ex.Failure);
    }

    [Fact]
    public async Task A_stale_header_is_stripped_when_a_later_refresh_fails_closed()
    {
        // First a good token attaches; then it expires and the refresh fails —
        // the previously-attached header must be removed, never left dangling.
        var clock = new MutableClock(0);
        var responses = new Queue<Func<AppCheckMintHttpResponse>>(new Func<AppCheckMintHttpResponse>[]
        {
            () => new AppCheckMintHttpResponse(200, TestConstants.SuccessBody("jwt-good", 30 * Minute, TestConstants.PlaceholderAppId)),
            () => throw AppCheckMintException.Transport("down"),
        });
        var transport = new FakeMintTransport(_ => responses.Dequeue()());
        using var provider = Build(transport, clock, out _, out _);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var first = await provider.AuthorizeRequestAsync(headers);
        Assert.True(first.IsAttached);
        Assert.Equal("jwt-good", headers["X-Firebase-AppCheck"]);

        clock.Advance(31 * Minute); // token now expired
        var second = await provider.AuthorizeRequestAsync(headers);

        Assert.True(second.IsBlocked);
        Assert.False(headers.ContainsKey("X-Firebase-AppCheck")); // stripped, fail-closed
    }

    [Fact]
    public async Task Serves_still_valid_token_when_a_proactive_refresh_fails()
    {
        // A proactive refresh (token still valid) that fails should keep serving the
        // genuine, unexpired token — that is not a weakening.
        var clock = new MutableClock(0);
        var responses = new Queue<Func<AppCheckMintHttpResponse>>(new Func<AppCheckMintHttpResponse>[]
        {
            () => new AppCheckMintHttpResponse(200, TestConstants.SuccessBody("jwt-good", 30 * Minute, TestConstants.PlaceholderAppId)),
            () => throw AppCheckMintException.Timeout(),
        });
        var transport = new FakeMintTransport(_ => responses.Dequeue()());
        using var provider = Build(transport, clock, out _, out _, refreshLeadMillis: 5 * Minute);

        var first = await provider.GetTokenAsync();
        clock.Advance(26 * Minute); // inside refresh lead, NOT expired
        var served = await provider.GetTokenAsync();

        Assert.Equal("jwt-good", served.Token);
        Assert.Same(first, served);            // same still-valid token
        Assert.Equal(2, transport.CallCount);  // it did attempt the refresh
    }

    [Fact]
    public async Task Invalidate_forces_a_fresh_mint()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Sequence(30 * Minute, TestConstants.PlaceholderAppId, "jwt-1", "jwt-2");
        using var provider = Build(transport, clock, out _, out _);

        var a = await provider.GetTokenAsync();
        provider.Invalidate();
        var b = await provider.GetTokenAsync();

        Assert.Equal("jwt-1", a.Token);
        Assert.Equal("jwt-2", b.Token);
        Assert.Equal(2, transport.CallCount);
    }

    [Fact]
    public async Task Concurrent_callers_collapse_onto_a_single_mint()
    {
        var clock = new MutableClock(0);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var mintCount = 0;
        var transport = new FakeMintTransport(_ =>
        {
            Interlocked.Increment(ref mintCount);
            entered.TrySetResult();
            release.Task.GetAwaiter().GetResult(); // hold the in-flight mint until released
            return new AppCheckMintHttpResponse(200, TestConstants.SuccessBody("jwt-x", 30 * Minute, TestConstants.PlaceholderAppId));
        });
        using var provider = Build(transport, clock, out var producer, out _);

        // Launch every caller on the pool so the single-flight winner's synchronous
        // in-transport block cannot stall the ones still waiting on the mint gate.
        var tasks = Enumerable.Range(0, 8).Select(_ => Task.Run(() => provider.GetTokenAsync())).ToArray();
        await entered.Task; // the one winner reached the transport
        release.SetResult();
        var tokens = await Task.WhenAll(tasks);

        Assert.All(tokens, t => Assert.Equal("jwt-x", t.Token));
        Assert.Equal(1, mintCount);            // single-flight: exactly one mint
        Assert.Equal(1, producer.ProduceCount);
    }

    [Fact]
    public async Task Requested_ttl_is_forwarded_to_the_mint_call()
    {
        var clock = new MutableClock(0);
        var transport = FakeMintTransport.Success("jwt", 60 * Minute, TestConstants.PlaceholderAppId);
        using var provider = Build(transport, clock, out _, out _, requestedTtl: 60 * Minute);

        await provider.GetTokenAsync();

        using var doc = System.Text.Json.JsonDocument.Parse(transport.LastBodyUtf8!);
        Assert.Equal(60 * Minute, doc.RootElement.GetProperty("data").GetProperty("ttlMillis").GetInt64());
    }
}
