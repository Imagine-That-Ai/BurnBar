using System;
using System.Collections.Generic;
using System.Net;

namespace OpenBurnBar.CloudSync.AppCheck.Windows;

internal static class TrustedProxyAddressParser
{
    internal static IReadOnlyList<IPAddress> Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return Array.Empty<IPAddress>();
        }

        var addresses = new List<IPAddress>();
        foreach (string entry in value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (!IPAddress.TryParse(entry, out IPAddress? address))
            {
                throw new InvalidOperationException(
                    $"Trusted proxy entry '{entry}' must be an IPv4 or IPv6 address.");
            }

            addresses.Add(address);
        }

        return addresses;
    }
}
