using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// F2 companion CLI multi-client plane: loopback TCP JSON-line protocol.
/// Multiple clients can connect; each request gets a JSON response.
/// </summary>
public sealed class CompanionCliServer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly ConcurrentDictionary<Guid, ClientConnection> _clients = new();
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public CompanionCliServer(int port = 8765)
    {
        _listener = new TcpListener(IPAddress.Loopback, port);
        Port = port;
    }

    public int Port { get; }

    public int ConnectedClients => _clients.Count;

    public void Start()
    {
        if (_acceptLoop is not null)
        {
            return;
        }

        _listener.Start();
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
            using var reader = new StreamReader(conn.Stream, Encoding.UTF8);
            using var writer = new StreamWriter(conn.Stream, Encoding.UTF8) { AutoFlush = true };
            while (!cancellationToken.IsCancellationRequested)
            {
                string? line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                string response = HandleLine(line);
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
