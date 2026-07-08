using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Net;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.AppCheck.Token;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>
/// The FULL claim → real HTTP → token-install → header-attach path, driven through
/// the live <see cref="HttpClientAppCheckMintTransport"/> against a loopback
/// <see cref="HttpListener"/> mint server. Mirrors the Home Assistant live
/// HttpListener test and proves the transport + client + provider work end-to-end
/// off-Windows, not just against a hand-rolled fake.
/// </summary>
public sealed class LiveLoopbackMintTests
{
    private const long Minute = 60 * 1000;

    private sealed class LoopbackMintServer : IAsyncDisposable
    {
        private readonly HttpListener _listener = new();
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _loop;

        public Uri Url { get; }
        public string? LastAuthorization { get; private set; }
        public string? LastBody { get; private set; }

        public LoopbackMintServer(Func<string, (int status, string body)> respond)
        {
            var port = FreeLoopbackPort();
            Url = new Uri($"http://127.0.0.1:{port}/mintWindowsAppCheckToken");
            _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
            _listener.Start();
            _loop = Task.Run(() => AcceptLoop(respond));
        }

        private async Task AcceptLoop(Func<string, (int status, string body)> respond)
        {
            while (!_cts.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try
                {
                    ctx = await _listener.GetContextAsync().ConfigureAwait(false);
                }
                catch (Exception) { return; }

                LastAuthorization = ctx.Request.Headers["Authorization"];
                using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                {
                    LastBody = await reader.ReadToEndAsync().ConfigureAwait(false);
                }

                var (status, body) = respond(LastBody ?? "");
                var bytes = Encoding.UTF8.GetBytes(body);
                ctx.Response.StatusCode = status;
                ctx.Response.ContentType = "application/json";
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
                ctx.Response.Close();
            }
        }

        private static int FreeLoopbackPort()
        {
            var probe = new TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            var port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            return port;
        }

        public async ValueTask DisposeAsync()
        {
            _cts.Cancel();
            _listener.Stop();
            try { await _loop.ConfigureAwait(false); } catch { /* shutdown */ }
            _listener.Close();
            _cts.Dispose();
        }
    }

    private static WindowsAppCheckProvider BuildProvider(Uri url, IClock clock, string? idToken = TestConstants.SampleIdToken)
    {
        var endpoint = AppCheckMintEndpoint.ForUrl(url);
        var transport = new HttpClientAppCheckMintTransport();
        var client = new AppCheckMintClient(endpoint, transport);
        var options = new AppCheckProviderOptions { AppId = TestConstants.PlaceholderAppId };
        return new WindowsAppCheckProvider(
            new MockAttestationProducer(new SequenceNonceSource("0123456789abcdef0123456789abcdef")),
            client,
            new StubIdTokenSource(idToken),
            options,
            clock);
    }

    [Fact]
    public async Task Real_http_round_trip_mints_installs_and_attaches_the_header()
    {
        await using var server = new LoopbackMintServer(_ =>
            (200, TestConstants.SuccessBody("live-jwt", 30 * Minute, TestConstants.PlaceholderAppId)));

        var clock = new MutableClock(1_700_000_000_000);
        using var provider = BuildProvider(server.Url, clock);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var decision = await provider.AuthorizeRequestAsync(headers);

        Assert.True(decision.IsAttached);
        Assert.Equal("live-jwt", headers["X-Firebase-AppCheck"]);

        // The server actually received an authenticated request carrying the exact claim.
        Assert.Equal($"Bearer {TestConstants.SampleIdToken}", server.LastAuthorization);
        using var doc = JsonDocument.Parse(server.LastBody!);
        var att = doc.RootElement.GetProperty("data").GetProperty("attestation");
        Assert.Equal("mock", att.GetProperty("kind").GetString());
        Assert.Equal(TestConstants.PlaceholderAppId, att.GetProperty("appId").GetString());
        Assert.Equal("0123456789abcdef0123456789abcdef", att.GetProperty("nonce").GetString());
        Assert.Equal(
            MockAttestationMac.Sign(TestConstants.PlaceholderAppId, "0123456789abcdef0123456789abcdef", 1_700_000_000_000),
            att.GetProperty("mac").GetString());
    }

    [Fact]
    public async Task Real_http_401_fails_closed_no_header()
    {
        await using var server = new LoopbackMintServer(_ =>
            (401, TestConstants.ErrorBody("unauthenticated", "The attestation signature did not verify.")));

        var clock = new MutableClock(0);
        using var provider = BuildProvider(server.Url, clock);

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var decision = await provider.AuthorizeRequestAsync(headers);

        Assert.True(decision.IsBlocked);
        Assert.Equal(AppCheckMintFailure.Rejected, decision.Failure);
        Assert.False(headers.ContainsKey("X-Firebase-AppCheck"));
    }

    [Fact]
    public async Task Real_http_refresh_before_expiry_makes_a_second_round_trip()
    {
        var call = 0;
        await using var server = new LoopbackMintServer(_ =>
        {
            var n = Interlocked.Increment(ref call);
            return (200, TestConstants.SuccessBody($"live-jwt-{n}", 30 * Minute, TestConstants.PlaceholderAppId));
        });

        var clock = new MutableClock(0);
        using var provider = BuildProvider(server.Url, clock);

        var first = await provider.GetTokenAsync();
        clock.Advance(26 * Minute); // inside 5-min lead, not expired
        var second = await provider.GetTokenAsync();

        Assert.Equal("live-jwt-1", first.Token);
        Assert.Equal("live-jwt-2", second.Token);
    }
}
