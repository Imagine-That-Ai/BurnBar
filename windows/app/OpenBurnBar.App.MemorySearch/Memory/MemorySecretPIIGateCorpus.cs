using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.MemorySearch.Memory;

// PORTED (faithful) from OpenBurnBarCore/.../Memory/MemorySecretPIIGate.swift
//   (the corpus model + loading + compile + validators half).
//
// The compiled corpus is loaded from the SAME committed secret-pattern-corpus.json the macOS/daemon
// gate loads (linked as an EmbeddedResource in the csproj — single source of truth, no duplication).
// FAIL-CLOSED invariant: a missing/corrupt corpus, an unknown finding `kind`, or an uncompilable
// regex makes the WHOLE corpus Unavailable, so every evaluation rejects. ICU regex flags map to
// .NET: caseInsensitive→IgnoreCase, dotMatchesNewlines→Singleline, anchorsMatchLines→Multiline.

/// <summary>Whether a finding is a credential/secret or PII. Swift: <c>enum MemoryGateFindingKind</c>.</summary>
public enum MemoryGateFindingKind
{
    Secret,
    Pii,
}

/// <summary>Lowercase raw-value parity + parse. Swift: the <c>String</c>-backed enum rawValues.</summary>
public static class MemoryGateFindingKindExtensions
{
    public static string RawValue(this MemoryGateFindingKind kind) =>
        kind == MemoryGateFindingKind.Pii ? "pii" : "secret";

    /// <summary>Maps a raw value to a kind; null for an unrecognized value (forces fail-closed).</summary>
    public static MemoryGateFindingKind? ParseKind(string? raw) => raw switch
    {
        "secret" => MemoryGateFindingKind.Secret,
        "pii" => MemoryGateFindingKind.Pii,
        _ => null,
    };
}

/// <summary>A single thing the gate found. Swift: <c>struct MemoryGateFinding</c>.</summary>
public sealed record MemoryGateFinding(string Id, string Label, MemoryGateFindingKind Kind);

/// <summary>The post-match validator a corpus pattern declared. Swift: <c>CompiledPattern.Validator</c>.</summary>
public enum MemoryGateValidator
{
    None,
    Luhn,
    Ipv4Octets,
}

/// <summary>A compiled corpus pattern + its validator. Swift: <c>struct CompiledPattern</c>. A loose
/// regex that matched but failed its validator is NOT a finding.</summary>
public sealed class CompiledPattern
{
    public string Id { get; }

    public string Label { get; }

    public MemoryGateFindingKind Kind { get; }

    public Regex Regex { get; }

    public MemoryGateValidator Validator { get; }

    public CompiledPattern(string id, string label, MemoryGateFindingKind kind, Regex regex, MemoryGateValidator validator)
    {
        Id = id;
        Label = label;
        Kind = kind;
        Regex = regex;
        Validator = validator;
    }

    /// <summary>Swift: <c>accepts(_:)</c>.</summary>
    public bool Accepts(string matched) => Validator switch
    {
        MemoryGateValidator.None => true,
        MemoryGateValidator.Luhn => MemoryGateValidators.PassesLuhn(matched),
        MemoryGateValidator.Ipv4Octets => MemoryGateValidators.HasBoundedIpv4Octets(matched),
        _ => true,
    };
}

/// <summary>Entropy heuristic config. Swift: <c>struct EntropyConfig</c>.</summary>
public sealed record EntropyConfig(
    bool Enabled,
    string Label,
    MemoryGateFindingKind Kind,
    int MinLength,
    int MaxLength,
    double MinShannonEntropy);

/// <summary>Decode-candidate config. Swift: <c>struct DecodingConfig</c>.</summary>
public sealed record DecodingConfig(bool Enabled, int MaxCandidates, int MaxDecodedBytes);

/// <summary>
/// The loaded, compiled, immutable corpus. Swift: <c>struct LoadedCorpus</c>. <see cref="Shared"/>
/// is the lazily-loaded default (from the embedded JSON); <see cref="Unavailable"/> and
/// <see cref="FromJson"/> exist so tests can drive the fail-closed and custom-corpus branches.
/// </summary>
public sealed class MemoryGateCorpus
{
    public string Version { get; }

    public IReadOnlyList<CompiledPattern> Patterns { get; }

    public EntropyConfig? Entropy { get; }

    public EntropyConfig? HexEntropy { get; }

    public DecodingConfig? Decoding { get; }

    public bool Available { get; }

    private MemoryGateCorpus(
        string version,
        IReadOnlyList<CompiledPattern> patterns,
        EntropyConfig? entropy,
        EntropyConfig? hexEntropy,
        DecodingConfig? decoding,
        bool available)
    {
        Version = version;
        Patterns = patterns;
        Entropy = entropy;
        HexEntropy = hexEntropy;
        Decoding = decoding;
        Available = available;
    }

    /// <summary>The fail-closed corpus. Swift: <c>LoadedCorpus.unavailable</c>.</summary>
    public static MemoryGateCorpus Unavailable { get; } =
        new(string.Empty, Array.Empty<CompiledPattern>(), null, null, null, false);

    private static readonly Lazy<MemoryGateCorpus> LazyShared = new(LoadEmbedded);

    /// <summary>The process-wide default, loaded once from the embedded JSON.</summary>
    public static MemoryGateCorpus Shared => LazyShared.Value;

    /// <summary>Loads + compiles a corpus from JSON. Returns <see cref="Unavailable"/> on any corrupt
    /// pattern / unknown kind / parse failure. Swift: <c>loadCorpus()</c>.</summary>
    public static MemoryGateCorpus FromJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        RawCorpus? decoded = RawCorpus.TryDecode(json);
        if (decoded == null)
        {
            return Unavailable;
        }

        var compiled = new List<CompiledPattern>();
        foreach (var spec in decoded.Patterns)
        {
            RegexOptions options = RegexOptions.CultureInvariant;
            if (spec.CaseInsensitive == true)
            {
                options |= RegexOptions.IgnoreCase;
            }

            if (spec.DotMatchesNewlines == true)
            {
                options |= RegexOptions.Singleline;
            }

            if (spec.AnchorsMatchLines == true)
            {
                options |= RegexOptions.Multiline;
            }

            Regex regex;
            try
            {
                regex = new Regex(spec.Regex, options);
            }
            catch (ArgumentException)
            {
                // Corrupt pattern => fail closed for the whole gate.
                return Unavailable;
            }

            var kind = MemoryGateFindingKindExtensions.ParseKind(spec.Kind);
            if (kind == null)
            {
                return Unavailable;
            }

            compiled.Add(new CompiledPattern(spec.Id, spec.Label, kind.Value, regex, ParseValidator(spec.Validator)));
        }

        return new MemoryGateCorpus(
            decoded.Version,
            compiled,
            BuildEntropy(decoded.Entropy),
            BuildEntropy(decoded.HexEntropy),
            decoded.Decoding is { } d ? new DecodingConfig(d.Enabled, d.MaxCandidates, d.MaxDecodedBytes) : null,
            available: true);
    }

    private static MemoryGateCorpus LoadEmbedded()
    {
        string? json = ReadEmbeddedCorpus();
        return json == null ? Unavailable : FromJson(json);
    }

    private static string? ReadEmbeddedCorpus()
    {
        var assembly = typeof(MemoryGateCorpus).Assembly;
        string? name = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("secret-pattern-corpus.json", StringComparison.Ordinal));
        if (name == null)
        {
            return null;
        }

        using Stream? stream = assembly.GetManifestResourceStream(name);
        if (stream == null)
        {
            return null;
        }

        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static MemoryGateValidator ParseValidator(string? raw) => raw switch
    {
        "luhn" => MemoryGateValidator.Luhn,
        "ipv4Octets" => MemoryGateValidator.Ipv4Octets,
        _ => MemoryGateValidator.None,
    };

    private static EntropyConfig? BuildEntropy(RawCorpus.RawEntropy? raw)
    {
        if (raw == null)
        {
            return null;
        }

        var kind = MemoryGateFindingKindExtensions.ParseKind(raw.Kind ?? MemoryGateFindingKind.Secret.RawValue());
        if (kind == null)
        {
            return null;
        }

        return new EntropyConfig(raw.Enabled, raw.Label, kind.Value, raw.MinLength, raw.MaxLength, raw.MinShannonEntropy);
    }
}

/// <summary>The corpus-declared validators. Swift: <c>passesLuhn</c> / <c>hasBoundedIPv4Octets</c>.</summary>
public static class MemoryGateValidators
{
    /// <summary>Luhn (mod-10) over the digits, requiring 13–19 digits. Swift: <c>passesLuhn(_:)</c>.</summary>
    public static bool PassesLuhn(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var digits = new List<int>();
        foreach (char ch in value)
        {
            if (ch >= '0' && ch <= '9')
            {
                digits.Add(ch - '0');
            }
        }

        if (digits.Count < 13 || digits.Count > 19)
        {
            return false;
        }

        int sum = 0;
        bool doubling = false;
        for (int i = digits.Count - 1; i >= 0; i--)
        {
            int current = digits[i];
            if (doubling)
            {
                current *= 2;
                if (current > 9)
                {
                    current -= 9;
                }
            }

            sum += current;
            doubling = !doubling;
        }

        return sum % 10 == 0;
    }

    /// <summary>Every dotted octet must parse and be in 0–255. Swift: <c>hasBoundedIPv4Octets(_:)</c>.</summary>
    public static bool HasBoundedIpv4Octets(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        string[] octets = value.Split('.');
        if (octets.Length != 4)
        {
            return false;
        }

        foreach (string octet in octets)
        {
            if (octet.Length == 0)
            {
                return false;
            }

            foreach (char ch in octet)
            {
                if (!char.IsNumber(ch))
                {
                    return false;
                }
            }

            if (!int.TryParse(octet, out int number) || number < 0 || number > 255)
            {
                return false;
            }
        }

        return true;
    }
}
