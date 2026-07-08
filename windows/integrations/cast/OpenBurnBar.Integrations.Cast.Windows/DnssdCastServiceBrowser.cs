// Windows adapter for ICastServiceBrowser. Parity source:
// AgentLens/Services/Cast/CastDiscovery.swift (NWBrowser _googlecast._tcp browse).
//
// Uses the WinRT Dnssd device watcher (Windows.Devices.Enumeration over the
// System.Devices.Dnssd.* AQS) to enumerate _googlecast._tcp services live, then
// maps each resolved DeviceInformation to a portable CastDevice and republishes
// the deduplicated set via the portable CastDiscoveryMerge.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using OpenBurnBar.Integrations.Cast.Discovery;
using OpenBurnBar.Integrations.Cast.Model;
using Windows.Devices.Enumeration;

namespace OpenBurnBar.Integrations.Cast.Windows;

/// <summary>
/// Live <c>_googlecast._tcp</c> browser backed by the Windows Dnssd device
/// watcher. Publishes the full deduplicated device set on every change, matching
/// the portable <see cref="ICastServiceBrowser"/> contract.
/// </summary>
public sealed class DnssdCastServiceBrowser : ICastServiceBrowser
{
    private const string HostNameProperty = "System.Devices.Dnssd.HostName";
    private const string InstanceNameProperty = "System.Devices.Dnssd.InstanceName";
    private const string PortNumberProperty = "System.Devices.Dnssd.PortNumber";
    private const string TextAttributesProperty = "System.Devices.Dnssd.TextAttributes";
    private const string IpAddressProperty = "System.Devices.IPAddress";

    private static readonly string[] RequestedProperties =
    {
        HostNameProperty,
        InstanceNameProperty,
        PortNumberProperty,
        TextAttributesProperty,
        IpAddressProperty,
    };

    private readonly object _gate = new();
    private readonly Dictionary<string, DeviceInformation> _found = new(StringComparer.Ordinal);
    private DeviceWatcher? _watcher;

    /// <inheritdoc />
    public event Action<IReadOnlyList<CastDevice>>? DevicesChanged;

    /// <inheritdoc />
    public void Start()
    {
        Stop();

        // AQS selector for the Cast DNS-SD service, resolved as association
        // endpoint services so host / port / TXT come back on each DeviceInformation.
        const string selector =
            "System.Devices.Dnssd.ServiceName:=\"_googlecast._tcp.local.\" AND " +
            "System.Devices.Dnssd.Domain:=\"local\"";

        var watcher = DeviceInformation.CreateWatcher(
            selector,
            RequestedProperties,
            DeviceInformationKind.AssociationEndpointService);

        watcher.Added += OnAdded;
        watcher.Updated += OnUpdated;
        watcher.Removed += OnRemoved;
        _watcher = watcher;
        watcher.Start();
    }

    /// <inheritdoc />
    public void Stop()
    {
        var watcher = _watcher;
        _watcher = null;
        if (watcher is not null)
        {
            watcher.Added -= OnAdded;
            watcher.Updated -= OnUpdated;
            watcher.Removed -= OnRemoved;
            if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
            {
                watcher.Stop();
            }
        }

        lock (_gate)
        {
            _found.Clear();
        }
    }

    /// <inheritdoc />
    public void Dispose() => Stop();

    private void OnAdded(DeviceWatcher sender, DeviceInformation info)
    {
        lock (_gate)
        {
            _found[info.Id] = info;
        }

        Publish();
    }

    private void OnUpdated(DeviceWatcher sender, DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            if (_found.TryGetValue(update.Id, out var existing))
            {
                existing.Update(update);
            }
        }

        Publish();
    }

    private void OnRemoved(DeviceWatcher sender, DeviceInformationUpdate update)
    {
        lock (_gate)
        {
            _found.Remove(update.Id);
        }

        Publish();
    }

    private void Publish()
    {
        List<DeviceInformation> snapshot;
        lock (_gate)
        {
            snapshot = _found.Values.ToList();
        }

        var devices = snapshot.Select(MapDevice).ToList();
        DevicesChanged?.Invoke(CastDiscoveryMerge.Merge(devices));
    }

    private static CastDevice MapDevice(DeviceInformation info)
    {
        var serviceName = ReadString(info, InstanceNameProperty) ?? info.Name;
        var txt = ReadStringArray(info, TextAttributesProperty);
        var parsed = CastTxtRecord.Parse(txt, serviceName);

        var host = ReadStringArray(info, IpAddressProperty).FirstOrDefault()
                   ?? ReadString(info, HostNameProperty)
                   ?? string.Empty;
        var port = ReadInt(info, PortNumberProperty) ?? CastMdnsAdvertisement.DefaultPort;

        return new CastDevice
        {
            ServiceName = serviceName,
            FriendlyName = parsed.FriendlyName,
            Host = host,
            Port = port,
            Model = parsed.Model,
            Identifier = parsed.Identifier,
            LastSeenAt = DateTimeOffset.UtcNow,
            SupportsDisplay = CastCapabilities.InferSupportsDisplay(
                parsed.CapabilityFlags,
                parsed.Model,
                serviceName),
        };
    }

    private static string? ReadString(DeviceInformation info, string key)
        => info.Properties.TryGetValue(key, out var value) && value is string s && s.Length > 0 ? s : null;

    private static int? ReadInt(DeviceInformation info, string key)
    {
        if (info.Properties.TryGetValue(key, out var value) && value is not null)
        {
            try
            {
                return Convert.ToInt32(value, CultureInfo.InvariantCulture);
            }
            catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
            {
                return null;
            }
        }

        return null;
    }

    private static IReadOnlyList<string> ReadStringArray(DeviceInformation info, string key)
    {
        if (info.Properties.TryGetValue(key, out var value))
        {
            switch (value)
            {
                case string[] array:
                    return array;
                case IEnumerable<string> enumerable:
                    return enumerable.ToList();
                case string single:
                    return new[] { single };
            }
        }

        return Array.Empty<string>();
    }
}
