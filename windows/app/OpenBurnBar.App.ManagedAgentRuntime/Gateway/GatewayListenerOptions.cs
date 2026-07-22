using System;
using System.Net;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Normalized bind settings for the local OpenAI-compatible gateway. Persisted
/// settings are the default; explicit environment values remain available for
/// automation and development-host overrides.
/// </summary>
public sealed record GatewayListenerOptions
{
    public GatewayListenerOptions(bool enabled, string host, int port)
    {
        Enabled = enabled;
        Host = NormalizeHost(host);
        Port = NormalizePort(null, port);
        _ = BaseAddress;
    }

    public bool Enabled { get; }

    public string Host { get; }

    public int Port { get; }

    public bool IsLoopback =>
        string.Equals(Host, "localhost", StringComparison.OrdinalIgnoreCase)
        || (IPAddress.TryParse(Host, out IPAddress? address) && IPAddress.IsLoopback(address));

    public Uri BaseAddress => new UriBuilder(Uri.UriSchemeHttp, Host, Port, "/").Uri;

    public bool AllowsUnauthenticatedAccess(bool configuredAllow, string? allowOverride = null)
    {
        bool environmentAllows = string.Equals(allowOverride, "1", StringComparison.Ordinal)
            || string.Equals(allowOverride, "true", StringComparison.OrdinalIgnoreCase);
        return IsLoopback && (configuredAllow || environmentAllows);
    }

    public static GatewayListenerOptions Resolve(
        bool configuredEnabled,
        string? configuredHost,
        int configuredPort,
        string? enabledOverride = null,
        string? hostOverride = null,
        string? portOverride = null)
    {
        string host = NormalizeHost(hostOverride ?? configuredHost);
        int port = NormalizePort(portOverride, configuredPort);
        bool hasLegacyEndpointOverride = !string.IsNullOrWhiteSpace(hostOverride)
            || !string.IsNullOrWhiteSpace(portOverride);
        bool enabled = ParseBooleanOverride(enabledOverride)
            ?? (hasLegacyEndpointOverride || configuredEnabled);
        return new GatewayListenerOptions(enabled, host, port);
    }

    public static string NormalizeHost(string? host)
    {
        string normalized = (host ?? string.Empty).Trim();
        if (normalized.Length == 0)
        {
            throw new ArgumentException("A gateway bind host is required.", nameof(host));
        }

        if (normalized.Contains('/')
            || normalized.Contains('\\')
            || Uri.CheckHostName(normalized) == UriHostNameType.Unknown)
        {
            throw new ArgumentException("The gateway bind host is invalid.", nameof(host));
        }

        return normalized;
    }

    private static int NormalizePort(string? portOverride, int configuredPort)
    {
        if (!string.IsNullOrWhiteSpace(portOverride))
        {
            if (!int.TryParse(portOverride.Trim(), out int parsed))
            {
                throw new ArgumentException("The gateway port override must be an integer.", nameof(portOverride));
            }

            configuredPort = parsed;
        }

        if (configuredPort is <= 0 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(configuredPort), "The gateway port must be between 1 and 65535.");
        }

        return configuredPort;
    }

    private static bool? ParseBooleanOverride(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value.Trim().ToLowerInvariant() switch
        {
            "1" or "true" => true,
            "0" or "false" => false,
            _ => throw new ArgumentException(
                "The gateway enabled override must be 1, 0, true, or false.",
                nameof(value)),
        };
    }
}
