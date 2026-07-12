using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// DNS-SD service advertisement + browse/resolve (RFC 6763).
//
// Parity: AgentLens/Services/SmartHub/LocalNetworkDiscovery.swift
//   NetService publish (advertise) + NetServiceBrowser search/resolve (browse).
//   macOS hides the wire bytes behind NetService; on Windows we build them.
//
//   * BuildAdvertisement — the response a Windows advertiser multicasts: a PTR
//     answer (service-type -> instance) plus SRV / TXT / A additionals, exactly
//     as a Bonjour publish would.
//   * BuildBrowseQuery — the PTR question a browser multicasts (the equivalent
//     of NetServiceBrowser.searchForServices(ofType:inDomain:)).
//   * ParseBrowseResponse — resolves a response into service instances
//     (host / port / addresses / TXT), the equivalent of NetService.resolve.

/// A service to advertise. The instance label must be a single DNS-SD label
/// (no embedded dots); the host name is a normal dotted name (e.g. "mac.local").
public sealed record MdnsService(
    string InstanceName,
    string ServiceType,
    string HostName,
    ushort Port,
    string Ipv4,
    IReadOnlyList<string> TxtEntries,
    string Domain = "local",
    uint Ttl = 120)
{
    public string ServiceTypeName => $"{ServiceType}.{Domain}";

    public string InstanceFqdn => $"{InstanceName}.{ServiceType}.{Domain}";
}

/// A resolved service instance from a browse response.
public sealed record MdnsServiceInstance(
    string InstanceFqdn,
    string ServiceTypeName,
    string? Host,
    ushort? Port,
    IReadOnlyList<string> Ipv4Addresses,
    IReadOnlyList<string> TxtEntries)
{
    /// The instance label (first label of the FQDN, i.e. the DNS-SD name).
    public string InstanceName
    {
        get
        {
            var dot = InstanceFqdn.IndexOf('.');
            return dot < 0 ? InstanceFqdn : InstanceFqdn.Substring(0, dot);
        }
    }
}

public static class MdnsAdvertisement
{
    /// The canonical OpenBurnBar SmartHub bridge DNS-SD service type.
    public const string SmartHubServiceType = "_openburnbar-hub._tcp";

    /// AWTRIX Light and DashCast web targets advertise over plain HTTP DNS-SD.
    public const string HttpServiceType = "_http._tcp";

    /// The standard link-local mDNS multicast endpoint.
    public const string MulticastAddress = "224.0.0.251";
    public const int MulticastPort = 5353;

    /// Builds the advertisement response message for a service.
    public static DnsMessage BuildAdvertisement(MdnsService service)
    {
        ValidateInstanceLabel(service.InstanceName);

        var message = new DnsMessage { Id = 0, Flags = DnsMessage.ResponseFlags };

        message.Answers.Add(new DnsResourceRecord(
            service.ServiceTypeName,
            (ushort)DnsRecordType.Ptr,
            DnsClass.Internet,
            service.Ttl,
            DnsRecords.BuildPtrRData(service.InstanceFqdn)));

        var uniqueClass = (ushort)(DnsClass.Internet | DnsClass.CacheFlush);

        message.Additionals.Add(new DnsResourceRecord(
            service.InstanceFqdn,
            (ushort)DnsRecordType.Srv,
            uniqueClass,
            service.Ttl,
            DnsRecords.BuildSrvRData(0, 0, service.Port, service.HostName)));

        message.Additionals.Add(new DnsResourceRecord(
            service.InstanceFqdn,
            (ushort)DnsRecordType.Txt,
            uniqueClass,
            service.Ttl,
            DnsTxt.BuildRData(service.TxtEntries)));

        message.Additionals.Add(new DnsResourceRecord(
            service.HostName,
            (ushort)DnsRecordType.A,
            uniqueClass,
            service.Ttl,
            DnsRecords.BuildARData(service.Ipv4)));

        return message;
    }

    public static byte[] BuildAdvertisementBytes(MdnsService service) => BuildAdvertisement(service).Build();

    /// Builds the PTR browse query for a service type.
    public static DnsMessage BuildBrowseQuery(string serviceType = SmartHubServiceType, string domain = "local")
    {
        var message = new DnsMessage { Id = 0, Flags = DnsMessage.QueryFlags };
        message.Questions.Add(new DnsQuestion(
            $"{serviceType}.{domain}",
            (ushort)DnsRecordType.Ptr,
            DnsClass.Internet));
        return message;
    }

    public static byte[] BuildBrowseQueryBytes(string serviceType = SmartHubServiceType, string domain = "local") =>
        BuildBrowseQuery(serviceType, domain).Build();

    /// Resolves a browse response into service instances, joining each PTR answer
    /// with its SRV / TXT / A records (from any section).
    public static IReadOnlyList<MdnsServiceInstance> ParseBrowseResponse(byte[] responseBytes)
    {
        var message = DnsMessage.Parse(responseBytes);
        var all = message.Answers
            .Concat(message.Authorities)
            .Concat(message.Additionals)
            .ToList();

        // Map host name -> its A addresses.
        var addressesByHost = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in all.Where(r => r.ATarget is not null))
        {
            if (!addressesByHost.TryGetValue(record.Name, out var list))
            {
                list = new List<string>();
                addressesByHost[record.Name] = list;
            }
            list.Add(record.ATarget!);
        }

        var srvByInstance = all
            .Where(r => r.Srv is not null)
            .GroupBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First().Srv!, StringComparer.OrdinalIgnoreCase);

        var txtByInstance = all
            .Where(r => r.TxtEntries is not null)
            .GroupBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First().TxtEntries!, StringComparer.OrdinalIgnoreCase);

        // Instance FQDNs come from PTR answers (falling back to any SRV names).
        var instanceFqdns = new List<string>();
        foreach (var ptr in all.Where(r => r.PtrTarget is not null))
        {
            if (!instanceFqdns.Contains(ptr.PtrTarget!, StringComparer.Ordinal))
            {
                instanceFqdns.Add(ptr.PtrTarget!);
            }
        }
        foreach (var srvName in srvByInstance.Keys)
        {
            if (!instanceFqdns.Contains(srvName, StringComparer.Ordinal))
            {
                instanceFqdns.Add(srvName);
            }
        }

        var instances = new List<MdnsServiceInstance>();
        foreach (var fqdn in instanceFqdns)
        {
            srvByInstance.TryGetValue(fqdn, out var srv);
            txtByInstance.TryGetValue(fqdn, out var txt);
            var host = srv?.Target;
            var addresses = host is not null && addressesByHost.TryGetValue(host, out var addr)
                ? Ipv4Subnet.Unique(addr)
                : (IReadOnlyList<string>)Array.Empty<string>();

            instances.Add(new MdnsServiceInstance(
                fqdn,
                ServiceTypeOf(fqdn),
                host,
                srv?.Port,
                addresses,
                txt ?? Array.Empty<string>()));
        }

        return instances;
    }

    /// Parity: Swift `bonjourDiscoverAwtrixHosts` filtering — instance names with
    /// an "awtrix" prefix, resolved to usable LAN IPv4 hosts (de-duplicated).
    public static IReadOnlyList<string> ExtractAwtrixHosts(byte[] responseBytes)
    {
        var hosts = new List<string>();
        foreach (var instance in ParseBrowseResponse(responseBytes))
        {
            if (!instance.InstanceName.ToLowerInvariant().StartsWith("awtrix", StringComparison.Ordinal))
            {
                continue;
            }
            foreach (var ip in instance.Ipv4Addresses)
            {
                if (Ipv4Subnet.IsUsableLanIpv4(ip))
                {
                    hosts.Add(ip);
                }
            }
        }
        return Ipv4Subnet.Unique(hosts);
    }

    private static string ServiceTypeOf(string instanceFqdn)
    {
        // Drop the first (instance) label; the remainder is the service type FQDN.
        var dot = instanceFqdn.IndexOf('.');
        return dot < 0 ? instanceFqdn : instanceFqdn.Substring(dot + 1);
    }

    private static void ValidateInstanceLabel(string instanceName)
    {
        if (instanceName.Length == 0)
        {
            throw new ArgumentException("DNS-SD instance name must not be empty.", nameof(instanceName));
        }
        if (instanceName.Contains('.', StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "DNS-SD instance name is a single label and must not contain '.'; got: " + instanceName,
                nameof(instanceName));
        }
    }
}
