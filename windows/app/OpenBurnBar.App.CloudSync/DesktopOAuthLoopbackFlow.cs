using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Token;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// The interactive browser-loopback authorization flow (RFC 8252): bind a loopback
/// <see cref="HttpListener"/>, open the browser at the PKCE authorization URL,
/// capture the redirect, then run the Google-code → Google-token → Firebase-id-token
/// exchanges. Produces a <see cref="FirebaseOAuthSession"/> stamped with the injected
/// clock, or throws <see cref="DesktopOAuthException"/> fail-closed on
/// cancel/timeout/error.
/// </summary>
public sealed class DesktopOAuthLoopbackFlow
{
    private readonly DesktopOAuthOptions _options;
    private readonly IBrowserLauncher _browser;
    private readonly FirebaseIdentityClient _identity;
    private readonly IClock _clock;

    public DesktopOAuthLoopbackFlow(
        DesktopOAuthOptions options,
        IBrowserLauncher browser,
        FirebaseIdentityClient identity,
        IClock clock)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _browser = browser ?? throw new ArgumentNullException(nameof(browser));
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
    }

    public async Task<FirebaseOAuthSession> AuthorizeAsync(CancellationToken cancellationToken = default)
    {
        PkceCodePair pkce = PkceCodePair.Generate();
        int port = _options.FixedRedirectPort ?? FreeLoopbackPort();
        string redirectUri = $"http://{_options.LoopbackHost}:{port}/";

        using var listener = new HttpListener();
        listener.Prefixes.Add(redirectUri);
        listener.Start();

        try
        {
            Uri authorizationUrl = BuildAuthorizationUrl(pkce, redirectUri);
            LaunchBrowser(authorizationUrl);

            string code = await AwaitRedirectCodeAsync(listener, pkce.State, cancellationToken).ConfigureAwait(false);

            GoogleTokenResult googleTokens = await _identity
                .ExchangeAuthorizationCodeAsync(code, pkce.CodeVerifier, redirectUri, cancellationToken)
                .ConfigureAwait(false);

            FirebaseSignInResult firebase = await _identity
                .SignInWithIdpAsync(googleTokens.GoogleIdToken, cancellationToken)
                .ConfigureAwait(false);

            return new FirebaseOAuthSession
            {
                IdToken = firebase.IdToken,
                RefreshToken = firebase.RefreshToken,
                Uid = firebase.Uid,
                Email = firebase.Email,
                TtlMillis = firebase.ExpiresInSeconds * 1000,
                MintedAtMs = _clock.NowMillis,
            };
        }
        finally
        {
            try { listener.Stop(); } catch { /* already stopped */ }
        }
    }

    private Uri BuildAuthorizationUrl(PkceCodePair pkce, string redirectUri)
    {
        string scope = string.Join(" ", _options.Scopes);
        var query = new List<string>
        {
            $"client_id={Uri.EscapeDataString(_options.ClientId)}",
            $"redirect_uri={Uri.EscapeDataString(redirectUri)}",
            "response_type=code",
            $"scope={Uri.EscapeDataString(scope)}",
            $"code_challenge={Uri.EscapeDataString(pkce.CodeChallenge)}",
            $"code_challenge_method={PkceCodePair.ChallengeMethod}",
            $"state={Uri.EscapeDataString(pkce.State)}",
            "access_type=offline",
            "prompt=consent",
        };
        var builder = new UriBuilder(_options.AuthorizationEndpoint);
        string existing = builder.Query.TrimStart('?');
        string joined = string.Join("&", query);
        builder.Query = string.IsNullOrEmpty(existing) ? joined : existing + "&" + joined;
        return builder.Uri;
    }

    private void LaunchBrowser(Uri authorizationUrl)
    {
        try
        {
            _browser.Launch(authorizationUrl);
        }
        catch (Exception ex)
        {
            throw new DesktopOAuthException(
                DesktopOAuthFailure.Transport, $"Failed to open the sign-in browser: {ex.Message}.", ex);
        }
    }

    private async Task<string> AwaitRedirectCodeAsync(HttpListener listener, string expectedState, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_options.AuthorizationTimeout);
        using CancellationTokenRegistration registration = timeoutCts.Token.Register(() =>
        {
            try { listener.Stop(); } catch { /* already stopped */ }
        });

        HttpListenerContext context;
        try
        {
            context = await listener.GetContextAsync().ConfigureAwait(false);
        }
        catch (Exception) when (timeoutCts.IsCancellationRequested)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                throw DesktopOAuthException.UserCancelled("Sign-in was cancelled before the redirect arrived.");
            }
            throw DesktopOAuthException.Timeout();
        }

        try
        {
            return ExtractCode(context.Request, expectedState);
        }
        finally
        {
            WriteBrowserResponse(context.Response);
        }
    }

    private string ExtractCode(HttpListenerRequest request, string expectedState)
    {
        string? error = request.QueryString["error"];
        if (!string.IsNullOrEmpty(error))
        {
            throw string.Equals(error, "access_denied", StringComparison.OrdinalIgnoreCase)
                ? DesktopOAuthException.UserCancelled("The user denied the sign-in consent.")
                : DesktopOAuthException.AuthorizationError(error!);
        }

        string? state = request.QueryString["state"];
        if (!string.Equals(state, expectedState, StringComparison.Ordinal))
        {
            throw DesktopOAuthException.StateMismatch();
        }

        string? code = request.QueryString["code"];
        if (string.IsNullOrEmpty(code))
        {
            throw DesktopOAuthException.Malformed("authorization redirect", "missing code");
        }
        return code!;
    }

    private void WriteBrowserResponse(HttpListenerResponse response)
    {
        try
        {
            byte[] bytes = Encoding.UTF8.GetBytes(_options.SuccessHtml);
            response.StatusCode = 200;
            response.ContentType = "text/html; charset=utf-8";
            response.ContentLength64 = bytes.Length;
            response.OutputStream.Write(bytes, 0, bytes.Length);
            response.OutputStream.Close();
        }
        catch
        {
            // The browser tab may already be closed — the code capture still succeeded.
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
}
