// Parity source: AgentLens/Services/Cast/CastDiscovery.swift (resolve + record → CastDevice)
// The macOS browser gets fn/md/id/ca + host:port from the OS; this reconstructs
// the same CastDevice from the raw DNS-SD records so discovery is provable off-Windows.

using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Integrations.Cast.Model;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>
/// Reconstructs <see cref="CastDevice"/> records from a captured
/// <c>_googlecast._tcp</c> mDNS advertisement (PTR + SRV + TXT + A records),
/// correlating them by instance name exactly as a DNS-SD resolver would.
/// </summary>
public static class CastMdnsAdvertisement
{
    /// <summary>The DNS-SD service type Cast devices advertise.</summary>
    public const string ServiceType = "_googlecast._tcp.local";

    private const string InstanceSuffix = "._googlecast._tcp.local";

    /// <summary>The default Cast TLS port when an SRV record is absent.</summary>
    public const int DefaultPort = 8009;

    /// <summary>Parse raw advertisement bytes into Cast devices.</summary>
    public static IReadOnlyList<CastDevice> Parse(byte[] packet, DateTimeOffset? seenAt = null)
        => Parse(DnsMessage.Parse(packet), seenAt);

    /// <summary>Reconstruct Cast devices from an already-parsed DNS message.</summary>
    public static IReadOnlyList<CastDevice> Parse(DnsMessage message, DateTimeOffset? seenAt = null)
    {
        if (message is null)
        {
            throw new ArgumentNullException(nameof(message));
        }

        var records = message.AllRecords().ToList();
        var timestamp = seenAt ?? DateTimeOffset.UtcNow;

        // Index SRV/TXT by instance name, and A records by host name.
        var srvByInstance = new Dictionary<string, DnsResourceRecord>(StringComparer.OrdinalIgnoreCase);
        var txtByInstance = new Dictionary<string, DnsResourceRecord>(StringComparer.OrdinalIgnoreCase);
        var aByHost = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var instanceNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var record in records)
        {
            switch (record.Type)
            {
                case DnsRecordType.Ptr:
                    if (IsCastServiceName(record.Name) && !string.IsNullOrEmpty(record.PtrTarget)
                        && IsCastInstance(record.PtrTarget!))
                    {
                        instanceNames.Add(record.PtrTarget!);
                    }

                    break;
                case DnsRecordType.Srv:
                    if (IsCastInstance(record.Name))
                    {
                        srvByInstance[record.Name] = record;
                        instanceNames.Add(record.Name);
                    }

                    break;
                case DnsRecordType.Txt:
                    if (IsCastInstance(record.Name))
                    {
                        txtByInstance[record.Name] = record;
                        instanceNames.Add(record.Name);
                    }

                    break;
                case DnsRecordType.A:
                    if (record.AAddress is { } address)
                    {
                        aByHost[record.Name] = address;
                    }

                    break;
                default:
                    break;
            }
        }

        var devices = new List<CastDevice>();
        foreach (var instance in instanceNames)
        {
            var serviceName = InstanceLabel(instance);

            var txtStrings = txtByInstance.TryGetValue(instance, out var txt) && txt.TxtStrings is not null
                ? txt.TxtStrings
                : Array.Empty<string>();
            var parsedTxt = CastTxtRecord.Parse(txtStrings, serviceName);

            var host = string.Empty;
            var port = DefaultPort;
            if (srvByInstance.TryGetValue(instance, out var srv))
            {
                port = srv.SrvPort ?? DefaultPort;
                if (srv.SrvTarget is { } target && aByHost.TryGetValue(target, out var resolved))
                {
                    host = resolved;
                }
                else if (srv.SrvTarget is { } hostname)
                {
                    host = hostname;
                }
            }

            devices.Add(new CastDevice
            {
                ServiceName = serviceName,
                FriendlyName = parsedTxt.FriendlyName,
                Host = host,
                Port = port,
                Model = parsedTxt.Model,
                Identifier = parsedTxt.Identifier,
                LastSeenAt = timestamp,
                SupportsDisplay = CastCapabilities.InferSupportsDisplay(
                    parsedTxt.CapabilityFlags,
                    parsedTxt.Model,
                    serviceName),
            });
        }

        return CastDiscoveryMerge.Merge(devices);
    }

    private static bool IsCastServiceName(string name)
        => string.Equals(name.TrimEnd('.'), ServiceType, StringComparison.OrdinalIgnoreCase);

    private static bool IsCastInstance(string name)
        => name.TrimEnd('.').EndsWith(InstanceSuffix, StringComparison.OrdinalIgnoreCase);

    /// <summary>Extract the Bonjour instance label (the part before the service suffix).</summary>
    public static string InstanceLabel(string instanceName)
    {
        if (instanceName is null)
        {
            throw new ArgumentNullException(nameof(instanceName));
        }

        var trimmed = instanceName.TrimEnd('.');
        if (trimmed.EndsWith(InstanceSuffix, StringComparison.OrdinalIgnoreCase))
        {
            return trimmed.Substring(0, trimmed.Length - InstanceSuffix.Length);
        }

        return trimmed;
    }
}
