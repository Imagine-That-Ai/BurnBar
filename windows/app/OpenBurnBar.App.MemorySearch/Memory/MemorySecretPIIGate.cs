using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from OpenBurnBarCore/.../Memory/MemorySecretPIIGate.swift
//   (the evaluate/scan/entropy/redaction/derived-views half).
//
// The pre-persistence secret/PII gate. Three verdicts: Allow / Redact / Reject. FAIL-CLOSED: an
// unavailable corpus rejects everything with the synthetic corpus-unavailable finding. Per-view
// rule: entropy is only evaluated for a view when NO explicit corpus pattern matched that view.
// Redaction is bounded (max 8 passes) and downgrades to reject the instant any finding cannot be
// located on the current text. Span offsets are .NET char (UTF-16) offsets — faithful to the Swift
// grapheme offsets for the ASCII secrets/PII the corpus targets (documented parity assumption).

/// <summary>What the gate should do on a find. Swift: <c>enum MemoryGatePolicy</c>.</summary>
public enum MemoryGatePolicy
{
    /// <summary>Refuse the whole write if anything is found (fail-closed; the default).</summary>
    Reject,

    /// <summary>Attempt to redact located spans, re-gating until clean or a bounded cap.</summary>
    Redact,
}

/// <summary>The gate's decision. Swift: <c>enum MemoryGateVerdict</c>.</summary>
public sealed class MemoryGateVerdict
{
    public enum Kind
    {
        Allow,
        Redact,
        Reject,
    }

    private MemoryGateVerdict(Kind decision, string? text, IReadOnlyList<MemoryGateFinding> findings)
    {
        Decision = decision;
        RedactedText = text;
        Findings = findings;
    }

    public Kind Decision { get; }

    /// <summary>The redacted body (only for <see cref="Kind.Redact"/>).</summary>
    public string? RedactedText { get; }

    /// <summary>The findings (empty for <see cref="Kind.Allow"/>).</summary>
    public IReadOnlyList<MemoryGateFinding> Findings { get; }

    public static MemoryGateVerdict Allow() =>
        new(Kind.Allow, null, Array.Empty<MemoryGateFinding>());

    public static MemoryGateVerdict Redacted(string text, IReadOnlyList<MemoryGateFinding> findings) =>
        new(Kind.Redact, text, findings);

    public static MemoryGateVerdict Rejected(IReadOnlyList<MemoryGateFinding> findings) =>
        new(Kind.Reject, null, findings);
}

/// <summary>
/// The shared secret/PII gate. Swift: <c>enum MemorySecretPIIGate</c> (a stateless façade over a
/// process-wide corpus). Here it is an instance over an injectable <see cref="MemoryGateCorpus"/> so
/// tests can drive the fail-closed and custom-corpus branches; <see cref="Shared"/> uses the default.
/// </summary>
public sealed class MemorySecretPIIGate
{
    /// <summary>Emitted as the sole finding when the corpus is unavailable. Swift:
    /// <c>corpusUnavailableFindingID</c>.</summary>
    public const string CorpusUnavailableFindingId = "secret-scanner-corpus-unavailable";

    /// <summary>Swift: <c>corpusUnavailableLabel</c>.</summary>
    public const string CorpusUnavailableLabel = "Secret scanner corpus unavailable";

    /// <summary>Swift: <c>highEntropyFindingID</c>.</summary>
    public const string HighEntropyFindingId = "high-entropy-token";

    /// <summary>Swift: <c>hexHighEntropyFindingID</c>.</summary>
    public const string HexHighEntropyFindingId = "high-entropy-hex-token";

    /// <summary>Max redaction passes before failing closed. Swift: <c>maxRedactionPasses = 8</c>.</summary>
    public const int MaxRedactionPasses = 8;

    // Compiled decode-candidate / entropy-token regexes. Swift compiles these with `try?`; they are
    // valid so they always compile here.
    private static readonly Regex Base64CandidateRegex =
        new(@"(?<![A-Za-z0-9+/=])(?:[A-Za-z0-9+/]{32,}={0,2})(?![A-Za-z0-9+/=])", RegexOptions.CultureInvariant);

    private static readonly Regex HexCandidateRegex =
        new(@"(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{48,})(?![A-Fa-f0-9])", RegexOptions.CultureInvariant);

    private static readonly Regex SecretLikeTokenRegex =
        new(@"[A-Za-z0-9_+/=.-]{32,}", RegexOptions.CultureInvariant);

    private static readonly Regex LineContinuationRegex =
        new(@"\\\s*\n\s*", RegexOptions.CultureInvariant);

    private static readonly Regex JoinedStringLiteralRegex =
        new(@"[""']\s*(?:\\\s*)?\n\s*[""']", RegexOptions.CultureInvariant);

    private readonly MemoryGateCorpus _corpus;

    public MemorySecretPIIGate(MemoryGateCorpus corpus)
    {
        _corpus = corpus ?? throw new ArgumentNullException(nameof(corpus));
    }

    /// <summary>The gate over the default embedded corpus.</summary>
    public static MemorySecretPIIGate Shared { get; } = new(MemoryGateCorpus.Shared);

    /// <summary>Whether the corpus loaded cleanly. Swift: <c>isAvailable</c>.</summary>
    public bool IsAvailable => _corpus.Available;

    /// <summary>The loaded corpus version (empty when unavailable). Swift: <c>corpusVersion</c>.</summary>
    public string CorpusVersion => _corpus.Version;

    private readonly record struct ScanFinding(string Id, string Label, MemoryGateFindingKind Kind, GateSpan? Range);

    private readonly record struct GateSpan(int Lower, int Upper);

    /// <summary>Scan <paramref name="text"/> and return the decision. Swift: <c>evaluate(_:policy:)</c>.</summary>
    public MemoryGateVerdict Evaluate(string text, MemoryGatePolicy policy = MemoryGatePolicy.Reject)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!_corpus.Available)
        {
            return MemoryGateVerdict.Rejected(new[] { UnavailableFinding });
        }

        var scan = ScanFindings(text);
        if (scan.Count == 0)
        {
            return MemoryGateVerdict.Allow();
        }

        return policy switch
        {
            MemoryGatePolicy.Reject => MemoryGateVerdict.Rejected(DedupedPublicFindings(scan)),
            _ => RedactEvaluate(text, scan),
        };
    }

    /// <summary>Deduped findings without a policy. Swift: <c>findings(in:)</c>.</summary>
    public IReadOnlyList<MemoryGateFinding> Findings(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return _corpus.Available
            ? DedupedPublicFindings(ScanFindings(text))
            : new[] { UnavailableFinding };
    }

    /// <summary>Deduped, order-preserving labels. Swift: <c>labels(in:)</c>.</summary>
    public IReadOnlyList<string> Labels(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!_corpus.Available)
        {
            return new[] { CorpusUnavailableLabel };
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var labels = new List<string>();
        foreach (var finding in ScanFindings(text))
        {
            if (seen.Add(finding.Label))
            {
                labels.Add(finding.Label);
            }
        }

        return labels;
    }

    /// <summary>Deduped, order-preserving finding ids. Swift: <c>findingIDs(in:)</c>.</summary>
    public IReadOnlyList<string> FindingIds(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!_corpus.Available)
        {
            return new[] { CorpusUnavailableFindingId };
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var ids = new List<string>();
        foreach (var finding in ScanFindings(text))
        {
            if (seen.Add(finding.Id))
            {
                ids.Add(finding.Id);
            }
        }

        return ids;
    }

    private MemoryGateVerdict RedactEvaluate(string originalText, List<ScanFinding> initialScan)
    {
        if (initialScan.Exists(f => f.Range == null))
        {
            return MemoryGateVerdict.Rejected(DedupedPublicFindings(initialScan));
        }

        string working = originalText;
        var accumulated = new List<ScanFinding>(initialScan);
        int pass = 0;

        while (pass < MaxRedactionPasses)
        {
            var scan = pass == 0 ? initialScan : ScanFindings(working);
            if (scan.Count == 0)
            {
                return MemoryGateVerdict.Redacted(working, DedupedPublicFindings(accumulated));
            }

            if (scan.Exists(f => f.Range == null))
            {
                var combined = new List<ScanFinding>(accumulated);
                combined.AddRange(scan);
                return MemoryGateVerdict.Rejected(DedupedPublicFindings(combined));
            }

            accumulated.AddRange(scan);
            working = ApplyRedactions(scan, working);
            pass++;
        }

        var residual = ScanFindings(working);
        if (residual.Count == 0)
        {
            return MemoryGateVerdict.Redacted(working, DedupedPublicFindings(accumulated));
        }

        var all = new List<ScanFinding>(accumulated);
        all.AddRange(residual);
        return MemoryGateVerdict.Rejected(DedupedPublicFindings(all));
    }

    private static string ApplyRedactions(List<ScanFinding> findings, string text)
    {
        var spans = new List<(int Lower, int Upper, MemoryGateFindingKind Kind)>();
        foreach (var finding in findings)
        {
            if (finding.Range is GateSpan span)
            {
                spans.Add((span.Lower, span.Upper, finding.Kind));
            }
        }

        // Right-to-left so a replacement never shifts a still-pending (lower) span.
        spans.Sort((a, b) => b.Lower.CompareTo(a.Lower));

        string result = text;
        int lastAppliedLower = int.MaxValue;
        foreach (var span in spans)
        {
            if (span.Upper > lastAppliedLower)
            {
                continue;
            }

            if (span.Lower < 0 || span.Upper > result.Length || span.Lower >= span.Upper)
            {
                continue;
            }

            result = result[..span.Lower] + Placeholder(span.Kind) + result[span.Upper..];
            lastAppliedLower = span.Lower;
        }

        return result;
    }

    private static string Placeholder(MemoryGateFindingKind kind) =>
        kind == MemoryGateFindingKind.Pii ? "[REDACTED-PII]" : "[REDACTED-SECRET]";

    private List<ScanFinding> ScanFindings(string text)
    {
        var findings = new List<ScanFinding>();

        // View 0: the original text — findings are locatable.
        findings.AddRange(ScanView(text, locatable: true));

        // Derived views — real but NOT locatable on the original body (spans nil → forces reject).
        foreach (var view in DerivedViews(text))
        {
            findings.AddRange(ScanView(view, locatable: false));
        }

        return findings;
    }

    private List<ScanFinding> ScanView(string view, bool locatable)
    {
        var results = new List<ScanFinding>();
        bool matchedExplicitPattern = false;

        foreach (var pattern in _corpus.Patterns)
        {
            foreach (Match match in pattern.Regex.Matches(view))
            {
                string matched = match.Value;
                if (!pattern.Accepts(matched))
                {
                    continue;
                }

                matchedExplicitPattern = true;
                results.Add(new ScanFinding(
                    pattern.Id,
                    pattern.Label,
                    pattern.Kind,
                    locatable ? new GateSpan(match.Index, match.Index + match.Length) : null));
            }
        }

        if (!matchedExplicitPattern)
        {
            results.AddRange(EntropyFindings(view, locatable));
        }

        return results;
    }

    private List<ScanFinding> EntropyFindings(string text, bool locatable)
    {
        var results = new List<ScanFinding>();
        var entropy = _corpus.Entropy;
        if (entropy == null || !entropy.Enabled)
        {
            return results;
        }

        var hexEntropy = _corpus.HexEntropy;
        foreach (Match match in SecretLikeTokenRegex.Matches(text))
        {
            string token = match.Value;
            var span = locatable ? new GateSpan(match.Index, match.Index + match.Length) : (GateSpan?)null;

            // General high-entropy path (mixed-charset secrets).
            if (token.Length >= entropy.MinLength
                && token.Length <= entropy.MaxLength
                && DistinctCount(token) >= 10
                && ContainsLetter(token)
                && ContainsNumber(token)
                && ShannonEntropy(token) >= entropy.MinShannonEntropy)
            {
                results.Add(new ScanFinding(HighEntropyFindingId, entropy.Label, entropy.Kind, span));
                continue;
            }

            // Hex-charset path (lower threshold; pure hex caps below the general 4.2).
            if (hexEntropy != null
                && hexEntropy.Enabled
                && token.Length >= hexEntropy.MinLength
                && token.Length <= hexEntropy.MaxLength
                && IsHexToken(token)
                && ShannonEntropy(token) >= hexEntropy.MinShannonEntropy)
            {
                results.Add(new ScanFinding(HexHighEntropyFindingId, hexEntropy.Label, hexEntropy.Kind, span));
            }
        }

        return results;
    }

    private List<string> DerivedViews(string text)
    {
        var views = new List<string>();

        string lineContinuations = LineContinuationRegex.Replace(text, string.Empty);
        if (!string.Equals(lineContinuations, text, StringComparison.Ordinal))
        {
            views.Add(lineContinuations);
        }

        string joinedStringLiterals = JoinedStringLiteralRegex.Replace(text, string.Empty);
        if (!string.Equals(joinedStringLiterals, text, StringComparison.Ordinal)
            && !views.Contains(joinedStringLiterals))
        {
            views.Add(joinedStringLiterals);
        }

        views.AddRange(DecodedViews(text));
        return views;
    }

    private List<string> DecodedViews(string text)
    {
        var views = new List<string>();
        var decoding = _corpus.Decoding;
        if (decoding == null || !decoding.Enabled)
        {
            return views;
        }

        int maxCandidates = decoding.MaxCandidates;
        int maxDecodedBytes = decoding.MaxDecodedBytes;

        foreach (Match match in Base64CandidateRegex.Matches(text))
        {
            if (views.Count >= maxCandidates)
            {
                break;
            }

            string raw = match.Value;
            int remainder = raw.Length % 4;
            if (remainder != 0)
            {
                raw += new string('=', 4 - remainder);
            }

            byte[]? decoded = TryFromBase64(raw);
            if (decoded == null || decoded.Length == 0 || decoded.Length > maxDecodedBytes)
            {
                continue;
            }

            views.Add(Encoding.UTF8.GetString(decoded));
        }

        foreach (Match match in HexCandidateRegex.Matches(text))
        {
            if (views.Count >= maxCandidates)
            {
                break;
            }

            string candidate = match.Value;
            string evenMatch = candidate.Length % 2 == 0 ? candidate : candidate[..^1];
            byte[]? decoded = TryFromHex(evenMatch);
            if (decoded == null || decoded.Length == 0 || decoded.Length > maxDecodedBytes)
            {
                continue;
            }

            views.Add(Encoding.UTF8.GetString(decoded));
        }

        return views;
    }

    private List<MemoryGateFinding> DedupedPublicFindings(List<ScanFinding> scan)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<MemoryGateFinding>();
        foreach (var finding in scan)
        {
            if (seen.Add(finding.Id))
            {
                result.Add(new MemoryGateFinding(finding.Id, finding.Label, finding.Kind));
            }
        }

        return result;
    }

    private static MemoryGateFinding UnavailableFinding =>
        new(CorpusUnavailableFindingId, CorpusUnavailableLabel, MemoryGateFindingKind.Secret);

    /// <summary>Shannon entropy over the UTF-8 bytes. Swift: <c>shannonEntropy(_:)</c>.</summary>
    public static double ShannonEntropy(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length == 0)
        {
            return 0;
        }

        var counts = new Dictionary<byte, int>();
        foreach (byte b in bytes)
        {
            counts[b] = counts.TryGetValue(b, out int existing) ? existing + 1 : 1;
        }

        double length = bytes.Length;
        double entropy = 0;
        foreach (int count in counts.Values)
        {
            double probability = count / length;
            entropy -= probability * Math.Log2(probability);
        }

        return entropy;
    }

    private static bool IsHexToken(string token)
    {
        if (token.Length == 0)
        {
            return false;
        }

        foreach (byte b in Encoding.UTF8.GetBytes(token))
        {
            bool isHex = (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102);
            if (!isHex)
            {
                return false;
            }
        }

        return true;
    }

    private static int DistinctCount(string token)
    {
        var set = new HashSet<char>();
        foreach (char ch in token)
        {
            set.Add(ch);
        }

        return set.Count;
    }

    private static bool ContainsLetter(string token)
    {
        foreach (char ch in token)
        {
            if (char.IsLetter(ch))
            {
                return true;
            }
        }

        return false;
    }

    private static bool ContainsNumber(string token)
    {
        foreach (char ch in token)
        {
            if (char.IsNumber(ch))
            {
                return true;
            }
        }

        return false;
    }

    private static byte[]? TryFromBase64(string value)
    {
        try
        {
            return Convert.FromBase64String(value);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static byte[]? TryFromHex(string value)
    {
        if (value.Length % 2 != 0)
        {
            return null;
        }

        var bytes = new byte[value.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
        {
            if (!TryHexNibble(value[(i * 2) + 0], out int high) || !TryHexNibble(value[(i * 2) + 1], out int low))
            {
                return null;
            }

            bytes[i] = (byte)((high << 4) | low);
        }

        return bytes;
    }

    private static bool TryHexNibble(char ch, out int value)
    {
        if (ch >= '0' && ch <= '9')
        {
            value = ch - '0';
            return true;
        }

        if (ch >= 'a' && ch <= 'f')
        {
            value = ch - 'a' + 10;
            return true;
        }

        if (ch >= 'A' && ch <= 'F')
        {
            value = ch - 'A' + 10;
            return true;
        }

        value = 0;
        return false;
    }
}
