// Parity source: AgentLens/Services/Cast/CastChannelClient.swift
// (namespace/app-id constants, serializedPayload, dashCastLoadPayload, and the
//  outbound message builders CONNECT/GET_STATUS/LAUNCH/STOP/PING/PONG)

using System;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.Integrations.Cast.Protocol;

/// <summary>
/// Static Cast V2 receiver-protocol vocabulary + payload builders. This holds
/// the parts of <c>CastChannelClient</c> that are pure (namespaces, app ids,
/// JSON payload shapes) so they can be unit-tested off-Windows and reused by the
/// live session driver.
/// </summary>
public static class CastReceiverProtocol
{
    /// <summary>
    /// Public app id for DashCast — a community Cast receiver app that renders
    /// any URL (verified against pychromecast's <c>DashCastController</c>).
    /// </summary>
    public const string DashCastAppId = "84912283";

    /// <summary>User-agent string sent in every virtual CONNECT.</summary>
    public const string UserAgent = "OpenBurnBar/1.0";

    /// <summary>tp.connection namespace — opens a virtual channel.</summary>
    public const string NamespaceConnection = "urn:x-cast:com.google.cast.tp.connection";

    /// <summary>tp.heartbeat namespace — PING/PONG keepalive.</summary>
    public const string NamespaceHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";

    /// <summary>receiver namespace — GET_STATUS/LAUNCH/STOP.</summary>
    public const string NamespaceReceiver = "urn:x-cast:com.google.cast.receiver";

    /// <summary>DashCast application namespace — LOAD a URL.</summary>
    public const string NamespaceDashCast = "urn:x-cast:com.madmod.dashcast";

    /// <summary>Build a virtual-channel CONNECT frame to the given destination.</summary>
    public static CastMessage Connect(string destination)
        => CastMessage.String(
            NamespaceConnection,
            SerializeOrThrow(new JsonObject
            {
                ["type"] = "CONNECT",
                ["userAgent"] = UserAgent,
            }),
            destination);

    /// <summary>Build a receiver GET_STATUS request carrying <paramref name="requestId"/>.</summary>
    public static CastMessage GetStatus(int requestId)
        => CastMessage.String(
            NamespaceReceiver,
            SerializeOrThrow(new JsonObject
            {
                ["type"] = "GET_STATUS",
                ["requestId"] = requestId,
            }),
            CastMessage.DefaultDestination);

    /// <summary>Build a receiver LAUNCH request for DashCast.</summary>
    public static CastMessage LaunchDashCast(int requestId)
        => CastMessage.String(
            NamespaceReceiver,
            SerializeOrThrow(new JsonObject
            {
                ["type"] = "LAUNCH",
                ["appId"] = DashCastAppId,
                ["requestId"] = requestId,
            }),
            CastMessage.DefaultDestination);

    /// <summary>Build a receiver STOP request for the given session.</summary>
    public static CastMessage Stop(string sessionId, int requestId)
        => CastMessage.String(
            NamespaceReceiver,
            SerializeOrThrow(new JsonObject
            {
                ["type"] = "STOP",
                ["sessionId"] = sessionId,
                ["requestId"] = requestId,
            }),
            CastMessage.DefaultDestination);

    /// <summary>Build a heartbeat PING to the receiver.</summary>
    public static CastMessage Ping()
        => CastMessage.String(
            NamespaceHeartbeat,
            SerializeOrThrow(new JsonObject { ["type"] = "PING" }),
            CastMessage.DefaultDestination);

    /// <summary>Build a heartbeat PONG reply to the receiver.</summary>
    public static CastMessage Pong()
        => CastMessage.String(
            NamespaceHeartbeat,
            SerializeOrThrow(new JsonObject { ["type"] = "PONG" }),
            CastMessage.DefaultDestination);

    /// <summary>
    /// Build the DashCast LOAD payload as an ordered JSON object. Faithful port
    /// of Swift <c>dashCastLoadPayload</c>:
    /// <c>force</c> selects the direct (reload-incapable) load mode, so
    /// <c>reload</c>/<c>reload_time</c> are suppressed whenever <c>force</c> is set.
    /// </summary>
    public static JsonObject DashCastLoadPayload(
        string url,
        string? sessionId,
        double reloadSeconds,
        bool force = false)
    {
        var shouldReload = !force && reloadSeconds > 0;
        var payload = new JsonObject
        {
            ["url"] = url,
            ["force"] = force,
            ["reload"] = shouldReload,
            ["reload_time"] = shouldReload ? reloadSeconds * 1_000 : 0,
        };
        if (!string.IsNullOrEmpty(sessionId))
        {
            payload["sessionId"] = sessionId;
        }

        return payload;
    }

    /// <summary>
    /// Build a DashCast LOAD <see cref="CastMessage"/> to the given transport id.
    /// </summary>
    public static CastMessage DashCastLoad(
        string transportId,
        string url,
        string? sessionId,
        double reloadSeconds,
        bool force = false)
        => CastMessage.String(
            NamespaceDashCast,
            SerializeOrThrow(DashCastLoadPayload(url, sessionId, reloadSeconds, force)),
            transportId);

    /// <summary>
    /// Serialize a Cast payload to a compact UTF-8 JSON string, or return
    /// <see langword="null"/> when it cannot be represented as JSON — mirroring
    /// Swift <c>serializedPayload</c> failing closed (a dropped control message
    /// is observable rather than a mystery downstream timeout). Non-finite
    /// numbers (NaN/Infinity) are rejected, matching the Foundation behavior.
    /// </summary>
    public static string? TrySerialize(JsonNode? payload)
    {
        if (payload is null)
        {
            return null;
        }

        if (ContainsNonFiniteNumber(payload))
        {
            return null;
        }

        try
        {
            return payload.ToJsonString(CompactOptions);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static readonly JsonSerializerOptions CompactOptions = new()
    {
        WriteIndented = false,
    };

    private static string SerializeOrThrow(JsonNode payload)
    {
        var json = TrySerialize(payload);
        if (json is null)
        {
            throw new InvalidOperationException("Cast payload is not JSON-serializable.");
        }

        return json;
    }

    private static bool ContainsNonFiniteNumber(JsonNode node)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var kvp in obj)
                {
                    if (kvp.Value is not null && ContainsNonFiniteNumber(kvp.Value))
                    {
                        return true;
                    }
                }

                return false;
            case JsonArray arr:
                foreach (var item in arr)
                {
                    if (item is not null && ContainsNonFiniteNumber(item))
                    {
                        return true;
                    }
                }

                return false;
            case JsonValue value:
                if (value.TryGetValue(out double d))
                {
                    return double.IsNaN(d) || double.IsInfinity(d);
                }

                return false;
            default:
                return false;
        }
    }

    internal static string FormatDouble(double value)
        => value.ToString("R", CultureInfo.InvariantCulture);
}
