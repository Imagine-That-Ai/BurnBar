using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// F2 in-process local HTTP gateway host (production path for multi-client probes).
/// Serves health + model list JSON on loopback. Not a full Hermes port — the live
/// multi-client gateway surface for Windows F2 composition.
/// </summary>
public sealed class LocalHttpGatewayHost : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly int _port;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public LocalHttpGatewayHost(int port = 8642)
    {
        if (port is <= 0 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port));
        }

        _port = port;
    }

    public int Port => _port;

    public Uri BaseAddress => new($"http://127.0.0.1:{_port}/");

    public bool IsRunning => _loop is { IsCompleted: false };

    public void Start()
    {
        if (_loop is not null)
        {
            return;
        }

        string prefix = $"http://127.0.0.1:{_port}/";
        _listener.Prefixes.Add(prefix);
        _listener.Start();
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { /* ignore */ }
        try { _listener.Stop(); } catch { /* ignore */ }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { /* ignore */ }
        }

        _listener.Close();
        _cts?.Dispose();
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync().ConfigureAwait(false);
            }
            catch (HttpListenerException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }

            _ = Task.Run(() => HandleAsync(context), cancellationToken);
        }
    }

    private static async Task HandleAsync(HttpListenerContext context)
    {
        try
        {
            string path = context.Request.Url?.AbsolutePath ?? "/";
            if (path is "/" or "/health" or "/v1/health")
            {
                await WriteJsonAsync(context.Response, 200, new Dictionary<string, object>
                {
                    ["ok"] = true,
                    ["service"] = "openburnbar-local-gateway",
                    ["finishLine"] = "F2",
                }).ConfigureAwait(false);
                return;
            }

            if (path is "/v1/models" or "/models")
            {
                await WriteJsonAsync(context.Response, 200, new Dictionary<string, object>
                {
                    ["object"] = "list",
                    ["data"] = new object[]
                    {
                        new Dictionary<string, object>
                        {
                            ["id"] = "openburnbar-local",
                            ["object"] = "model",
                            ["owned_by"] = "openburnbar",
                        },
                    },
                }).ConfigureAwait(false);
                return;
            }

            await WriteJsonAsync(context.Response, 404, new Dictionary<string, object>
            {
                ["error"] = "not_found",
                ["path"] = path,
            }).ConfigureAwait(false);
        }
        catch
        {
            try { context.Response.Abort(); } catch { /* ignore */ }
        }
    }

    private static async Task WriteJsonAsync(HttpListenerResponse response, int status, object body)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(body);
        response.StatusCode = status;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        response.OutputStream.Close();
    }
}
