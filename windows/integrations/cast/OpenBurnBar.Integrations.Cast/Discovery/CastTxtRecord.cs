// Parity source: AgentLens/Services/Cast/CastDiscovery.swift (TXT extraction: fn/md/id/ca)

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>
/// The Cast-relevant fields pulled from a <c>_googlecast._tcp</c> DNS-SD TXT
/// record. Faithful to the Swift discovery layer, which reads <c>fn</c>
/// (friendly name), <c>md</c> (model), <c>id</c> (device UUID), and <c>ca</c>
/// (capability bitmask).
/// </summary>
public sealed record CastTxtRecord
{
    /// <summary>Friendly name (<c>fn</c>), or the service name when absent.</summary>
    public required string FriendlyName { get; init; }

    /// <summary>Model string (<c>md</c>), or <c>Cast Device</c> when absent.</summary>
    public required string Model { get; init; }

    /// <summary>Device UUID (<c>id</c>), or the service name when absent.</summary>
    public required string Identifier { get; init; }

    /// <summary>Capability bitmask (<c>ca</c>), or 0 when absent/unparseable.</summary>
    public required int CapabilityFlags { get; init; }

    /// <summary>Default model string when the <c>md</c> field is missing.</summary>
    public const string DefaultModel = "Cast Device";

    /// <summary>
    /// Parse a set of TXT <c>key=value</c> entries (as delivered by DNS-SD) into
    /// the Cast fields, falling back to <paramref name="serviceName"/> for the
    /// name/identifier just like the Swift discovery layer.
    /// </summary>
    public static CastTxtRecord Parse(IEnumerable<string> keyValueEntries, string serviceName)
    {
        if (keyValueEntries is null)
        {
            throw new ArgumentNullException(nameof(keyValueEntries));
        }

        if (serviceName is null)
        {
            throw new ArgumentNullException(nameof(serviceName));
        }

        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in keyValueEntries)
        {
            if (entry is null)
            {
                continue;
            }

            var separator = entry.IndexOf('=');
            if (separator < 0)
            {
                // A key with no '=' is a valueless boolean attribute; ignore.
                continue;
            }

            var key = entry.Substring(0, separator);
            var value = entry.Substring(separator + 1);
            // DNS-SD keys are case-insensitive; the last wins (RFC 6763 §6.4).
            map[key.ToLowerInvariant()] = value;
        }

        return FromMap(map, serviceName);
    }

    /// <summary>Build from an already-split key/value map (keys lowercased).</summary>
    public static CastTxtRecord FromMap(IReadOnlyDictionary<string, string> map, string serviceName)
    {
        if (map is null)
        {
            throw new ArgumentNullException(nameof(map));
        }

        var friendly = NonEmpty(map, "fn") ?? serviceName;
        var model = NonEmpty(map, "md") ?? DefaultModel;
        var identifier = NonEmpty(map, "id") ?? serviceName;
        var capabilityFlags = 0;
        if (NonEmpty(map, "ca") is { } ca && int.TryParse(ca, out var parsed))
        {
            capabilityFlags = parsed;
        }

        return new CastTxtRecord
        {
            FriendlyName = friendly,
            Model = model,
            Identifier = identifier,
            CapabilityFlags = capabilityFlags,
        };
    }

    private static string? NonEmpty(IReadOnlyDictionary<string, string> map, string key)
        => map.TryGetValue(key, out var value) && !string.IsNullOrEmpty(value) ? value : null;
}
