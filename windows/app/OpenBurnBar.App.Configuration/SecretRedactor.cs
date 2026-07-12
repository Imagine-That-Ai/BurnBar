using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Configuration;

public sealed class SecretRedactor
{
    private static readonly Regex StructuredSecretField = new(
        "(?<key>\\b(?:api[_-]?key|app[_-]?check|auth(?:orization)?|credential|firebase[_-]?id[_-]?token|id[_-]?token|passphrase|password|refresh[_-]?token|secret|token|vault[_-]?key)\\b\\s*[:=]\\s*)(?<quote>[\"']?)(?<value>[^\"'\\s,;}\\]]+)(\\k<quote>)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex HighEntropyToken = new(
        "\\b[A-Za-z0-9_+/=-]{32,}\\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private readonly ConcurrentDictionary<string, byte> _known = new(StringComparer.Ordinal);

    public static SecretRedactor Shared { get; } = new();

    public void Register(string? secret)
    {
        if (string.IsNullOrWhiteSpace(secret))
        {
            return;
        }

        string trimmed = secret.Trim();
        if (trimmed.Length < 4)
        {
            return;
        }

        foreach (string variant in SecretVariants(trimmed))
        {
            _known.TryAdd(variant, 0);
        }
    }

    public string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        string output = text;
        foreach (string secret in _known.Keys.OrderByDescending(v => v.Length))
        {
            if (secret.Length >= 4)
            {
                output = output.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
            }
        }

        output = StructuredSecretField.Replace(output, match =>
        {
            string value = match.Groups["value"].Value;
            return LooksLikeSensitiveValue(value)
                ? match.Groups["key"].Value + match.Groups["quote"].Value + "[REDACTED]" + match.Groups["quote"].Value
                : match.Value;
        });

        output = HighEntropyToken.Replace(output, match =>
            ShannonEntropy(match.Value) >= 3.7 ? "[REDACTED]" : match.Value);

        return output;
    }

    public static IReadOnlyList<string> SecretVariants(string secret)
    {
        var variants = new HashSet<string>(StringComparer.Ordinal)
        {
            secret,
            Convert.ToBase64String(Encoding.UTF8.GetBytes(secret)),
            Convert.ToHexString(Encoding.UTF8.GetBytes(secret)).ToLowerInvariant(),
            Convert.ToHexString(Encoding.UTF8.GetBytes(secret)).ToUpperInvariant(),
            WebUtility.UrlEncode(secret),
        };

        if (secret.Length >= 16)
        {
            variants.Add(secret[..16]);
            variants.Add(secret[^16..]);
        }

        if (secret.Length >= 20)
        {
            for (int i = 0; i <= secret.Length - 16; i += 4)
            {
                variants.Add(secret.Substring(i, 16));
            }
        }

        return variants.Where(v => !string.IsNullOrWhiteSpace(v) && v.Length >= 4).ToArray();
    }

    private static bool LooksLikeSensitiveValue(string value) =>
        value.Length >= 8 || ShannonEntropy(value) >= 3.2;

    internal static double ShannonEntropy(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return 0;
        }

        var counts = new Dictionary<char, int>();
        foreach (char ch in value)
        {
            counts[ch] = counts.TryGetValue(ch, out int count) ? count + 1 : 1;
        }

        double entropy = 0;
        foreach (int count in counts.Values)
        {
            double p = (double)count / value.Length;
            entropy -= p * Math.Log(p, 2);
        }

        return entropy;
    }
}
