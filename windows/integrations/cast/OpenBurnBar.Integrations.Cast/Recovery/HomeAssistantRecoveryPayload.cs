// Parity source: AgentLens/Services/Cast/HomeAssistantCastRecoveryClient.swift (payload)

using System;
using System.Text.Json.Nodes;
using OpenBurnBar.Integrations.Cast.Model;

namespace OpenBurnBar.Integrations.Cast.Recovery;

/// <summary>
/// Builds the JSON body POSTed to a Home Assistant webhook when native Cast
/// exhausts its retries. Faithful port of the Swift <c>payload</c> builder; the
/// actual HTTP call lives in the Windows adapter (or any <c>HttpClient</c> host),
/// so the body shape stays unit-testable off-Windows.
/// </summary>
public static class HomeAssistantRecoveryPayload
{
    /// <summary>Build the recovery JSON object for a device + dashboard URL + reason.</summary>
    public static JsonObject Build(
        CastDevice device,
        string dashboardUrl,
        string reason,
        DateTimeOffset requestedAt)
    {
        if (device is null)
        {
            throw new ArgumentNullException(nameof(device));
        }

        if (dashboardUrl is null)
        {
            throw new ArgumentNullException(nameof(dashboardUrl));
        }

        if (reason is null)
        {
            throw new ArgumentNullException(nameof(reason));
        }

        return new JsonObject
        {
            ["source"] = "openburnbar",
            ["action"] = "cast_recovery",
            ["device"] = new JsonObject
            {
                ["serviceName"] = device.ServiceName,
                ["friendlyName"] = device.FriendlyName,
                ["host"] = device.Host,
                ["port"] = device.Port,
                ["model"] = device.Model,
            },
            ["dashboardURL"] = dashboardUrl,
            ["reason"] = reason,
            // ISO-8601 UTC, matching Swift's ISO8601DateFormatter default.
            ["requestedAt"] = requestedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
        };
    }

    /// <summary>Build the recovery body as a compact UTF-8 JSON string.</summary>
    public static string BuildJson(
        CastDevice device,
        string dashboardUrl,
        string reason,
        DateTimeOffset requestedAt)
        => Build(device, dashboardUrl, reason, requestedAt).ToJsonString();
}
