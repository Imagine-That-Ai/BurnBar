using System;
using System.Security.Cryptography;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Fail-closed bearer-token policy for the local gateway. Persistence belongs to
/// the desktop host; this portable policy owns trimming, opt-out semantics, and
/// cryptographically secure token generation.
/// </summary>
public static class GatewayAuthTokenPolicy
{
    private const int TokenBytes = 32;

    /// <summary>
    /// Returns an existing token, generates one when required, or returns null
    /// only when unauthenticated loopback was explicitly opted into.
    /// </summary>
    public static string? Resolve(
        string? configuredToken,
        bool allowUnauthenticatedLoopback,
        Func<string>? generator = null)
    {
        string trimmed = configuredToken?.Trim() ?? string.Empty;
        if (trimmed.Length > 0)
        {
            return trimmed;
        }

        if (allowUnauthenticatedLoopback)
        {
            return null;
        }

        string generated = (generator ?? Generate)().Trim();
        if (generated.Length == 0)
        {
            throw new InvalidOperationException("Gateway authentication token generation returned an empty value.");
        }

        return generated;
    }

    /// <summary>Generates a URL-safe 256-bit token from the OS CSPRNG.</summary>
    public static string Generate()
    {
        byte[] bytes = RandomNumberGenerator.GetBytes(TokenBytes);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
