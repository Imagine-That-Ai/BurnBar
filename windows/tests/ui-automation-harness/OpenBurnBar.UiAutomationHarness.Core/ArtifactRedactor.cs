using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace OpenBurnBar.UiAutomationHarness.Core;

public sealed class ArtifactRedactor
{
    private static readonly Regex FactoryKeyRegex = new(
        "fk-[A-Za-z0-9_-]{24,}",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex SecretPairRegex = new(
        "(?i)(client_secret|password|api[_-]?key|token)(['\"\\s:=]+)([^'\"\\s,;]{8,})",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly IReadOnlyList<string> _pathPrefixes;

    public ArtifactRedactor(params string?[] pathPrefixes)
    {
        var prefixes = new List<string>();
        foreach (string? prefix in pathPrefixes)
        {
            if (!string.IsNullOrWhiteSpace(prefix))
            {
                prefixes.Add(Normalize(prefix));
            }
        }

        _pathPrefixes = prefixes;
    }

    public string Redact(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        string redacted = FactoryKeyRegex.Replace(value, "[REDACTED_FACTORY_KEY]");
        redacted = SecretPairRegex.Replace(redacted, "$1$2[REDACTED]");
        foreach (string prefix in _pathPrefixes)
        {
            redacted = redacted.Replace(prefix, "[REDACTED_PATH]", StringComparison.OrdinalIgnoreCase);
            redacted = redacted.Replace(prefix.Replace('\\', '/'), "[REDACTED_PATH]", StringComparison.OrdinalIgnoreCase);
        }

        return redacted;
    }

    private static string Normalize(string path) => path.Trim().TrimEnd('\\', '/');
}
