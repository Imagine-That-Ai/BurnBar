using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Token;

namespace OpenBurnBar.CloudSync.AppCheck.Provider;

/// <summary>
/// The Windows App Check provider: it produces a platform attestation, exchanges
/// it for a Firebase App Check token at the mint endpoint, caches the token,
/// refreshes it TTL-aware BEFORE it expires, and attaches
/// <c>X-Firebase-AppCheck</c> to outbound requests — fail-closed at every step.
/// </summary>
/// <remarks>
/// This is the Windows-port mirror of the macOS
/// <c>OpenBurnBarAppCheckProviderFactory</c> / <c>AppCheckAttestationMonitor</c>:
/// a Windows client cannot use Apple App Attest, so it plugs its own attestation
/// producer into the same token lifecycle.
///
/// FAIL-CLOSED CONTRACT (never weakens the server gate):
/// <list type="bullet">
///   <item>No Firebase ID token (signed out) ⇒ no mint ⇒ request BLOCKED.</item>
///   <item>Mint rejected/timed-out/malformed AND no still-valid cached token ⇒
///   request BLOCKED; the cached slot is cleared so no stale token is ever served.</item>
///   <item>A request is authorized ONLY when a non-expired token is attached.</item>
/// </list>
/// A proactive refresh that fails while a still-valid token remains keeps serving
/// that valid token (matching Firebase SDK behavior) and retries on the next call
/// — this is NOT a weakening: the served token is genuine and unexpired.
///
/// Concurrency: a single-flight <see cref="SemaphoreSlim"/> collapses concurrent
/// callers onto one mint round-trip so a token-expiry stampede cannot fan out N
/// mint calls.
/// </remarks>
public sealed class WindowsAppCheckProvider : IDisposable
{
    private readonly IAttestationProducer _producer;
    private readonly AppCheckMintClient _mintClient;
    private readonly IFirebaseIdTokenSource _idTokenSource;
    private readonly IClock _clock;
    private readonly AppCheckProviderOptions _options;
    private readonly SemaphoreSlim _mintGate = new(1, 1);

    private AppCheckToken? _current;

    public WindowsAppCheckProvider(
        IAttestationProducer producer,
        AppCheckMintClient mintClient,
        IFirebaseIdTokenSource idTokenSource,
        AppCheckProviderOptions options,
        IClock? clock = null)
    {
        _producer = producer ?? throw new ArgumentNullException(nameof(producer));
        _mintClient = mintClient ?? throw new ArgumentNullException(nameof(mintClient));
        _idTokenSource = idTokenSource ?? throw new ArgumentNullException(nameof(idTokenSource));
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
        _clock = clock ?? SystemClock.Instance;
    }

    /// <summary>The App Check app id this provider mints for.</summary>
    public string AppId => _options.AppId;

    /// <summary>The producer's attestation kind (e.g. <c>"mock"</c> / <c>"tpm"</c>).</summary>
    public string AttestationKind => _producer.Kind;

    /// <summary>
    /// The currently cached token, if any (may be expired). Exposed for
    /// diagnostics / tests; callers should use <see cref="GetTokenAsync"/>.
    /// </summary>
    public AppCheckToken? CurrentToken => Volatile.Read(ref _current);

    /// <summary>
    /// Return a valid, non-expired App Check token, minting or refreshing as
    /// needed. Throws <see cref="AppCheckMintException"/> fail-closed when no valid
    /// token can be obtained.
    /// </summary>
    public async Task<AppCheckToken> GetTokenAsync(CancellationToken cancellationToken = default)
    {
        // Fast path: a cached token that is neither expired nor inside its refresh
        // window needs no lock.
        var cached = Volatile.Read(ref _current);
        var now = _clock.NowMillis;
        if (cached is not null &&
            !cached.IsExpired(now) &&
            !cached.ShouldRefresh(now, _options.RefreshLeadMillis))
        {
            return cached;
        }

        await _mintGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Re-check under the lock: a concurrent caller may have just refreshed.
            now = _clock.NowMillis;
            cached = _current;
            if (cached is not null &&
                !cached.IsExpired(now) &&
                !cached.ShouldRefresh(now, _options.RefreshLeadMillis))
            {
                return cached;
            }

            try
            {
                var fresh = await MintFreshAsync(now, cancellationToken).ConfigureAwait(false);
                _current = fresh;
                return fresh;
            }
            catch (AppCheckMintException)
            {
                // A proactive refresh failed. If the still-cached token remains
                // genuinely valid (not expired), keep serving it — the served token
                // is real and unexpired, so this does not weaken the gate.
                var stillCached = _current;
                var nowAfter = _clock.NowMillis;
                if (stillCached is not null && !stillCached.IsExpired(nowAfter))
                {
                    return stillCached;
                }

                // Otherwise fail closed: clear any expired token so it can never be
                // served, and propagate.
                _current = null;
                throw;
            }
        }
        finally
        {
            _mintGate.Release();
        }
    }

    private async Task<AppCheckToken> MintFreshAsync(long nowMillis, CancellationToken cancellationToken)
    {
        var idToken = await _idTokenSource.GetIdTokenAsync(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(idToken))
        {
            throw AppCheckMintException.MissingIdToken();
        }

        var claim = await _producer.ProduceAsync(_options.AppId, nowMillis, cancellationToken).ConfigureAwait(false);
        return await _mintClient
            .MintAsync(claim, idToken, nowMillis, _options.RequestedTtlMillis, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Authorize an outbound request: obtain a valid token and, on success, write
    /// the <c>X-Firebase-AppCheck</c> header into <paramref name="headers"/>. On
    /// failure the header is NOT written and the returned decision is
    /// <see cref="AppCheckDecisionKind.Blocked"/> — the caller MUST abort the request.
    /// </summary>
    public async Task<AppCheckDecision> AuthorizeRequestAsync(
        IDictionary<string, string> headers,
        CancellationToken cancellationToken = default)
    {
        if (headers is null) throw new ArgumentNullException(nameof(headers));
        try
        {
            var token = await GetTokenAsync(cancellationToken).ConfigureAwait(false);
            headers[AppCheckHeader.Name] = token.Token;
            return AppCheckDecision.Attach(token);
        }
        catch (AppCheckMintException ex)
        {
            // Fail closed: ensure no App Check header lingers from a prior attempt.
            headers.Remove(AppCheckHeader.Name);
            return AppCheckDecision.Block(ex.Failure, ex.Message);
        }
    }

    /// <summary>
    /// Discard the cached token (e.g. after a downstream 401 that indicates the
    /// token was rejected), forcing a fresh mint on the next call.
    /// </summary>
    public void Invalidate()
    {
        _mintGate.Wait();
        try
        {
            _current = null;
        }
        finally
        {
            _mintGate.Release();
        }
    }

    public void Dispose()
    {
        _mintGate.Dispose();
    }
}
