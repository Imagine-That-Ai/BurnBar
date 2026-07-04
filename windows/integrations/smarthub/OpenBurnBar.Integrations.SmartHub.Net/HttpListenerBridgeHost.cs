using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.SmartHub.Bridge;
using OpenBurnBar.Integrations.SmartHub.Discovery;

namespace OpenBurnBar.Integrations.SmartHub.Net;

// Live HTTP listener fronting the pure BridgeRouter.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift NWListener +
// connection handling. Every request is turned into a portable BridgeRequest,
// dispatched through the pure BridgeRouter, and the resulting BridgeResponse is
// written back — so all routing, auth, and JSON contract behavior lives in the
// tested core; this adapter only owns the socket.

public sealed class HttpListenerBridgeHost : IBridgeSocketHost, IDisposable
{
    private readonly BridgeRouter _router;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public bool IsRunning { get; private set; }
    public int? BoundPort { get; private set; }

    public HttpListenerBridgeHost(BridgeRouter router)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
    }

    public Task StartAsync(int port = 8787, CancellationToken cancellationToken = default) =>
        StartAsync(new[] { $"http://127.0.0.1:{port}/" }, port, cancellationToken);

    /// Starts the listener on the given prefixes. The Windows bridge binds all
    /// interfaces ("http://+:{port}/", admin-gated); tests bind loopback.
    public Task StartAsync(IReadOnlyList<string> prefixes, int port, CancellationToken cancellationToken = default)
    {
        if (IsRunning)
        {
            return Task.CompletedTask;
        }
        var listener = new HttpListener();
        foreach (var prefix in prefixes)
        {
            listener.Prefixes.Add(prefix);
        }
        listener.Start();

        _listener = listener;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        BoundPort = port;
        IsRunning = true;
        _acceptLoop = Task.Run(() => AcceptLoopAsync(listener, _cts.Token));
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        IsRunning = false;
        _cts?.Cancel();
        try
        {
            _listener?.Stop();
            _listener?.Close();
        }
        catch (ObjectDisposedException)
        {
            // Already torn down.
        }
        if (_acceptLoop is not null)
        {
            try
            {
                await _acceptLoop.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
        }
        _listener = null;
        BoundPort = null;
    }

    private async Task AcceptLoopAsync(HttpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && listener.IsListening)
        {
            HttpListenerContext context;
            try
            {
                context = await listener.GetContextAsync().ConfigureAwait(false);
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (HttpListenerException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }

            _ = Task.Run(() => HandleContextAsync(context), cancellationToken);
        }
    }

    private async Task HandleContextAsync(HttpListenerContext context)
    {
        try
        {
            var request = await BuildRequestAsync(context.Request).ConfigureAwait(false);
            var response = await _router.DispatchAsync(request).ConfigureAwait(false);
            WriteResponse(context.Response, response);
        }
        catch (Exception)
        {
            TryWriteError(context.Response);
        }
    }

    private static async Task<BridgeRequest> BuildRequestAsync(HttpListenerRequest request)
    {
        var rawPath = request.Url?.PathAndQuery ?? request.RawUrl ?? "/";
        var pathOnly = request.Url?.AbsolutePath ?? SplitFirst(rawPath, '?');

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string? key in request.Headers.AllKeys)
        {
            if (key is not null && !headers.ContainsKey(key))
            {
                headers[key] = request.Headers[key] ?? string.Empty;
            }
        }

        byte[]? body = null;
        if (request.HasEntityBody)
        {
            using var ms = new MemoryStream();
            await request.InputStream.CopyToAsync(ms).ConfigureAwait(false);
            body = ms.ToArray();
        }

        return new BridgeRequest(request.HttpMethod, rawPath, pathOnly, headers, body);
    }

    private static void WriteResponse(HttpListenerResponse httpResponse, BridgeResponse response)
    {
        httpResponse.StatusCode = response.StatusCode;
        httpResponse.StatusDescription = response.ReasonPhrase;
        if (response.ContentType is not null)
        {
            httpResponse.ContentType = response.ContentType;
        }
        foreach (var header in response.ExtraHeaders)
        {
            httpResponse.Headers[header.Key] = header.Value;
        }
        httpResponse.ContentLength64 = response.Body.Length;
        if (response.Body.Length > 0)
        {
            httpResponse.OutputStream.Write(response.Body, 0, response.Body.Length);
        }
        httpResponse.OutputStream.Close();
    }

    private static void TryWriteError(HttpListenerResponse httpResponse)
    {
        try
        {
            var response = BridgeResponse.Status(500);
            WriteResponse(httpResponse, response);
        }
        catch (Exception)
        {
            // Best-effort; the socket may already be gone.
        }
    }

    private static string SplitFirst(string value, char separator)
    {
        var idx = value.IndexOf(separator);
        return idx < 0 ? value : value.Substring(0, idx);
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _listener?.Close();
        _cts?.Dispose();
    }
}
