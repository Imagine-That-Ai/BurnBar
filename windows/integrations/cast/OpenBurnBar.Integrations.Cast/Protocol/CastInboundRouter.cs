// Parity source: AgentLens/Services/Cast/CastChannelClient.swift (handle(message:))

using System.Text.Json;

namespace OpenBurnBar.Integrations.Cast.Protocol;

/// <summary>Kinds of inbound Cast control-channel event we act on.</summary>
public enum CastInboundKind
{
    /// <summary>A RECEIVER_STATUS carrying a running application (session/transport/app).</summary>
    ReceiverStatusActive,

    /// <summary>A RECEIVER_STATUS with no applications (idle / Backdrop).</summary>
    ReceiverStatusIdle,

    /// <summary>A LAUNCH_ERROR.</summary>
    LaunchError,

    /// <summary>A heartbeat PING (we must auto-reply PONG).</summary>
    Ping,

    /// <summary>A heartbeat PONG.</summary>
    Pong,

    /// <summary>Anything else (acknowledged but carries no state change).</summary>
    Other,
}

/// <summary>
/// The parsed meaning of one inbound <see cref="CastMessage"/>.
/// </summary>
public sealed record CastInboundEvent
{
    /// <summary>The event classification.</summary>
    public required CastInboundKind Kind { get; init; }

    /// <summary>Request id echoed back for round-trip correlation, if present.</summary>
    public int? RequestId { get; init; }

    /// <summary>Receiver session id (for <see cref="CastInboundKind.ReceiverStatusActive"/>).</summary>
    public string? SessionId { get; init; }

    /// <summary>Receiver transport id (for <see cref="CastInboundKind.ReceiverStatusActive"/>).</summary>
    public string? TransportId { get; init; }

    /// <summary>Running receiver app id (for <see cref="CastInboundKind.ReceiverStatusActive"/>).</summary>
    public string? AppId { get; init; }

    /// <summary>Raw LAUNCH_ERROR reason code (for <see cref="CastInboundKind.LaunchError"/>).</summary>
    public string? LaunchErrorReason { get; init; }

    /// <summary><see langword="true"/> when the running app is DashCast.</summary>
    public bool IsDashCast => AppId == CastReceiverProtocol.DashCastAppId;
}

/// <summary>
/// Pure decoder from an inbound <see cref="CastMessage"/> to a
/// <see cref="CastInboundEvent"/>. Malformed / unrecognized payloads decode to
/// <see langword="null"/> (matching Swift's early <c>return</c> on a bad JSON body).
/// </summary>
public static class CastInboundRouter
{
    /// <summary>Parse one inbound message; returns <see langword="null"/> if the payload is not JSON.</summary>
    public static CastInboundEvent? Route(CastMessage message)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(message.PayloadUtf8);
        }
        catch (JsonException)
        {
            return null;
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            int? requestId = null;
            if (root.TryGetProperty("requestId", out var requestIdElement)
                && requestIdElement.ValueKind == JsonValueKind.Number
                && requestIdElement.TryGetInt32(out var parsedRequestId))
            {
                requestId = parsedRequestId;
            }

            var type = root.TryGetProperty("type", out var typeElement)
                       && typeElement.ValueKind == JsonValueKind.String
                ? typeElement.GetString()
                : null;

            switch (type)
            {
                case "RECEIVER_STATUS":
                    return ParseReceiverStatus(root, requestId);
                case "LAUNCH_ERROR":
                    return new CastInboundEvent
                    {
                        Kind = CastInboundKind.LaunchError,
                        RequestId = requestId,
                        LaunchErrorReason = root.TryGetProperty("reason", out var reasonElement)
                                            && reasonElement.ValueKind == JsonValueKind.String
                            ? reasonElement.GetString()
                            : "LAUNCH_ERROR",
                    };
                case "PING":
                    return new CastInboundEvent { Kind = CastInboundKind.Ping, RequestId = requestId };
                case "PONG":
                    return new CastInboundEvent { Kind = CastInboundKind.Pong, RequestId = requestId };
                default:
                    return new CastInboundEvent { Kind = CastInboundKind.Other, RequestId = requestId };
            }
        }
    }

    private static CastInboundEvent ParseReceiverStatus(JsonElement root, int? requestId)
    {
        if (root.TryGetProperty("status", out var status)
            && status.ValueKind == JsonValueKind.Object
            && status.TryGetProperty("applications", out var apps)
            && apps.ValueKind == JsonValueKind.Array
            && apps.GetArrayLength() > 0)
        {
            var first = apps[0];
            var sessionId = first.TryGetProperty("sessionId", out var s) && s.ValueKind == JsonValueKind.String
                ? s.GetString()
                : null;
            if (!string.IsNullOrEmpty(sessionId))
            {
                return new CastInboundEvent
                {
                    Kind = CastInboundKind.ReceiverStatusActive,
                    RequestId = requestId,
                    SessionId = sessionId,
                    TransportId = first.TryGetProperty("transportId", out var t) && t.ValueKind == JsonValueKind.String
                        ? t.GetString()
                        : null,
                    AppId = first.TryGetProperty("appId", out var a) && a.ValueKind == JsonValueKind.String
                        ? a.GetString()
                        : null,
                };
            }
        }

        return new CastInboundEvent { Kind = CastInboundKind.ReceiverStatusIdle, RequestId = requestId };
    }
}
