// Watchdog command/response wire protocol + portable command handler.
//
// Port of PrivilegedInputKillSwitchWatchdogMain.swift. The watchdog is a
// separate, always-running process that sets the durable kill flag when the app
// cannot (crash, wedged coordinator) — the "signed local kill channel
// independent of RC" from master plan R17.
//
// Wire:
//   request  = {"action":"activate|clear|health","reason":"..."}   (reason optional)
//   response = {"ok":true|false,"detail":"..."}
//
// Every accepted connection is peer-authenticated: the caller must carry a valid
// first-party code signature. On Windows that peer-auth + the transport is the
// landed named-pipe peer-auth harness (OpenBurnBar.Pal.Ipc) behind
// IWatchdogPeerAuthenticator; this portable half owns the command semantics so
// the exact activate/clear/health behavior is unit-tested on the authoring host.

using System;
using System.Text;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.KillSwitch;

namespace OpenBurnBar.ComputerUse.Core.Watchdog;

/// <summary>The parsed action of a watchdog command.</summary>
public enum WatchdogCommandKind
{
    Activate,
    Clear,
    Health,
    Unsupported,
    Malformed,
}

/// <summary>A parsed watchdog command.</summary>
public sealed class WatchdogCommand
{
    private WatchdogCommand(WatchdogCommandKind kind, string? rawAction, string? reason)
    {
        Kind = kind;
        RawAction = rawAction;
        Reason = reason;
    }

    public WatchdogCommandKind Kind { get; }

    public string? RawAction { get; }

    public string? Reason { get; }

    /// <summary>Parses a request payload; never throws — malformed input maps to Malformed.</summary>
    public static WatchdogCommand Parse(ReadOnlySpan<byte> payload)
    {
        try
        {
            using var document = JsonDocument.Parse(payload.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("action", out var actionElement)
                || actionElement.ValueKind != JsonValueKind.String)
            {
                return new WatchdogCommand(WatchdogCommandKind.Malformed, null, null);
            }

            var action = actionElement.GetString();
            var reason = root.TryGetProperty("reason", out var reasonElement)
                && reasonElement.ValueKind == JsonValueKind.String
                ? reasonElement.GetString()
                : null;

            var kind = action switch
            {
                "activate" => WatchdogCommandKind.Activate,
                "clear" => WatchdogCommandKind.Clear,
                "health" => WatchdogCommandKind.Health,
                _ => WatchdogCommandKind.Unsupported,
            };
            return new WatchdogCommand(kind, action, reason);
        }
        catch (JsonException)
        {
            return new WatchdogCommand(WatchdogCommandKind.Malformed, null, null);
        }
    }

    /// <summary>Encodes a request payload (used by the app-side client + tests).</summary>
    public static byte[] Encode(string action, string? reason = null)
    {
        var map = new System.Collections.Generic.Dictionary<string, string> { ["action"] = action };
        if (reason is not null)
        {
            map["reason"] = reason;
        }

        return JsonSerializer.SerializeToUtf8Bytes(map);
    }
}

/// <summary>A watchdog response.</summary>
public readonly struct WatchdogResponse
{
    public WatchdogResponse(bool ok, string detail)
    {
        Ok = ok;
        Detail = detail;
    }

    public bool Ok { get; }

    public string Detail { get; }

    /// <summary>Serializes exactly as the daemon writes it: <c>{"ok":..,"detail":".."}</c> + '\n'.</summary>
    public byte[] Encode()
    {
        var json = $"{{\"ok\":{(Ok ? "true" : "false")},\"detail\":\"{Escape(Detail)}\"}}\n";
        return Encoding.UTF8.GetBytes(json);
    }

    /// <summary>Parses a bounded response without relying on substring matches.</summary>
    public static WatchdogResponse Parse(ReadOnlySpan<byte> payload)
    {
        if (payload.Length is 0 or > 4 * 1024)
        {
            return new WatchdogResponse(ok: false, detail: "invalid_response");
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(payload.ToArray());
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("ok", out JsonElement okElement)
                || okElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
                || !root.TryGetProperty("detail", out JsonElement detailElement)
                || detailElement.ValueKind != JsonValueKind.String)
            {
                return new WatchdogResponse(ok: false, detail: "invalid_response");
            }

            string detail = detailElement.GetString() ?? string.Empty;
            return detail.Length is > 0 and <= 128
                ? new WatchdogResponse(okElement.GetBoolean(), detail)
                : new WatchdogResponse(ok: false, detail: "invalid_response");
        }
        catch (JsonException)
        {
            return new WatchdogResponse(ok: false, detail: "invalid_response");
        }
    }

    private static string Escape(string value) => value.Replace("\\", "\\\\").Replace("\"", "\\\"");
}

/// <summary>
/// Authenticates a watchdog peer before any command is processed. On Windows the
/// implementation delegates to the landed named-pipe peer-auth harness
/// (client SID/PID + image + first-party code-signature validation).
/// </summary>
public interface IWatchdogPeerAuthenticator
{
    /// <summary>True iff the connected peer is authorized to command the watchdog.</summary>
    bool IsAuthorized(object peer);
}

/// <summary>
/// The portable watchdog command handler. Applies activate/clear/health to the
/// durable kill flag exactly as the daemon does, gated on peer authentication.
/// </summary>
public sealed class WatchdogServer
{
    private readonly IKillSwitchFlag _flag;

    public WatchdogServer(IKillSwitchFlag flag)
    {
        _flag = flag ?? throw new ArgumentNullException(nameof(flag));
    }

    /// <summary>Handles a request payload, returning the response payload bytes.</summary>
    public byte[] Handle(ReadOnlySpan<byte> requestPayload)
        => Respond(WatchdogCommand.Parse(requestPayload)).Encode();

    /// <summary>Handles a request only after the peer authenticates; else "peer_unauthorized".</summary>
    public byte[] HandleAuthenticated(object peer, IWatchdogPeerAuthenticator authenticator, ReadOnlySpan<byte> requestPayload)
    {
        if (!authenticator.IsAuthorized(peer))
        {
            return new WatchdogResponse(ok: false, detail: "peer_unauthorized").Encode();
        }

        return Handle(requestPayload);
    }

    private WatchdogResponse Respond(WatchdogCommand command)
    {
        switch (command.Kind)
        {
            case WatchdogCommandKind.Activate:
                _flag.Activate(command.Reason ?? "watchdog");
                return new WatchdogResponse(ok: true, detail: "activated");
            case WatchdogCommandKind.Clear:
                _flag.Clear();
                return new WatchdogResponse(ok: true, detail: "cleared");
            case WatchdogCommandKind.Health:
                return new WatchdogResponse(ok: true, detail: _flag.IsActive ? "active" : "idle");
            case WatchdogCommandKind.Malformed:
                return new WatchdogResponse(ok: false, detail: "malformed_command");
            case WatchdogCommandKind.Unsupported:
            default:
                return new WatchdogResponse(ok: false, detail: "unsupported_action");
        }
    }
}
