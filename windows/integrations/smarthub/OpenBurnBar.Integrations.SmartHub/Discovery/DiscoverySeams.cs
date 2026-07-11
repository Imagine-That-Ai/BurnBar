using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// The "live" platform seams the Net adapter implements.
//
// Parity: the socket-owning halves of SmartHubBridgeServer (NWListener) and
// LocalNetworkDiscovery (getifaddrs / NetService). The app depends on these
// abstractions; the net-generic adapter binds real HttpListener / UdpClient /
// NetworkInterface implementations behind them.

/// The live HTTP listener that fronts the pure BridgeRouter.
public interface IBridgeSocketHost
{
    bool IsRunning { get; }
    int? BoundPort { get; }
    Task StartAsync(int port = 8787, CancellationToken cancellationToken = default);
    Task StopAsync();
}

/// The live mDNS advertiser that multicasts a service's advertisement bytes and
/// answers matching browse queries.
public interface IMdnsResponder
{
    Task StartAsync(MdnsService service, CancellationToken cancellationToken = default);
    Task StopAsync();
}

/// Enumerates the host's usable LAN IPv4 interfaces + preferred address + name
/// for the pure subnet-candidate and dashboard-URL math.
public interface ILanInterfaceEnumerator
{
    IReadOnlyList<Ipv4InterfaceInput> Enumerate();
    string? PreferredLanAddress();
    string? LocalHostName();
}
