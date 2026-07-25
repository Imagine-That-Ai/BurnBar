using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// F2 companion CLI multi-client plane: loopback TCP JSON-line protocol.
/// Multiple clients can connect; each request gets a JSON response.
/// </summary>
public sealed class CompanionCliServer : IAsyncDisposable
{
    public const int MaxLineBytes = 512 * 1024;

    private readonly TcpListener _listener;
    private readonly ConcurrentDictionary<Guid, ClientConnection> _clients = new();
    private readonly ICompanionCliCommandHandler? _handler;
    private readonly byte[]? _accessToken;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public CompanionCliServer(
        int port = 8765,
        ICompanionCliCommandHandler? handler = null,
        string? accessToken = null)
    {
        _listener = new TcpListener(IPAddress.Loopback, port);
        Port = port;
        _handler = handler;
        _accessToken = string.IsNullOrWhiteSpace(accessToken)
            ? null
            : Encoding.UTF8.GetBytes(accessToken.Trim());
    }

    /// <summary>
    /// Bound loopback port. When constructed with port <c>0</c>, this is
    /// populated with the OS-assigned ephemeral port after <see cref="Start"/>.
    /// </summary>
    public int Port { get; private set; }

    public int ConnectedClients => _clients.Count;

    public void Start()
    {
        if (_acceptLoop is not null)
        {
            return;
        }

        _listener.Start();
        if (_listener.LocalEndpoint is IPEndPoint endpoint)
        {
            Port = endpoint.Port;
        }
        _cts = new CancellationTokenSource();
        _acceptLoop = Task.Run(() => AcceptAsync(_cts.Token));
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _listener.Stop(); } catch { /* ignore */ }
        foreach (ClientConnection client in _clients.Values)
        {
            client.Dispose();
        }

        _clients.Clear();
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { /* ignore */ }
        }

        _cts?.Dispose();
    }

    private async Task AcceptAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient tcp;
            try
            {
                tcp = await _listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (SocketException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }

            var id = Guid.NewGuid();
            var conn = new ClientConnection(id, tcp);
            _clients[id] = conn;
            _ = Task.Run(() => ServeClientAsync(conn, cancellationToken), cancellationToken);
        }
    }

    private async Task ServeClientAsync(ClientConnection conn, CancellationToken cancellationToken)
    {
        try
        {
            var utf8WithoutBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
            using var reader = new StreamReader(conn.Stream, utf8WithoutBom);
            using var writer = new StreamWriter(conn.Stream, utf8WithoutBom) { AutoFlush = true };
            var boundedReader = new BoundedLineReader(reader);
            CompanionCliAuthentication.Session? authenticationSession = null;
            var connectionAuthenticated = _accessToken is null;
            while (!cancellationToken.IsCancellationRequested)
            {
                BoundedLine line = await boundedReader.ReadAsync(cancellationToken).ConfigureAwait(false);
                if (line.Value is null && !line.TooLarge)
                {
                    break;
                }

                string response;
                if (line.TooLarge)
                {
                    response = JsonSerializer.Serialize(new { ok = false, error = "request_too_large" });
                }
                else if (!connectionAuthenticated && authenticationSession is null)
                {
                    authenticationSession = CompanionCliAuthentication.TryCreateSession(line.Value!, _accessToken!);
                    response = authenticationSession is null
                        ? JsonSerializer.Serialize(new { ok = false, error = "authentication_required" })
                        : CompanionCliAuthentication.ChallengeResponse(authenticationSession);
                }
                else
                {
                    string requestLine = line.Value!;
                    if (!connectionAuthenticated)
                    {
                        requestLine = CompanionCliAuthentication.VerifyAndStripProof(
                            requestLine,
                            authenticationSession!,
                            _accessToken!);
                        connectionAuthenticated = true;
                    }
                    response = await HandleLineAsync(requestLine, _handler, cancellationToken).ConfigureAwait(false);
                }
                await writer.WriteLineAsync(response.AsMemory(), cancellationToken).ConfigureAwait(false);
            }
        }
        catch
        {
            // client disconnect
        }
        finally
        {
            _clients.TryRemove(conn.Id, out _);
            conn.Dispose();
        }
    }

    private static BoundedLine FinishBoundedLine(StringBuilder builder, bool tooLarge)
    {
        string value = builder.ToString();
        return new BoundedLine(
            value,
            tooLarge || Encoding.UTF8.GetByteCount(value) > MaxLineBytes);
    }

    private readonly record struct BoundedLine(string? Value, bool TooLarge);

    private sealed class BoundedLineReader
    {
        private readonly StreamReader _reader;
        private readonly char[] _buffer = new char[4096];
        private readonly StringBuilder _builder = new(capacity: 1024);
        private int _offset;
        private int _count;
        private bool _tooLarge;

        public BoundedLineReader(StreamReader reader)
        {
            _reader = reader;
        }

        public async Task<BoundedLine> ReadAsync(CancellationToken cancellationToken)
        {
            while (true)
            {
                if (_offset >= _count)
                {
                    _count = await _reader.ReadAsync(_buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                    _offset = 0;
                    if (_count == 0)
                    {
                        if (_builder.Length == 0 && !_tooLarge) return new BoundedLine(null, false);
                        return FinishLine();
                    }
                }

                while (_offset < _count)
                {
                    char character = _buffer[_offset++];
                    if (character == '\n') return FinishLine();
                    if (character == '\r') continue;
                    if (_builder.Length < MaxLineBytes) _builder.Append(character);
                    else _tooLarge = true;
                }
            }
        }

        private BoundedLine FinishLine()
        {
            BoundedLine line = FinishBoundedLine(_builder, _tooLarge);
            _builder.Clear();
            _tooLarge = false;
            return line;
        }
    }

    /// <summary>Pure request handler (testable without sockets).</summary>
    public static string HandleLine(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return JsonSerializer.Serialize(new { ok = false, error = "empty" });
        }

        try
        {
            using JsonDocument doc = JsonDocument.Parse(line);
            string op = doc.RootElement.TryGetProperty("op", out JsonElement opEl)
                ? opEl.GetString() ?? ""
                : "";
            return op switch
            {
                "ping" => JsonSerializer.Serialize(new { ok = true, pong = true }),
                "version" => JsonSerializer.Serialize(new { ok = true, version = "f2-companion-cli-1" }),
                "clients" => JsonSerializer.Serialize(new { ok = true, note = "multi-client plane" }),
                _ => JsonSerializer.Serialize(new { ok = false, error = "unknown_op", op }),
            };
        }
        catch (JsonException)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "invalid_json" });
        }
    }

    public static async Task<string> HandleLineAsync(
        string line,
        ICompanionCliCommandHandler? handler,
        CancellationToken cancellationToken = default,
        byte[]? accessToken = null)
    {
        if (Encoding.UTF8.GetByteCount(line) > MaxLineBytes)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "request_too_large" });
        }

        try
        {
            if (accessToken is not null)
            {
                if (!IsAuthorized(line, accessToken))
                {
                    return JsonSerializer.Serialize(new { ok = false, error = "unauthorized" });
                }

                // Do not expose the bearer token to command handlers.
                line = StripAuthToken(line);
            }

            if (handler is null)
            {
                return HandleLine(line);
            }

            return await handler.HandleAsync(line, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (ArgumentException)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "invalid_request" });
        }
        catch (Exception)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "handler_failed" });
        }
    }

    private static bool IsAuthorized(string line, byte[] expectedToken)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("authToken", out JsonElement tokenElement)
                || tokenElement.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            byte[] actual = Encoding.UTF8.GetBytes(tokenElement.GetString()?.Trim() ?? string.Empty);
            return CryptographicOperations.FixedTimeEquals(actual, expectedToken);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string StripAuthToken(string line)
    {
        JsonObject? root = JsonNode.Parse(line) as JsonObject;
        if (root is null)
        {
            return line;
        }

        root.Remove("authToken");
        return root.ToJsonString();
    }

    private sealed class ClientConnection : IDisposable
    {
        public ClientConnection(Guid id, TcpClient client)
        {
            Id = id;
            Client = client;
            Stream = client.GetStream();
        }

        public Guid Id { get; }

        public TcpClient Client { get; }

        public NetworkStream Stream { get; }

        public void Dispose()
        {
            try { Stream.Dispose(); } catch { /* ignore */ }
            try { Client.Dispose(); } catch { /* ignore */ }
        }
    }
}

public static class CompanionCliAuthentication
{
    private const string ChallengeOperation = "auth.challenge.v1";
    private const string ProofProperty = "authProof";

    public sealed record Session(string ClientNonce, string ServerNonce, string ServerProof);

    public static Session? TryCreateSession(string line, byte[] accessToken)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                root.GetProperty("op").GetString() != ChallengeOperation ||
                !root.TryGetProperty("clientNonce", out JsonElement nonceElement) ||
                nonceElement.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            string clientNonce = nonceElement.GetString() ?? string.Empty;
            if (!IsCanonicalNonce(clientNonce)) return null;
            string serverNonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
            string proof = ComputeProof(accessToken, $"server\n{clientNonce}\n{serverNonce}");
            return new Session(clientNonce, serverNonce, proof);
        }
        catch (Exception exception) when (exception is JsonException or KeyNotFoundException or FormatException)
        {
            return null;
        }
    }

    public static string ChallengeResponse(Session session) => JsonSerializer.Serialize(new
    {
        ok = true,
        op = ChallengeOperation,
        serverNonce = session.ServerNonce,
        serverProof = session.ServerProof,
    });

    public static string VerifyAndStripProof(string line, Session session, byte[] accessToken)
    {
        JsonObject root = JsonNode.Parse(line) as JsonObject
            ?? throw new ArgumentException("The authenticated request must be an object.", nameof(line));
        if (root[ProofProperty] is not JsonObject proof ||
            proof["clientNonce"]?.GetValue<string>() != session.ClientNonce ||
            proof["serverNonce"]?.GetValue<string>() != session.ServerNonce)
        {
            throw new ArgumentException("The companion authentication proof is missing or mismatched.", nameof(line));
        }
        string supplied = proof["proof"]?.GetValue<string>() ?? string.Empty;
        root.Remove(ProofProperty);
        string canonicalRequest = root.ToJsonString();
        string requestDigest = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)));
        string expected = ComputeProof(
            accessToken,
            $"client\n{session.ClientNonce}\n{session.ServerNonce}\n{requestDigest}");
        if (!FixedTimeBase64Equals(supplied, expected))
        {
            throw new ArgumentException("The companion authentication proof is invalid.", nameof(line));
        }
        return canonicalRequest;
    }

    public static string CreateClientProof(
        JsonObject request,
        string clientNonce,
        string serverNonce,
        byte[] accessToken)
    {
        string requestDigest = Convert.ToBase64String(
            SHA256.HashData(Encoding.UTF8.GetBytes(request.ToJsonString())));
        return ComputeProof(accessToken, $"client\n{clientNonce}\n{serverNonce}\n{requestDigest}");
    }

    public static bool VerifyServerProof(
        string supplied,
        string clientNonce,
        string serverNonce,
        byte[] accessToken)
    {
        string expected = ComputeProof(accessToken, $"server\n{clientNonce}\n{serverNonce}");
        return FixedTimeBase64Equals(supplied, expected);
    }

    private static string ComputeProof(byte[] key, string value) =>
        Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(value)));

    private static bool FixedTimeBase64Equals(string left, string right)
    {
        try
        {
            byte[] leftBytes = Convert.FromBase64String(left);
            byte[] rightBytes = Convert.FromBase64String(right);
            return CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool IsCanonicalNonce(string value)
    {
        try
        {
            return Convert.FromBase64String(value).Length == 32;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}

public interface ICompanionCliCommandHandler
{
    Task<string> HandleAsync(string line, CancellationToken cancellationToken);
}

/// <summary>
/// Connector-plane command router. Expensive work is supplied by injected
/// handlers so the protocol core never shells out or embeds provider secrets.
/// </summary>
public sealed class CompanionCliCommandRouter : ICompanionCliCommandHandler
{
    private readonly ModelProxyRouter? _router;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _submit;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _resume;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _fusion;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _code;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _recover;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _missionSubmit;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _missionResume;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _plan;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _policy;
    private readonly Func<JsonElement, CancellationToken, Task<object?>>? _tooling;
    private readonly CompanionCliAgentRunHandler? _agentRuns;
    private readonly CompanionCliTelegramHandler? _telegram;

    public CompanionCliCommandRouter(
        ModelProxyRouter? router = null,
        Func<JsonElement, CancellationToken, Task<object?>>? submit = null,
        Func<JsonElement, CancellationToken, Task<object?>>? resume = null,
        Func<JsonElement, CancellationToken, Task<object?>>? fusion = null,
        Func<JsonElement, CancellationToken, Task<object?>>? code = null,
        Func<JsonElement, CancellationToken, Task<object?>>? recover = null,
        Func<JsonElement, CancellationToken, Task<object?>>? missionSubmit = null,
        Func<JsonElement, CancellationToken, Task<object?>>? missionResume = null,
        Func<JsonElement, CancellationToken, Task<object?>>? plan = null,
        Func<JsonElement, CancellationToken, Task<object?>>? policy = null,
        CompanionCliAgentRunHandler? agentRuns = null,
        CompanionCliTelegramHandler? telegram = null,
        Func<JsonElement, CancellationToken, Task<object?>>? tooling = null)
    {
        _router = router;
        _submit = submit;
        _resume = resume;
        _fusion = fusion;
        _code = code;
        _recover = recover;
        _missionSubmit = missionSubmit;
        _missionResume = missionResume;
        _plan = plan;
        _policy = policy;
        _agentRuns = agentRuns;
        _telegram = telegram;
        _tooling = tooling;
    }

    public async Task<string> HandleAsync(string line, CancellationToken cancellationToken)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(line);
            JsonElement root = doc.RootElement;
            string op = root.TryGetProperty("op", out JsonElement opElement)
                ? opElement.GetString() ?? string.Empty
                : string.Empty;
            return op switch
            {
                "health" => JsonSerializer.Serialize(new { ok = true, status = "ready" }),
                "models" => JsonSerializer.Serialize(new
                {
                    ok = true,
                    data = (_router?.Routes ?? Array.Empty<ModelRoute>()).Where(route => route.Healthy)
                        .Select(route => new
                        {
                            id = route.Model,
                            vendor = route.Vendor,
                            display_name = route.Discovery?.DisplayName ?? route.Model,
                            discovered = route.Discovery is not null,
                            source_kind = route.Discovery?.SourceKind,
                        })
                        .ToArray(),
                }),
                "run.submit" => await InvokeRunAsync(_submit, root, cancellationToken).ConfigureAwait(false),
                "run.resume" => await InvokeRunAsync(_resume, root, cancellationToken).ConfigureAwait(false),
                "run.recover" => await InvokeRunAsync(_recover, root, cancellationToken).ConfigureAwait(false),
                "run.get" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.GetAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "run.poll" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.PollAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "run.cancel" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.CancelAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "run.retry" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.RetryAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "workspace.executeTool" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.ClaimToolAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "workspace.toolResult" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.SubmitToolResultAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "approval.respond" => await InvokeAgentAsync(_agentRuns, static (handler, request, token) => handler.RespondToApprovalAsync(request, token), root, cancellationToken).ConfigureAwait(false),
                "mission.submit" => await InvokeRunAsync(_missionSubmit, root, cancellationToken).ConfigureAwait(false),
                "mission.resume" => await InvokeRunAsync(_missionResume, root, cancellationToken).ConfigureAwait(false),
                "planner.plan" => await InvokeRunAsync(_plan, root, cancellationToken).ConfigureAwait(false),
                "policy.evaluate" => await InvokeRunAsync(_policy, root, cancellationToken).ConfigureAwait(false),
                "connector.get" or "connector.update" or "connector.action"
                    or "workspace.bridge.enqueue" or "workspace.bridge.claim" or "workspace.bridge.result"
                    or "workspace.bridge.clear" or "workspace.bridge.cancel" or "context.next" or "context.snapshot" =>
                    await InvokeRunAsync(_tooling, root, cancellationToken).ConfigureAwait(false),
                "notification.followup.record" => await InvokeTelegramAsync(
                    static (handler, request, token) => handler.RecordFollowupAsync(request, token),
                    root,
                    cancellationToken).ConfigureAwait(false),
                "notification.question.record" => await InvokeTelegramAsync(
                    static (handler, request, token) => handler.RecordQuestionAsync(request, token),
                    root,
                    cancellationToken).ConfigureAwait(false),
                "notification.command" => await InvokeTelegramAsync(
                    static (handler, request, token) => handler.ExecuteCommandAsync(request, token),
                    root,
                    cancellationToken).ConfigureAwait(false),
                "fusion.run" => await InvokeRunAsync(_fusion, root, cancellationToken).ConfigureAwait(false),
                "code.index" or "code.search" or "code.symbol" or "code.status" or "code.context_pack" or "code.references" or "code.call_graph" or "code.semantic_search" =>
                    await InvokeRunAsync(_code, root, cancellationToken).ConfigureAwait(false),
                "ping" => JsonSerializer.Serialize(new { ok = true, pong = true }),
                "version" => JsonSerializer.Serialize(new { ok = true, version = "f2-companion-cli-9" }),
                _ => JsonSerializer.Serialize(new { ok = false, error = "unknown_op", op }),
            };
        }
        catch (JsonException)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "invalid_json" });
        }
    }

    private static async Task<string> InvokeRunAsync(
        Func<JsonElement, CancellationToken, Task<object?>>? handler,
        JsonElement request,
        CancellationToken cancellationToken)
    {
        if (handler is null)
        {
            return JsonSerializer.Serialize(new { ok = false, error = "run_unavailable" });
        }

        try
        {
            object? result = await handler(request.Clone(), cancellationToken).ConfigureAwait(false);
            return JsonSerializer.Serialize(new { ok = true, result });
        }
        catch (BurnBarPlannerException exception)
        {
            return JsonSerializer.Serialize(new
            {
                ok = false,
                error = exception.Code,
                message = exception.Message,
            });
        }
        catch (HeadlessAgentRunException exception)
        {
            return JsonSerializer.Serialize(new
            {
                ok = false,
                error = exception.Code,
                message = exception.Message,
            });
        }
        catch (ArgumentException exception)
        {
            return JsonSerializer.Serialize(new
            {
                ok = false,
                error = "invalid_request",
                message = exception.Message,
            });
        }
    }

    private static Task<string> InvokeAgentAsync(
        CompanionCliAgentRunHandler? handler,
        Func<CompanionCliAgentRunHandler, JsonElement, CancellationToken, Task<object?>> operation,
        JsonElement request,
        CancellationToken cancellationToken) =>
        InvokeRunAsync(
            handler is null
                ? null
                : (input, token) => operation(handler, input, token),
            request,
            cancellationToken);

    private Task<string> InvokeTelegramAsync(
        Func<CompanionCliTelegramHandler, JsonElement, CancellationToken, Task<object?>> operation,
        JsonElement request,
        CancellationToken cancellationToken) =>
        InvokeRunAsync(
            _telegram is null
                ? null
                : (input, token) => operation(_telegram, input, token),
            request,
            cancellationToken);
}
