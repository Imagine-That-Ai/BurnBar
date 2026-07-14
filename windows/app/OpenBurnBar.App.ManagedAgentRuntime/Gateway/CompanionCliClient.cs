using System;
using System.Buffers;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record CompanionCliClientOptions(
    int Port = 8765,
    TimeSpan? Timeout = null,
    bool RequireAuthentication = true)
{
    public TimeSpan EffectiveTimeout => Timeout ?? TimeSpan.FromSeconds(15);

    public void Validate()
    {
        if (Port is <= 0 or > 65535)
        {
            throw new CompanionCliClientException("invalid_port", "The companion port must be between 1 and 65535.");
        }

        if (EffectiveTimeout <= TimeSpan.Zero || EffectiveTimeout > TimeSpan.FromMinutes(5))
        {
            throw new CompanionCliClientException("invalid_timeout", "The companion timeout must be between 1 millisecond and 5 minutes.");
        }
    }
}

public sealed class CompanionCliClientException : Exception
{
    public CompanionCliClientException(string code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}

public interface ICompanionCliClient
{
    Task<JsonElement> ExchangeAsync(JsonElement request, CancellationToken cancellationToken = default);
}

/// <summary>
/// Bounded one-request loopback client for the production companion JSON-line plane.
/// Authentication is injected from protected storage and never accepted in request JSON.
/// </summary>
public sealed class CompanionCliClient : ICompanionCliClient
{
    private readonly CompanionCliClientOptions _options;
    private readonly Func<string?> _accessTokenProvider;

    public CompanionCliClient(CompanionCliClientOptions options, Func<string?> accessTokenProvider)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _accessTokenProvider = accessTokenProvider ?? throw new ArgumentNullException(nameof(accessTokenProvider));
        _options.Validate();
    }

    public async Task<JsonElement> ExchangeAsync(
        JsonElement request,
        CancellationToken cancellationToken = default)
    {
        if (request.ValueKind != JsonValueKind.Object)
        {
            throw new CompanionCliClientException("invalid_request", "The companion request must be a JSON object.");
        }

        JsonObject root;
        try
        {
            root = JsonNode.Parse(request.GetRawText())?.AsObject()
                ?? throw new CompanionCliClientException("invalid_request", "The companion request must be a JSON object.");
        }
        catch (InvalidOperationException exception)
        {
            throw new CompanionCliClientException("invalid_request", "The companion request must be a JSON object.", exception);
        }

        if (root.ContainsKey("authToken"))
        {
            throw new CompanionCliClientException(
                "inline_auth_forbidden",
                "Authentication must come from protected storage, not request JSON.");
        }

        string? accessToken = null;
        if (_options.RequireAuthentication)
        {
            try
            {
                accessToken = _accessTokenProvider()?.Trim();
            }
            catch (Exception exception) when (exception is not CompanionCliClientException)
            {
                throw new CompanionCliClientException(
                    "protected_token_unavailable",
                    "The protected companion access token could not be read.",
                    exception);
            }

            if (string.IsNullOrWhiteSpace(accessToken))
            {
                throw new CompanionCliClientException(
                    "protected_token_missing",
                    "No protected companion access token exists. Start OpenBurnBar once or configure the Model Proxy token.");
            }

            root["authToken"] = accessToken;
        }

        byte[]? payload = null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_options.EffectiveTimeout);
        try
        {
            payload = JsonSerializer.SerializeToUtf8Bytes(root);
            if (payload.Length > CompanionCliServer.MaxLineBytes)
            {
                throw new CompanionCliClientException("request_too_large", "The companion request exceeds the 512 KiB protocol limit.");
            }

            using var client = new TcpClient(AddressFamily.InterNetwork);
            await client.ConnectAsync(IPAddress.Loopback, _options.Port, timeout.Token).ConfigureAwait(false);
            await using NetworkStream stream = client.GetStream();
            await stream.WriteAsync(payload, timeout.Token).ConfigureAwait(false);
            await stream.WriteAsync("\n"u8.ToArray(), timeout.Token).ConfigureAwait(false);
            await stream.FlushAsync(timeout.Token).ConfigureAwait(false);

            string response = await ReadBoundedLineAsync(stream, timeout.Token).ConfigureAwait(false);
            response = response.TrimStart('\uFEFF');
            try
            {
                using JsonDocument document = JsonDocument.Parse(response);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    throw new CompanionCliClientException("invalid_response", "The companion response was not a JSON object.");
                }

                return document.RootElement.Clone();
            }
            catch (JsonException exception)
            {
                throw new CompanionCliClientException("invalid_response", "The companion response was not valid JSON.", exception);
            }
        }
        catch (OperationCanceledException exception) when (!cancellationToken.IsCancellationRequested)
        {
            throw new CompanionCliClientException("timeout", "The companion request timed out.", exception);
        }
        catch (SocketException exception)
        {
            throw new CompanionCliClientException(
                "companion_unavailable",
                "OpenBurnBar is not accepting companion connections on the configured loopback port.",
                exception);
        }
        catch (IOException exception)
        {
            throw new CompanionCliClientException("connection_failed", "The companion connection closed unexpectedly.", exception);
        }
        finally
        {
            if (!string.IsNullOrEmpty(accessToken))
            {
                root.Remove("authToken");
                if (payload is not null)
                {
                    Array.Clear(payload);
                }
            }
        }
    }

    private static async Task<string> ReadBoundedLineAsync(Stream stream, CancellationToken cancellationToken)
    {
        var output = new ArrayBufferWriter<byte>(4096);
        byte[] buffer = new byte[4096];
        while (true)
        {
            int count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                if (output.WrittenCount == 0)
                {
                    throw new CompanionCliClientException("empty_response", "The companion closed without a response.");
                }

                break;
            }

            for (int index = 0; index < count; index++)
            {
                byte value = buffer[index];
                if (value == (byte)'\n')
                {
                    return Encoding.UTF8.GetString(output.WrittenSpan);
                }

                if (value == (byte)'\r')
                {
                    continue;
                }

                if (output.WrittenCount >= CompanionCliServer.MaxLineBytes)
                {
                    throw new CompanionCliClientException(
                        "response_too_large",
                        "The companion response exceeds the 512 KiB protocol limit.");
                }

                output.GetSpan(1)[0] = value;
                output.Advance(1);
            }
        }

        return Encoding.UTF8.GetString(output.WrittenSpan);
    }
}
