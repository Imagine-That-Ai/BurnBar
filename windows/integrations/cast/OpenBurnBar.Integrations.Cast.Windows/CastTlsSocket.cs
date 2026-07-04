// Windows adapter for ICastSocket. Parity source:
// AgentLens/Services/Cast/CastTLSConnection.swift (NWConnection + permissive TLS trust).

using System;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Cast.Protocol;
using OpenBurnBar.Integrations.Cast.Session;

namespace OpenBurnBar.Integrations.Cast.Windows;

/// <summary>
/// Real TLS socket to a Cast device's <c>:8009</c> channel, implementing the
/// portable <see cref="ICastSocket"/> seam with <see cref="TcpClient"/> +
/// <see cref="SslStream"/>. Framing/deframing is delegated to the portable
/// <see cref="CastFraming"/> / <see cref="CastFrameBuffer"/>.
/// </summary>
/// <remarks>
/// Cast devices present self-signed certificates; the trust evaluator accepts
/// whatever the peer presents, appropriate only because <c>_googlecast._tcp</c>
/// discovery already proved this is a LAN Cast device the user chose. This is
/// the exact narrowing the Swift <c>configurePermissiveTrust</c> applies.
/// </remarks>
public sealed class CastTlsSocket : ICastSocket
{
    private readonly string _host;
    private readonly int _port;
    private readonly CastFrameBuffer _buffer = new();
    private readonly CancellationTokenSource _lifetime = new();

    private TcpClient? _tcp;
    private SslStream? _ssl;
    private CastSocketState _state = CastSocketState.Idle;

    /// <inheritdoc />
    public event Action<CastMessage>? MessageReceived;

    /// <inheritdoc />
    public event Action<CastSocketState>? StateChanged;

    /// <summary>Create a socket for the given host + Cast port (default 8009).</summary>
    public CastTlsSocket(string host, int port = 8009)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _port = port;
    }

    /// <inheritdoc />
    public CastSocketState State => _state;

    /// <inheritdoc />
    public async Task ConnectAsync(CancellationToken cancellationToken = default)
    {
        if (_state is CastSocketState.Ready or CastSocketState.Connecting)
        {
            return;
        }

        UpdateState(CastSocketState.Connecting);
        try
        {
            var tcp = new TcpClient();
            _tcp = tcp;
            await tcp.ConnectAsync(_host, _port, cancellationToken).ConfigureAwait(false);

            var ssl = new SslStream(tcp.GetStream(), leaveInnerStreamOpen: false);
            _ssl = ssl;
            var options = new SslClientAuthenticationOptions
            {
                TargetHost = _host,
                // Accept the device's self-signed chain — discovery proved the peer.
                RemoteCertificateValidationCallback = static (_, _, _, _) => true,
            };
            await ssl.AuthenticateAsClientAsync(options, cancellationToken).ConfigureAwait(false);

            UpdateState(CastSocketState.Ready);
            _ = Task.Run(() => ReceiveLoopAsync(_lifetime.Token), _lifetime.Token);
        }
        catch (OperationCanceledException)
        {
            UpdateState(CastSocketState.Cancelled);
        }
        catch (Exception ex) when (ex is SocketException or AuthenticationException or System.IO.IOException)
        {
            UpdateState(CastSocketState.Failed);
        }
    }

    /// <inheritdoc />
    public async Task SendAsync(CastMessage message, CancellationToken cancellationToken = default)
    {
        if (_state != CastSocketState.Ready || _ssl is null)
        {
            return;
        }

        var framed = CastFraming.Encode(message);
        try
        {
            await _ssl.WriteAsync(framed, cancellationToken).ConfigureAwait(false);
            await _ssl.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is System.IO.IOException or ObjectDisposedException)
        {
            UpdateState(CastSocketState.Failed);
        }
    }

    /// <inheritdoc />
    public void Cancel()
    {
        if (!_lifetime.IsCancellationRequested)
        {
            _lifetime.Cancel();
        }

        _ssl?.Dispose();
        _ssl = null;
        _tcp?.Dispose();
        _tcp = null;
        if (_state is not CastSocketState.Failed)
        {
            UpdateState(CastSocketState.Cancelled);
        }
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        Cancel();
        _lifetime.Dispose();
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var scratch = new byte[65_536];
        var ssl = _ssl;
        if (ssl is null)
        {
            return;
        }

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var read = await ssl.ReadAsync(scratch, cancellationToken).ConfigureAwait(false);
                if (read <= 0)
                {
                    UpdateState(CastSocketState.Cancelled);
                    return;
                }

                _buffer.Append(scratch.AsSpan(0, read));
                foreach (var message in _buffer.DrainDecodable())
                {
                    MessageReceived?.Invoke(message);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal teardown.
        }
        catch (Exception ex) when (ex is System.IO.IOException or ObjectDisposedException)
        {
            UpdateState(CastSocketState.Failed);
        }
    }

    private void UpdateState(CastSocketState next)
    {
        if (_state == next)
        {
            return;
        }

        _state = next;
        StateChanged?.Invoke(next);
    }
}
