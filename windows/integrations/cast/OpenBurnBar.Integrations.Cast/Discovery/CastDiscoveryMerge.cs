// Parity source: AgentLens/Services/Cast/CastDiscovery.swift (merge / discoveryScore / publish sort)

using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Integrations.Cast.Model;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>
/// Deduplicates and orders discovered <see cref="CastDevice"/>s. The two
/// discovery paths (NWBrowser + NetService on macOS; Dnssd + any fallback on
/// Windows) can surface the same device with different completeness, so we keep
/// the highest-scoring record per service name and sort display-capable devices
/// first. Faithful port of the Swift discovery merge/score/sort.
/// </summary>
public static class CastDiscoveryMerge
{
    /// <summary>
    /// Merge duplicate records keyed by lowercased service name, keeping the
    /// higher-<see cref="Score"/> record (ties keep the later one, matching the
    /// Swift <c>&gt;=</c>), then sort.
    /// </summary>
    public static IReadOnlyList<CastDevice> Merge(IEnumerable<CastDevice> devices)
    {
        if (devices is null)
        {
            throw new ArgumentNullException(nameof(devices));
        }

        var merged = new Dictionary<string, CastDevice>(StringComparer.Ordinal);
        foreach (var device in devices)
        {
            var key = device.ServiceName.ToLowerInvariant();
            if (!merged.TryGetValue(key, out var existing))
            {
                merged[key] = device;
                continue;
            }

            if (Score(device) >= Score(existing))
            {
                merged[key] = device;
            }
        }

        return Sort(merged.Values);
    }

    /// <summary>
    /// Completeness score for a discovered device: a resolved host is worth the
    /// most, then a distinct friendly name, then a real model, then a real id.
    /// </summary>
    public static int Score(CastDevice device)
    {
        if (device is null)
        {
            throw new ArgumentNullException(nameof(device));
        }

        var score = 0;
        if (!string.IsNullOrEmpty(device.Host.Trim()))
        {
            score += 4;
        }

        if (device.FriendlyName != device.ServiceName)
        {
            score += 2;
        }

        if (device.Model != CastTxtRecord.DefaultModel)
        {
            score += 1;
        }

        if (device.Identifier != device.ServiceName)
        {
            score += 1;
        }

        return score;
    }

    /// <summary>
    /// Sort: display-capable devices first, then audio-only, each bucket sorted
    /// case-insensitively by friendly name. Port of the Swift <c>publish</c> sort.
    /// </summary>
    public static IReadOnlyList<CastDevice> Sort(IEnumerable<CastDevice> devices)
    {
        if (devices is null)
        {
            throw new ArgumentNullException(nameof(devices));
        }

        return devices
            .OrderByDescending(d => d.SupportsDisplay)
            .ThenBy(d => d.FriendlyName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}
