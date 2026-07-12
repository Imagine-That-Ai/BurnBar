using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.CloudSync.AppCheck.Token;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

/// <summary>
/// The desktop Firebase OAuth loopback flow, proven end-to-end against an in-process
/// FAKE authorization server (a loopback <see cref="HttpListener"/> serving the token /
/// signInWithIdp / securetoken endpoints) plus a capturing browser launcher that
/// drives the redirect. Proves the full <c>code → Google token → Firebase id token →
/// refresh</c> loop value-for-value, and the cancel / timeout / error / malformed
/// paths fail closed. The real-Google/Firebase-endpoint round-trip is a WS-D tail
/// (needs Alberto's secrets); this proves everything reachable off-network.
/// </summary>
public sealed class DesktopOAuthCredentialsProviderTests
{
    private const long BaseNow = 1_000_000;

    // ── Happy path: full code → id-token → refresh loop, value-for-value ──────
    [Fact]
    public async Task Full_sign_in_then_refresh_loop_value_for_value()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(DefaultCallback);
        var clock = new MutableClock(BaseNow);
        var sessionStore = new RecordingSessionStore();
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, browser, clock, sessionStore);

        FirebaseOAuthSession session = await provider.SignInAsync();

        // The session carries the FIREBASE token (not the Google token), the uid, and
        // a clock-stamped TTL.
        Assert.Equal("fb-idtok-1", session.IdToken);
        Assert.Equal("fb-refresh-1", session.RefreshToken);
        Assert.Equal("uid-123", session.Uid);
        Assert.Equal("a@b.co", session.Email);
        Assert.Equal(3600L * 1000, session.TtlMillis);
        Assert.Equal(BaseNow, session.MintedAtMs);
        Assert.True(provider.IsSignedIn);
        Assert.Equal("uid-123", provider.SignedInUid);

        CloudSyncCredentials creds = await provider.GetCredentialsAsync();
        Assert.Equal("fb-idtok-1", creds.IdToken);
        Assert.Null(creds.AppCheckToken); // attached by the AppCheckCredentialsProvider wrapper

        // The App Check id-token source sees the same live token.
        Assert.Equal("fb-idtok-1", await provider.GetIdTokenAsync());
        Assert.Equal("fb-refresh-1", sessionStore.Saved!.RefreshToken);

        // Value-for-value on the wire: the PKCE challenge in the auth URL matches the
        // verifier posted to the token endpoint; the code round-trips; the Google id
        // token is forwarded to signInWithIdp.
        var authQuery = ParseQuery(browser.LaunchedUrl!.Query);
        Assert.Equal("S256", authQuery["code_challenge_method"]);
        var tokenBody = ParseQuery(server.LastBodyByPath["token"]);
        Assert.Equal("authorization_code", tokenBody["grant_type"]);
        Assert.Equal("fake-auth-code", tokenBody["code"]);
        Assert.Equal("test-client", tokenBody["client_id"]);
        Assert.Equal(authQuery["code_challenge"], PkceCodePair.ChallengeFor(tokenBody["code_verifier"]));
        Assert.Contains("id_token=google-idtok", server.LastBodyByPath["signInWithIdp"]);
        Assert.Contains("providerId=google.com", server.LastBodyByPath["signInWithIdp"]);

        // Refresh: advance into the refresh window (not yet expired) → securetoken hop.
        clock.Set(session.ExpiresAtMs - 60_000);
        CloudSyncCredentials refreshed = await provider.GetCredentialsAsync();
        Assert.Equal("fb-idtok-2", refreshed.IdToken);
        Assert.Equal("fb-refresh-2", provider.CurrentSession!.RefreshToken);
        Assert.Equal("fb-refresh-2", sessionStore.Saved!.RefreshToken);
        var refreshBody = ParseQuery(server.LastBodyByPath["securetoken"]);
        Assert.Equal("refresh_token", refreshBody["grant_type"]);
        Assert.Equal("fb-refresh-1", refreshBody["refresh_token"]); // the OLD refresh token was spent
    }

    [Fact]
    public async Task Valid_token_inside_ttl_is_served_from_cache_without_a_refresh()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var clock = new MutableClock(BaseNow);
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), clock);

        await provider.SignInAsync();
        clock.Advance(1000); // still well inside the 1h TTL, outside the refresh lead
        await provider.GetCredentialsAsync();
        await provider.GetCredentialsAsync();

        Assert.False(server.LastBodyByPath.ContainsKey("securetoken")); // never refreshed
    }

    // ── Fail-closed: cancel / timeout / error / state / malformed ─────────────
    [Fact]
    public async Task User_denied_consent_fails_closed_as_cancelled()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(state => $"error=access_denied&state={Uri.EscapeDataString(state)}");
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, browser, new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.UserCancelled, ex.Failure);
        Assert.False(provider.IsSignedIn);
    }

    [Fact]
    public async Task No_redirect_before_the_timeout_fails_closed()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(_ => null); // browser never redirects
        DesktopOAuthOptions options = Options(server, TimeSpan.FromMilliseconds(250));
        DesktopOAuthCredentialsProvider provider = BuildProvider(options, browser, new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.Timeout, ex.Failure);
    }

    [Fact]
    public async Task Caller_cancellation_fails_closed_as_cancelled()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(_ => null); // parked waiting for a redirect
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, browser, new MutableClock(BaseNow));
        using var cts = new CancellationTokenSource();
        cts.CancelAfter(TimeSpan.FromMilliseconds(150));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync(cts.Token));
        Assert.Equal(DesktopOAuthFailure.UserCancelled, ex.Failure);
    }

    [Fact]
    public async Task State_mismatch_fails_closed()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(_ => "code=x&state=TAMPERED");
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, browser, new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.StateMismatch, ex.Failure);
    }

    [Fact]
    public async Task Token_endpoint_error_fails_closed()
    {
        await using var server = new FakeAuthorizationServer((path, _) =>
            path == "token" ? (400, "{\"error\":\"invalid_grant\"}") : (200, "{}"));
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.TokenExchangeFailed, ex.Failure);
    }

    [Fact]
    public async Task Malformed_token_response_fails_closed()
    {
        await using var server = new FakeAuthorizationServer((path, _) =>
            path == "token" ? (200, "{}") : (200, "{}")); // 200 but no id_token
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.Malformed, ex.Failure);
    }

    [Fact]
    public async Task SignInWithIdp_error_fails_closed()
    {
        await using var server = new FakeAuthorizationServer((path, _) => path switch
        {
            "token" => (200, GoogleTokenBody()),
            "signInWithIdp" => (401, "{\"error\":{\"message\":\"INVALID_IDP_RESPONSE\"}}"),
            _ => (200, "{}"),
        });
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.SignInAsync());
        Assert.Equal(DesktopOAuthFailure.TokenExchangeFailed, ex.Failure);
    }

    // ── Passive accessors never pop a browser ────────────────────────────────
    [Fact]
    public async Task Get_credentials_before_sign_in_fails_closed_not_signed_in()
    {
        await using var server = new FakeAuthorizationServer(SuccessResponder());
        var browser = new CapturingBrowserLauncher(DefaultCallback);
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, browser, new MutableClock(BaseNow));

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.GetCredentialsAsync());
        Assert.Equal(DesktopOAuthFailure.NotSignedIn, ex.Failure);
        Assert.Null(await provider.GetIdTokenAsync());  // App Check mint fails closed (null)
        Assert.Null(browser.LaunchedUrl);               // never launched a browser
    }

    // ── Refresh fault behaviour ──────────────────────────────────────────────
    [Fact]
    public async Task Refresh_fault_keeps_serving_a_still_valid_token()
    {
        int securetokenHits = 0;
        await using var server = new FakeAuthorizationServer((path, _) =>
        {
            if (path == "token") return (200, GoogleTokenBody());
            if (path == "signInWithIdp") return (200, FirebaseSignInBody());
            if (path == "securetoken") { securetokenHits++; return (500, "{\"error\":\"backend\"}"); }
            return (200, "{}");
        });
        var clock = new MutableClock(BaseNow);
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), clock);

        FirebaseOAuthSession session = await provider.SignInAsync();
        clock.Set(session.ExpiresAtMs - 60_000); // inside refresh lead, NOT expired

        CloudSyncCredentials creds = await provider.GetCredentialsAsync();
        Assert.Equal("fb-idtok-1", creds.IdToken); // still-valid token kept despite refresh 500
        Assert.True(securetokenHits >= 1);
        Assert.True(provider.IsSignedIn);
    }

    [Fact]
    public async Task Refresh_fault_after_expiry_fails_closed_and_clears_session()
    {
        await using var server = new FakeAuthorizationServer((path, _) =>
        {
            if (path == "token") return (200, GoogleTokenBody());
            if (path == "signInWithIdp") return (200, FirebaseSignInBody());
            if (path == "securetoken") return (500, "{\"error\":\"backend\"}");
            return (200, "{}");
        });
        var clock = new MutableClock(BaseNow);
        var sessionStore = new RecordingSessionStore();
        DesktopOAuthCredentialsProvider provider = BuildProvider(server, new CapturingBrowserLauncher(DefaultCallback), clock, sessionStore);

        FirebaseOAuthSession session = await provider.SignInAsync();
        clock.Set(session.ExpiresAtMs + 1000); // fully expired

        DesktopOAuthException ex = await Assert.ThrowsAsync<DesktopOAuthException>(() => provider.GetCredentialsAsync());
        Assert.Equal(DesktopOAuthFailure.TokenExchangeFailed, ex.Failure);
        Assert.Null(provider.CurrentSession);   // cleared — never serve an expired token
        Assert.False(provider.IsSignedIn);
        Assert.True(sessionStore.Deleted);
    }

    // ── Wiring helpers ───────────────────────────────────────────────────────
    private static DesktopOAuthOptions Options(FakeAuthorizationServer server, TimeSpan? authorizationTimeout = null) => new()
    {
        AuthorizationEndpoint = new Uri("https://accounts.example.test/o/oauth2/v2/auth"),
        TokenEndpoint = new Uri(server.BaseUrl, "token"),
        FirebaseSignInEndpoint = new Uri(server.BaseUrl, "signInWithIdp"),
        FirebaseRefreshEndpoint = new Uri(server.BaseUrl, "securetoken"),
        ClientId = "test-client",
        FirebaseApiKey = "test-key",
        AuthorizationTimeout = authorizationTimeout ?? TimeSpan.FromSeconds(10),
    };

    private static DesktopOAuthCredentialsProvider BuildProvider(
        FakeAuthorizationServer server,
        IBrowserLauncher browser,
        IClock clock,
        IFirebaseOAuthSessionStore? sessionStore = null) =>
        BuildProvider(Options(server), browser, clock, sessionStore);

    private static DesktopOAuthCredentialsProvider BuildProvider(
        DesktopOAuthOptions options,
        IBrowserLauncher browser,
        IClock clock,
        IFirebaseOAuthSessionStore? sessionStore = null)
    {
        var identity = new FirebaseIdentityClient(new HttpClient(), options);
        var flow = new DesktopOAuthLoopbackFlow(options, browser, identity, clock);
        return new DesktopOAuthCredentialsProvider(options, flow, identity, clock, sessionStore);
    }

    private static string? DefaultCallback(string state) => $"code=fake-auth-code&state={Uri.EscapeDataString(state)}";

    private static string GoogleTokenBody() =>
        "{\"id_token\":\"google-idtok\",\"access_token\":\"g-acc\",\"refresh_token\":\"g-ref\",\"expires_in\":3599}";

    private static string FirebaseSignInBody() =>
        "{\"idToken\":\"fb-idtok-1\",\"refreshToken\":\"fb-refresh-1\",\"expiresIn\":\"3600\",\"localId\":\"uid-123\",\"email\":\"a@b.co\"}";

    private static string FirebaseRefreshBody() =>
        "{\"id_token\":\"fb-idtok-2\",\"refresh_token\":\"fb-refresh-2\",\"expires_in\":\"3600\",\"user_id\":\"uid-123\"}";

    private static Func<string, string, (int, string)> SuccessResponder() => (path, _) => path switch
    {
        "token" => (200, GoogleTokenBody()),
        "signInWithIdp" => (200, FirebaseSignInBody()),
        "securetoken" => (200, FirebaseRefreshBody()),
        _ => (404, "{}"),
    };

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = pair.IndexOf('=');
            if (eq < 0) { map[Uri.UnescapeDataString(pair)] = string.Empty; continue; }
            map[Uri.UnescapeDataString(pair[..eq])] = Uri.UnescapeDataString(pair[(eq + 1)..]);
        }
        return map;
    }

    // ── In-test fakes ────────────────────────────────────────────────────────

    /// <summary>Captures the authorization URL and drives the loopback redirect on a background task.</summary>
    private sealed class CapturingBrowserLauncher : IBrowserLauncher
    {
        private readonly Func<string, string?> _callbackQuery;
        public Uri? LaunchedUrl { get; private set; }

        public CapturingBrowserLauncher(Func<string, string?> callbackQuery) => _callbackQuery = callbackQuery;

        public void Launch(Uri authorizationUrl)
        {
            LaunchedUrl = authorizationUrl;
            var query = ParseQuery(authorizationUrl.Query);
            string redirect = query["redirect_uri"];
            string state = query["state"];
            string? callback = _callbackQuery(state);
            if (callback is null)
            {
                return; // simulate a browser that never redirects (timeout / cancel)
            }
            string target = redirect + (redirect.Contains('?') ? "&" : "?") + callback;
            _ = Task.Run(async () =>
            {
                try { using var client = new HttpClient(); await client.GetAsync(target); }
                catch { /* the flow may have already closed the listener */ }
            });
        }
    }

    /// <summary>A loopback fake authorization server routing by path (token / signInWithIdp / securetoken).</summary>
    private sealed class FakeAuthorizationServer : IAsyncDisposable
    {
        private readonly HttpListener _listener = new();
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _loop;
        private readonly Func<string, string, (int Status, string Body)> _respond;

        public Uri BaseUrl { get; }
        public Dictionary<string, string> LastBodyByPath { get; } = new(StringComparer.Ordinal);

        public FakeAuthorizationServer(Func<string, string, (int, string)> respond)
        {
            _respond = respond;
            int port = FreeLoopbackPort();
            BaseUrl = new Uri($"http://127.0.0.1:{port}/");
            _listener.Prefixes.Add(BaseUrl.ToString());
            _listener.Start();
            _loop = Task.Run(AcceptLoop);
        }

        private async Task AcceptLoop()
        {
            while (!_cts.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _listener.GetContextAsync().ConfigureAwait(false); }
                catch { return; }

                string path = ctx.Request.Url!.AbsolutePath.Trim('/');
                string body;
                using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                {
                    body = await reader.ReadToEndAsync().ConfigureAwait(false);
                }
                lock (LastBodyByPath) { LastBodyByPath[path] = body; }

                (int status, string responseBody) = _respond(path, body);
                byte[] bytes = Encoding.UTF8.GetBytes(responseBody);
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
            int port = ((IPEndPoint)probe.LocalEndpoint).Port;
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

    private sealed class RecordingSessionStore : IFirebaseOAuthSessionStore
    {
        public FirebaseOAuthSession? Saved { get; private set; }
        public bool Deleted { get; private set; }

        public FirebaseOAuthSession? Load() => Saved;

        public void Save(FirebaseOAuthSession session)
        {
            Saved = session;
            Deleted = false;
        }

        public void Delete()
        {
            Saved = null;
            Deleted = true;
        }
    }
}
