using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Configuration;

public enum SecretLeakKind
{
    Exact,
    Encoded,
    Substring,
    StructuredField,
    HighEntropy,
}

public sealed record SecretLeakFinding(
    SecretLeakKind Kind,
    string Artifact,
    string Detail);

public static class SecretLeakScanner
{
    private static readonly Regex StructuredSecretField = new(
        "\\b(?:api[_-]?key|app[_-]?check|auth(?:orization)?|credential|firebase[_-]?id[_-]?token|id[_-]?token|passphrase|password|refresh[_-]?token|secret|token|vault[_-]?key)\\b\\s*[:=]\\s*([\"']?)(?<value>[^\"'\\s,;}\\]]+)\\1",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex HighEntropyToken = new(
        "\\b[A-Za-z0-9_+/=-]{32,}\\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static IReadOnlyList<SecretLeakFinding> ScanText(
        string artifact,
        string text,
        IEnumerable<string> canarySecrets)
    {
        var findings = new List<SecretLeakFinding>();
        var secrets = canarySecrets.Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => s.Trim()).ToArray();
        foreach (string secret in secrets)
        {
            if (text.Contains(secret, StringComparison.Ordinal))
            {
                findings.Add(new SecretLeakFinding(SecretLeakKind.Exact, artifact, "exact canary secret"));
            }

            foreach (string variant in SecretRedactor.SecretVariants(secret))
            {
                if (!string.Equals(variant, secret, StringComparison.Ordinal)
                    && text.Contains(variant, StringComparison.Ordinal))
                {
                    findings.Add(new SecretLeakFinding(SecretLeakKind.Encoded, artifact, "encoded canary secret"));
                }
            }

            if (secret.Length >= 20)
            {
                string middle = secret.Substring(4, Math.Min(16, secret.Length - 8));
                if (middle.Length >= 12 && text.Contains(middle, StringComparison.Ordinal))
                {
                    findings.Add(new SecretLeakFinding(SecretLeakKind.Substring, artifact, "canary substring"));
                }
            }
        }

        foreach (Match match in StructuredSecretField.Matches(text))
        {
            string value = match.Groups["value"].Value;
            if (!value.Contains("REDACTED", StringComparison.OrdinalIgnoreCase)
                && value.Length >= 8)
            {
                findings.Add(new SecretLeakFinding(SecretLeakKind.StructuredField, artifact, "unredacted structured secret field"));
            }
        }

        foreach (Match match in HighEntropyToken.Matches(text))
        {
            string value = match.Value;
            if (!string.Equals(value, "[REDACTED]", StringComparison.Ordinal)
                && SecretRedactor.ShannonEntropy(value) >= 3.9)
            {
                findings.Add(new SecretLeakFinding(SecretLeakKind.HighEntropy, artifact, "high-entropy token-like value"));
            }
        }

        return findings;
    }

    public static IReadOnlyList<SecretLeakFinding> ScanFiles(
        IEnumerable<string> paths,
        IEnumerable<string> canarySecrets)
    {
        var findings = new List<SecretLeakFinding>();
        foreach (string path in paths)
        {
            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                findings.Add(new SecretLeakFinding(SecretLeakKind.StructuredField, path, "artifact unreadable"));
                continue;
            }

            findings.AddRange(ScanText(path, text, canarySecrets));
        }

        return findings;
    }
}
