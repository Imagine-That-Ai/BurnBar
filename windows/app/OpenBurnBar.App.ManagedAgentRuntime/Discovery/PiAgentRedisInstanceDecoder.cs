using System;
using System.Collections.Generic;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Discovery;

/// <summary>
/// Decodes the Pi gateway's <c>/admin/instances</c> JSON body into
/// <see cref="ManagedAgentInstance"/> values.
///
/// Faithful port of the Swift <c>decodeInstances(from:)</c> helper
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRedisDiscovery.swift, lines
/// 92-144). Every key alias, fallback order, and default is preserved
/// value-for-value:
///   * accepts both a bare array <c>[{...}]</c> and a wrapped
///     <c>{ "instances": [...] }</c> object;
///   * <c>id</c> = id / instance_id / instanceId / name (first present string
///     wins; an empty id drops the entry);
///   * <c>displayName</c> = display_name / displayName / name / id;
///   * <c>isOnline</c> = online(bool) / is_online(bool) /
///     status=="online"||"running" / true;
///   * <c>activeSessionId</c> = active_session_id / activeSessionId / session_id;
///   * <c>gatewayBaseURL</c> = gateway_base_url / gatewayBaseURL / base_url
///     (the first PRESENT string key is parsed, even if it fails to parse — the
///     others are not consulted, mirroring the Swift closure's early return).
///
/// Malformed JSON yields an empty list rather than throwing, matching the Swift
/// <c>try?</c> that silently skips an unparsable body.
/// </summary>
public static class PiAgentRedisInstanceDecoder
{
    /// <summary>Decodes a UTF-8 JSON body. Never throws; returns empty on malformed input.</summary>
    public static IReadOnlyList<ManagedAgentInstance> Decode(byte[] data)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data);
        }
        catch (JsonException)
        {
            // try?-parity: an unparsable body is skipped, not surfaced.
            return Array.Empty<ManagedAgentInstance>();
        }

        using (document)
        {
            var root = document.RootElement;

            // Support both `[{...}]` and `{ "instances": [...] }` shapes.
            JsonElement array;
            if (root.ValueKind == JsonValueKind.Array)
            {
                array = root;
            }
            else if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("instances", out var wrapped)
                && wrapped.ValueKind == JsonValueKind.Array)
            {
                array = wrapped;
            }
            else
            {
                return Array.Empty<ManagedAgentInstance>();
            }

            var result = new List<ManagedAgentInstance>();
            foreach (var entry in array.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object)
                {
                    // Swift casts each element to [String: Any]; non-objects are skipped.
                    continue;
                }

                var instance = DecodeEntry(entry);
                if (instance is not null)
                {
                    result.Add(instance);
                }
            }

            return result;
        }
    }

    private static ManagedAgentInstance? DecodeEntry(JsonElement entry)
    {
        var id = FirstString(entry, "id", "instance_id", "instanceId", "name");
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }

        var displayName = FirstString(entry, "display_name", "displayName", "name") ?? id;
        var isOnline = ResolveIsOnline(entry);
        var activeSessionId = FirstString(entry, "active_session_id", "activeSessionId", "session_id");
        var gatewayBaseUrl = ResolveGatewayBaseUrl(entry);

        return new ManagedAgentInstance(
            id: id,
            displayName: displayName,
            isOnline: isOnline,
            activeSessionId: activeSessionId,
            gatewayBaseUrl: gatewayBaseUrl);
    }

    private static bool ResolveIsOnline(JsonElement entry)
    {
        // online(bool) ?? is_online(bool) ?? status=="online"||"running" ?? true
        var online = OptionalBool(entry, "online") ?? OptionalBool(entry, "is_online");
        if (online is bool flag)
        {
            return flag;
        }

        var status = OptionalString(entry, "status");
        if (status is not null)
        {
            var lowered = status.ToLowerInvariant();
            return lowered == "online" || lowered == "running";
        }

        return true;
    }

    private static Uri? ResolveGatewayBaseUrl(JsonElement entry)
    {
        // The Swift closure returns as soon as the FIRST of these keys is a
        // string, parsing it (which may be null) without consulting the rest.
        foreach (var key in new[] { "gateway_base_url", "gatewayBaseURL", "base_url" })
        {
            if (entry.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
            {
                return ParseUrl(value.GetString());
            }
        }

        return null;
    }

    /// <summary>Returns the first key present as a JSON string (empty allowed), else null.</summary>
    private static string? FirstString(JsonElement entry, params string[] keys)
    {
        foreach (var key in keys)
        {
            var value = OptionalString(entry, key);
            if (value is not null)
            {
                return value;
            }
        }

        return null;
    }

    private static string? OptionalString(JsonElement entry, string key)
    {
        if (entry.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
        {
            return value.GetString();
        }

        return null;
    }

    private static bool? OptionalBool(JsonElement entry, string key)
    {
        if (entry.TryGetProperty(key, out var value))
        {
            if (value.ValueKind == JsonValueKind.True)
            {
                return true;
            }

            if (value.ValueKind == JsonValueKind.False)
            {
                return false;
            }
        }

        return null;
    }

    private static Uri? ParseUrl(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        return Uri.TryCreate(raw, UriKind.RelativeOrAbsolute, out var uri) ? uri : null;
    }
}
