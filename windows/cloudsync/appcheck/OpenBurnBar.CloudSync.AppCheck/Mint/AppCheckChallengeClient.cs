using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

/// <summary>Requests the authenticated, single-use nonce used by TPM attestation.</summary>
public sealed class AppCheckChallengeClient
{
    private readonly AppCheckChallengeEndpoint _endpoint;
    private readonly IAppCheckMintTransport _transport;
    private readonly double _timeoutSeconds;

    public AppCheckChallengeClient(
        AppCheckChallengeEndpoint endpoint,
        IAppCheckMintTransport transport,
        double timeoutSeconds = 20.0)
    {
        _endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        if (timeoutSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(timeoutSeconds));
        _timeoutSeconds = timeoutSeconds;
    }

    public async Task<AttestationChallenge> IssueAsync(
        string appId,
        string idToken,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(appId)) throw new ArgumentException("appId is required.", nameof(appId));
        if (string.IsNullOrWhiteSpace(idToken)) throw AppCheckMintException.MissingIdToken();

        var body = JsonSerializer.SerializeToUtf8Bytes(new { data = new { appId } });
        var response = await _transport.SendAsync(
            new AppCheckMintHttpRequest(
                "POST",
                _endpoint.Url.ToString(),
                new List<AppCheckMintHeader>
                {
                    new("Authorization", $"Bearer {idToken}"),
                    new("Content-Type", "application/json"),
                    new("Accept", "application/json"),
                },
                body,
                _timeoutSeconds),
            cancellationToken).ConfigureAwait(false);

        if (response.StatusCode is < 200 or >= 300)
        {
            throw AppCheckMintException.Rejected(response.StatusCode, "challenge request rejected");
        }

        try
        {
            using var document = JsonDocument.Parse(response.Body);
            var result = document.RootElement.GetProperty("result");
            if (!result.GetProperty("ok").GetBoolean())
            {
                throw AppCheckMintException.Rejected(response.StatusCode, "challenge request was not accepted");
            }
            var challengeId = result.GetProperty("challengeId").GetString();
            var nonce = result.GetProperty("nonce").GetString();
            if (!result.GetProperty("expiresAtMs").TryGetInt64(out var expiresAtMs))
            {
                throw AppCheckMintException.Malformed("invalid challenge expiry");
            }
            if (string.IsNullOrWhiteSpace(challengeId) || string.IsNullOrWhiteSpace(nonce) || expiresAtMs <= 0)
            {
                throw AppCheckMintException.Malformed("invalid challenge payload");
            }
            return new AttestationChallenge
            {
                ChallengeId = challengeId,
                Nonce = nonce,
                ExpiresAtMs = expiresAtMs,
            };
        }
        catch (AppCheckMintException)
        {
            throw;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            throw AppCheckMintException.Malformed($"invalid challenge response ({ex.Message})");
        }
    }
}
