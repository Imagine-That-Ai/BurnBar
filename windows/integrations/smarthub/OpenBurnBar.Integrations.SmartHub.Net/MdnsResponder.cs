using System;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.SmartHub.Discovery;

namespace OpenBurnBar.Integrations.SmartHub.Net;

// Live mDNS multicast advertiser.
//
// Parity: the NetService publish half of LocalNetworkDiscovery. It multicasts
// the pure MdnsAdvertisement bytes on 224.0.0.251:5353 (an initial unsolicited
// announcement, then again whenever a matching PTR browse query arrives). All
// record construction + query classification lives in the tested portable core;
// this adapter only owns the UDP socket.

public sealed class MdnsResponder : IMdnsResponder, IDisposable
{
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private MdnsService? _service;
    private byte[]? _advertisement;

    public async Task StartAsync(MdnsService service, CancellationToken cancellationToken = default)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        // Build once; the bytes are immutable for the lifetime of the service.
        _advertisement = MdnsAdvertisement.BuildAdvertisementBytes(service);

        var udp = new UdpClient(AddressFamily.InterNetwork);
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, MdnsAdvertisement.MulticastPort));
        var group = IPAddress.Parse(MdnsAdvertisement.MulticastAddress);
        udp.JoinMulticastGroup(group);
        _udp = udp;

        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        // Initial unsolicited announcement.
        await SendAdvertisementAsync().ConfigureAwait(false);

        _loop = Task.Run(() => ListenLoopAsync(_cts.Token));
    }

    public async Task StopAsync()
    {
        _cts?.Cancel();
        try
        {
            _udp?.Close();
        }
        catch (ObjectDisposedException)
        {
            // Already closed.
        }
        if (_loop is not null)
        {
            try
            {
                await _loop.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected on shutdown.
            }
        }
        _udp = null;
    }

    private async Task ListenLoopAsync(CancellationToken cancellationToken)
    {
        var udp = _udp;
        var service = _service;
        if (udp is null || service is null)
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            UdpReceiveResult received;
            try
            {
                received = await udp.ReceiveAsync(cancellationToken).ConfigureAwait(false);
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

            if (QueryMatchesService(received.Buffer, service))
            {
                await SendAdvertisementAsync().ConfigureAwait(false);
            }
        }
    }

    /// True when the datagram is a query carrying a PTR question for our service
    /// type. Uses the pure DnsMessage parser; malformed datagrams are ignored.
    private static bool QueryMatchesService(byte[] datagram, MdnsService service)
    {
        try
        {
            var message = DnsMessage.Parse(datagram);
            return message.Questions.Any(q =>
                q.Type == (ushort)DnsRecordType.Ptr &&
                string.Equals(q.Name, service.ServiceTypeName, StringComparison.OrdinalIgnoreCase));
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private async Task SendAdvertisementAsync()
    {
        var udp = _udp;
        var advertisement = _advertisement;
        if (udp is null || advertisement is null)
        {
            return;
        }
        var endpoint = new IPEndPoint(IPAddress.Parse(MdnsAdvertisement.MulticastAddress), MdnsAdvertisement.MulticastPort);
        try
        {
            await udp.SendAsync(advertisement, advertisement.Length, endpoint).ConfigureAwait(false);
        }
        catch (SocketException)
        {
            // Transient send failure (interface flap); the next query re-triggers.
        }
        catch (ObjectDisposedException)
        {
            // Shutting down.
        }
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _udp?.Dispose();
        _cts?.Dispose();
    }
}
