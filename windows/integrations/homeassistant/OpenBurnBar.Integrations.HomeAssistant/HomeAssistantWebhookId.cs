using System;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.Integrations.HomeAssistant;

// High-entropy HA webhook id generator.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantWebhookID.swift
//   enum HomeAssistantWebhookID (prefix / secretLength / generate / isOurs).
//
// HA webhook ids are public-ish LAN strings, so they must be high-entropy. We
// follow HA's own approach: 32 random chars from a lowercase base36 alphabet,
// prefixed so the source is obvious in the user's automations.yaml.

public static class HomeAssistantWebhookId
{
    public const string Prefix = "openburnbar_cast_recover_";
    public const int SecretLength = 32;

    private static readonly char[] Alphabet = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray();

    /// Cryptographically random URL-safe webhook id. `randomBytes` is injectable
    /// so tests can drive it deterministically (parity with the Swift default arg).
    public static string Generate(Func<byte[]>? randomBytes = null)
    {
        var bytes = (randomBytes ?? DefaultRandomBytes)();
        var output = new StringBuilder(Prefix.Length + SecretLength);
        output.Append(Prefix);
        var count = Math.Min(SecretLength, bytes.Length);
        for (var i = 0; i < count; i++)
        {
            output.Append(Alphabet[bytes[i] % Alphabet.Length]);
        }
        return output.ToString();
    }

    /// True when the supplied id was minted by us (prefix + exact length).
    public static bool IsOurs(string id) =>
        id.StartsWith(Prefix, StringComparison.Ordinal) &&
        id.Length == Prefix.Length + SecretLength;

    /// Default CSPRNG path.
    public static byte[] DefaultRandomBytes()
    {
        var output = new byte[SecretLength];
        RandomNumberGenerator.Fill(output);
        return output;
    }
}
