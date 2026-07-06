using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Token;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Desktop Firebase OAuth via a browser loopback + PKCE flow. Fills the credential
/// gate that <c>MissionDispatchHostFactory</c>, <c>CloudSyncInsightSource</c>, and
/// <c>QuotaAccountsSource</c> check — once a user signs in, the "Authored→Real"
/// surfaces receive live data.
/// </summary>
/// <remarks>
/// The macOS oracle delegates this to the FirebaseAuth / GoogleSignIn Apple SDKs
/// (<c>AgentLens/Services/Insights/MacFirebaseTokenProvider.swift</c>); the Windows
/// port re-implements the flow the SDKs hide (see <see cref="DesktopOAuthOptions"/>).
///
/// <para><b>Interactive vs. check.</b> <see cref="SignInAsync"/> runs the browser
/// loopback flow and is invoked by an explicit "Sign in" action. The passive
/// accessors (<see cref="GetCredentialsAsync"/>, <see cref="GetIdTokenAsync"/>) never
/// pop a browser: they return the cached session, refresh it non-interactively when
/// it is inside its refresh window, and otherwise fail closed. This lets a surface
/// probe "am I signed in?" without triggering a sign-in dialog.</para>
///
/// <para><b>Fail-closed + single-flight.</b> A refresh that fails while a still-valid
/// token remains keeps serving that valid token (Firebase-SDK behavior); once the
/// token is expired and cannot be refreshed the session is cleared and the accessor
/// throws <see cref="DesktopOAuthException"/>. A single-flight
/// <see cref="SemaphoreSlim"/> collapses a concurrent expiry stampede onto one
/// round-trip. Mirrors <c>WindowsAppCheckProvider</c>.</para>
/// </remarks>
public sealed class DesktopOAuthCredentialsProvider : ICloudSyncCredentialsProvider, IFirebaseIdTokenSource, IDisposable
{
    private readonly DesktopOAuthLoopbackFlow _flow;
    private readonly FirebaseIdentityClient _identity;
    private readonly DesktopOAuthOptions _options;
    private readonly IClock _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private FirebaseOAuthSession? _session;

    public DesktopOAuthCredentialsProvider(
        DesktopOAuthOptions options,
        DesktopOAuthLoopbackFlow flow,
        FirebaseIdentityClient identity,
        IClock? clock = null)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
        _flow = flow ?? throw new ArgumentNullException(nameof(flow));
        _identity = identity ?? throw new ArgumentNullException(nameof(identity));
        _clock = clock ?? SystemClock.Instance;
    }

    /// <summary>
    /// Convenience wiring: build a provider from options + an <see cref="HttpClient"/>
    /// and the default system browser launcher.
    /// </summary>
    public static DesktopOAuthCredentialsProvider Create(
        DesktopOAuthOptions options,
        HttpClient httpClient,
        IBrowserLauncher? browser = null,
        IClock? clock = null)
    {
        if (options is null) throw new ArgumentNullException(nameof(options));
        options.Validate();
        IClock resolvedClock = clock ?? SystemClock.Instance;
        var identity = new FirebaseIdentityClient(httpClient, options);
        var flow = new DesktopOAuthLoopbackFlow(options, browser ?? new SystemBrowserLauncher(), identity, resolvedClock);
        return new DesktopOAuthCredentialsProvider(options, flow, identity, resolvedClock);
    }

    /// <summary>The current signed-in session, if any (exposed for diagnostics / tests).</summary>
    public FirebaseOAuthSession? CurrentSession => Volatile.Read(ref _session);

    /// <summary>True while a non-expired session is cached.</summary>
    public bool IsSignedIn
    {
        get
        {
            FirebaseOAuthSession? s = Volatile.Read(ref _session);
            return s is not null && !s.IsExpired(_clock.NowMillis);
        }
    }

    /// <summary>The signed-in Firebase uid, or null when signed out.</summary>
    public string? SignedInUid => Volatile.Read(ref _session)?.Uid;

    /// <summary>
    /// Run the interactive browser loopback sign-in and install the resulting
    /// session. Throws <see cref="DesktopOAuthException"/> fail-closed on
    /// cancel/timeout/error.
    /// </summary>
    public async Task<FirebaseOAuthSession> SignInAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            FirebaseOAuthSession session = await _flow.AuthorizeAsync(cancellationToken).ConfigureAwait(false);
            _session = session;
            return session;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Discard the cached session (explicit sign-out / after a hard 401).</summary>
    public void SignOut()
    {
        _gate.Wait();
        try
        {
            _session = null;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <inheritdoc />
    public async Task<CloudSyncCredentials> GetCredentialsAsync(CancellationToken cancellationToken = default)
    {
        FirebaseOAuthSession session = await GetValidSessionAsync(cancellationToken).ConfigureAwait(false);
        // App Check is attached by the AppCheckCredentialsProvider wrapper, so this
        // base provider returns the id token only.
        return new CloudSyncCredentials(session.IdToken);
    }

    /// <inheritdoc />
    public async ValueTask<string?> GetIdTokenAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            FirebaseOAuthSession session = await GetValidSessionAsync(cancellationToken).ConfigureAwait(false);
            return session.IdToken;
        }
        catch (DesktopOAuthException)
        {
            // IFirebaseIdTokenSource contract: signed-out / unrenewable ⇒ null so the
            // App Check mint fails closed as MissingIdToken (no interactive pop here).
            return null;
        }
    }

    private async Task<FirebaseOAuthSession> GetValidSessionAsync(CancellationToken cancellationToken)
    {
        // Fast path: a cached session that is neither expired nor inside its refresh
        // window needs no lock.
        FirebaseOAuthSession? cached = Volatile.Read(ref _session);
        long now = _clock.NowMillis;
        if (cached is not null && !cached.IsExpired(now) && !cached.ShouldRefresh(now, _options.RefreshLeadMillis))
        {
            return cached;
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            now = _clock.NowMillis;
            cached = _session;
            if (cached is null)
            {
                // Passive accessor: never launches a browser. The user must call
                // SignInAsync first.
                throw DesktopOAuthException.NotSignedIn();
            }
            if (!cached.IsExpired(now) && !cached.ShouldRefresh(now, _options.RefreshLeadMillis))
            {
                return cached;
            }

            try
            {
                FirebaseRefreshResult refreshed = await _identity
                    .RefreshAsync(cached.RefreshToken, cancellationToken)
                    .ConfigureAwait(false);
                var next = new FirebaseOAuthSession
                {
                    IdToken = refreshed.IdToken,
                    RefreshToken = refreshed.RefreshToken,
                    Uid = string.IsNullOrEmpty(refreshed.Uid) ? cached.Uid : refreshed.Uid,
                    Email = cached.Email,
                    TtlMillis = refreshed.ExpiresInSeconds * 1000,
                    MintedAtMs = _clock.NowMillis,
                };
                _session = next;
                return next;
            }
            catch (DesktopOAuthException)
            {
                // A proactive refresh failed. If the cached token is still genuinely
                // valid, keep serving it (real + unexpired ⇒ no weakening).
                FirebaseOAuthSession? still = _session;
                if (still is not null && !still.IsExpired(_clock.NowMillis))
                {
                    return still;
                }
                // Otherwise fail closed: clear the expired session so it is never served.
                _session = null;
                throw;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _gate.Dispose();
}
