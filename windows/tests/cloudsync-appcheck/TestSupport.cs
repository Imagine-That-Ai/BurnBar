using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>Shared fakes + helpers for the App Check client tests.</summary>
internal static class TestConstants
{
    public const string PlaceholderAppId = "1:000000000000:windows:0000000000000000placeholder";
    public const string SampleIdToken = "eyJhbGciOiJSUzI1NiJ9.fake.id-token";

    /// <summary>Build the JSON body a successful mint callable returns.</summary>
    public static string SuccessBody(string appCheckToken, long ttlMillis, string appId) =>
        $"{{\"result\":{{\"ok\":true,\"appCheckToken\":\"{appCheckToken}\",\"ttlMillis\":{ttlMillis},\"appId\":\"{appId}\"}}}}";

    /// <summary>Build a Firebase callable error envelope body.</summary>
    public static string ErrorBody(string status, string message) =>
        $"{{\"error\":{{\"status\":\"{status}\",\"message\":\"{message}\"}}}}";
}

/// <summary>
/// A deterministic <see cref="IAppCheckMintTransport"/> that captures the request
/// it was handed and returns a scripted response (or throws a scripted fault).
/// </summary>
internal sealed class FakeMintTransport : IAppCheckMintTransport
{
    private readonly Func<AppCheckMintHttpRequest, AppCheckMintHttpResponse> _responder;

    public int CallCount { get; private set; }
    public AppCheckMintHttpRequest? LastRequest { get; private set; }
    public string? LastBodyUtf8 => LastRequest is null ? null : Encoding.UTF8.GetString(LastRequest.Body);

    public FakeMintTransport(Func<AppCheckMintHttpRequest, AppCheckMintHttpResponse> responder)
    {
        _responder = responder;
    }

    /// <summary>Always return HTTP 200 with the given success token.</summary>
    public static FakeMintTransport Success(string token, long ttlMillis, string appId) =>
        new(_ => new AppCheckMintHttpResponse(200, TestConstants.SuccessBody(token, ttlMillis, appId)));

    /// <summary>Return HTTP 200 but with a distinct token each call (to observe refreshes).</summary>
    public static FakeMintTransport Sequence(long ttlMillis, string appId, params string[] tokens)
    {
        var index = 0;
        return new FakeMintTransport(_ =>
        {
            var token = tokens[Math.Min(index, tokens.Length - 1)];
            index++;
            return new AppCheckMintHttpResponse(200, TestConstants.SuccessBody(token, ttlMillis, appId));
        });
    }

    /// <summary>Reject with an HTTP status + error envelope.</summary>
    public static FakeMintTransport Rejecting(int statusCode, string status = "permission-denied", string message = "denied") =>
        new(_ => new AppCheckMintHttpResponse(statusCode, TestConstants.ErrorBody(status, message)));

    /// <summary>Throw a transport fault (unreachable host).</summary>
    public static FakeMintTransport Throwing(AppCheckMintException fault) =>
        new(_ => throw fault);

    public Task<AppCheckMintHttpResponse> SendAsync(
        AppCheckMintHttpRequest request,
        CancellationToken cancellationToken = default)
    {
        CallCount++;
        LastRequest = request;
        return Task.FromResult(_responder(request));
    }
}

/// <summary>An id-token source returning a fixed token, or null (signed out).</summary>
internal sealed class StubIdTokenSource : IFirebaseIdTokenSource
{
    private readonly string? _token;
    public int CallCount { get; private set; }

    public StubIdTokenSource(string? token)
    {
        _token = token;
    }

    public ValueTask<string?> GetIdTokenAsync(CancellationToken cancellationToken = default)
    {
        CallCount++;
        return new ValueTask<string?>(_token);
    }
}

/// <summary>A nonce source yielding a fixed sequence, then repeating the last one.</summary>
internal sealed class SequenceNonceSource : INonceSource
{
    private readonly string[] _nonces;
    private int _index;

    public SequenceNonceSource(params string[] nonces)
    {
        _nonces = nonces.Length == 0 ? new[] { "fixed-nonce-0123456789abcdef" } : nonces;
    }

    public string NextNonce()
    {
        var nonce = _nonces[Math.Min(_index, _nonces.Length - 1)];
        _index++;
        return nonce;
    }
}

/// <summary>An attestation producer that records how many times it produced a claim.</summary>
internal sealed class CountingAttestationProducer : IAttestationProducer
{
    private readonly IAttestationProducer _inner;
    public int ProduceCount { get; private set; }

    public CountingAttestationProducer(IAttestationProducer inner)
    {
        _inner = inner;
    }

    public string Kind => _inner.Kind;

    public async ValueTask<WindowsAttestationClaim> ProduceAsync(
        string appId, long nowMillis, CancellationToken cancellationToken = default)
    {
        ProduceCount++;
        return await _inner.ProduceAsync(appId, nowMillis, cancellationToken).ConfigureAwait(false);
    }
}
