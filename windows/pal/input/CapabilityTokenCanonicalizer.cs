// Canonical signable-bytes for a capability token — the security-critical wire.
//
// Byte-parity contract with macOS CapabilityTokenSigner.SignableBody:
//   signature = Ed25519.sign(privKey, UTF-8(canonicalJSON(tokenFieldsWithoutSignature)))
// where canonicalJSON is JSONEncoder output with [.sortedKeys, .withoutEscapingSlashes]
// and ISO8601 dates with fractional seconds. The signature field itself is EXCLUDED.
//
// The macOS synthesized Codable omits nil optionals (encodeIfPresent), so an absent
// boundEscrowDeviceId / attestationHashBlake3 is an ABSENT key here too. Keys are emitted
// in UTF-8 sorted order. This is hand-rolled (not System.Text.Json) so key order, null
// omission, number formatting, and string escaping are byte-deterministic and pinned by a
// golden test — the exact bytes an issuer signs and a leaf verifies.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace OpenBurnBar.Pal.Input;

/// <summary>Produces the canonical UTF-8 signable bytes for a
/// <see cref="VirtualHidCapabilityToken"/>. Deterministic and byte-identical to the
/// macOS signer's <c>SignableBody</c> encoding.</summary>
public static class CapabilityTokenCanonicalizer
{
    /// <summary>The signed body as its exact canonical JSON string (sorted keys, nil
    /// optionals omitted, ISO8601 fractional-second UTC dates, minimal escaping).</summary>
    public static string CanonicalJson(VirtualHidCapabilityToken token)
    {
        if (token is null)
        {
            throw new ArgumentNullException(nameof(token));
        }

        // Emit keys in UTF-8 sorted order:
        //   actionBudget, allowedActionKinds, [attestationHashBlake3], [boundEscrowDeviceId],
        //   domain, expiresAt, issuedAt, nonce, schemaVersion, scopeHash
        var sb = new StringBuilder(256);
        sb.Append('{');

        AppendNumber(sb, "actionBudget", token.ActionBudget, first: true);
        AppendStringArray(sb, "allowedActionKinds", token.AllowedActionKinds);
        if (token.AttestationHashBlake3 is not null)
        {
            AppendString(sb, "attestationHashBlake3", token.AttestationHashBlake3);
        }
        if (token.BoundEscrowDeviceId is not null)
        {
            AppendString(sb, "boundEscrowDeviceId", token.BoundEscrowDeviceId);
        }
        AppendString(sb, "domain", token.Domain.ToWire());
        AppendString(sb, "expiresAt", CanonicalDateString(token.ExpiresAt));
        AppendString(sb, "issuedAt", CanonicalDateString(token.IssuedAt));
        AppendString(sb, "nonce", token.Nonce);
        AppendNumber(sb, "schemaVersion", token.SchemaVersion);
        AppendString(sb, "scopeHash", token.ScopeHash);

        sb.Append('}');
        return sb.ToString();
    }

    /// <summary>The canonical signable bytes (UTF-8 of <see cref="CanonicalJson"/>).</summary>
    public static byte[] CanonicalBytes(VirtualHidCapabilityToken token) =>
        Encoding.UTF8.GetBytes(CanonicalJson(token));

    /// <summary>ISO8601 with fractional (millisecond) seconds in UTC — matches
    /// <c>ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])</c>.</summary>
    public static string CanonicalDateString(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static void AppendNumber(StringBuilder sb, string key, int value, bool first = false)
    {
        if (!first)
        {
            sb.Append(',');
        }
        AppendJsonString(sb, key);
        sb.Append(':');
        sb.Append(value.ToString(CultureInfo.InvariantCulture));
    }

    private static void AppendString(StringBuilder sb, string key, string value)
    {
        sb.Append(',');
        AppendJsonString(sb, key);
        sb.Append(':');
        AppendJsonString(sb, value);
    }

    private static void AppendStringArray(StringBuilder sb, string key, IReadOnlyList<string> values)
    {
        sb.Append(',');
        AppendJsonString(sb, key);
        sb.Append(":[");
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(',');
            }
            AppendJsonString(sb, values[i]);
        }
        sb.Append(']');
    }

    // Minimal JSON string escaping matching Swift JSONEncoder with .withoutEscapingSlashes:
    // escape " and \ and C0 control chars; forward slash is NOT escaped.
    private static void AppendJsonString(StringBuilder sb, string value)
    {
        sb.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20)
                    {
                        sb.Append("\\u");
                        sb.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }
        sb.Append('"');
    }
}
