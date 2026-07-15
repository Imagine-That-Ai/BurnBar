using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Configuration;

public sealed record DomainCoreCandidateIdentity(
    string CandidateCommit,
    string ExpectedCoreVersion,
    uint ExpectedCoreAbiVersion,
    string ExpectedCoreSourceSha256);

public sealed record DomainCoreBuildProfile(
    string Name,
    string ArtifactAuthority,
    string Distribution,
    string? RolloutChannel,
    bool EvidenceEnabled,
    IReadOnlyDictionary<string, string> Modes,
    DomainCoreCandidateIdentity? CandidateIdentity,
    bool IsValid);

public static class DomainCoreBuildProfileResolver
{
    private static readonly string[] Domains =
    [
        "quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing",
    ];

    private static readonly Regex CanonicalSemVer = new(
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" +
        "(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)" +
        "(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?" +
        "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    public static DomainCoreBuildProfile Current() => Resolve(
        typeof(DomainCoreBuildProfileResolver).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .ToDictionary(attribute => attribute.Key, attribute => attribute.Value ?? string.Empty, StringComparer.Ordinal),
        Environment.GetEnvironmentVariable);

    public static string Mode(string domain, string environmentKey)
    {
        var profile = Current();
        if (!profile.IsValid) return "legacy";
        if (!profile.Modes.TryGetValue(domain, out var embedded)) return "legacy";
        if (profile.ArtifactAuthority != "development") return embedded;
        var raw = Environment.GetEnvironmentVariable(environmentKey)?.Trim().ToLowerInvariant();
        return raw is "legacy" or "shadow" or "rust" ? raw : embedded;
    }

    public static string? EvidenceChannel()
    {
        var profile = Current();
        return profile.IsValid && profile.EvidenceEnabled ? profile.RolloutChannel : null;
    }

    public static DomainCoreBuildProfile Resolve(
        IReadOnlyDictionary<string, string> metadata,
        Func<string, string?> environment)
    {
        var authority = Value(metadata, "BuildAuthority") ?? "development";
        var candidateIsValid = TryCandidateIdentity(metadata, out var candidateIdentity);
        if (authority is "" or "development")
        {
            if (!candidateIsValid) return FailClosedDevelopment();
            var developmentModes = Domains.ToDictionary(
                domain => domain,
                domain => ValidMode(environment(EnvironmentKey(domain))) ?? ValidMode(Value(metadata, $"Mode.{domain}")) ?? "legacy",
                StringComparer.Ordinal);
            return new("developer", "development", "development", null, false, developmentModes, candidateIdentity, true);
        }
        if (authority != "signed") return FailClosedUntrusted(authority);
        if (!candidateIsValid || candidateIdentity is null) return FailClosedSigned();

        var modes = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var domain in Domains)
        {
            var mode = ValidMode(Value(metadata, $"Mode.{domain}"));
            if (mode is null) return FailClosedSigned();
            modes[domain] = mode;
        }
        var name = Value(metadata, "BuildProfile");
        var distribution = Value(metadata, "Distribution");
        var channel = Value(metadata, "RolloutChannel");
        if (string.IsNullOrEmpty(channel)) channel = null;
        var evidence = bool.TryParse(Value(metadata, "EvidenceEnabled"), out var enabled) && enabled;
        var valid = (name, distribution) switch
        {
            ("public-production", "public") => !evidence && channel is null && !modes.Values.Contains("shadow"),
            ("internal", "internal") or ("beta", "beta") => evidence && channel == distribution && modes["quota"] == "shadow",
            _ => false,
        };
        return valid
            ? new(name!, "signed", distribution!, channel, evidence, modes, candidateIdentity, true)
            : FailClosedSigned();
    }

    private static bool TryCandidateIdentity(
        IReadOnlyDictionary<string, string> metadata,
        out DomainCoreCandidateIdentity? candidateIdentity)
    {
        candidateIdentity = null;
        var candidateCommit = CandidateValue(metadata, "CandidateCommit");
        var expectedVersion = CandidateValue(metadata, "ExpectedVersion");
        var expectedAbiVersion = CandidateValue(metadata, "ExpectedAbiVersion");
        var expectedSourceSha256 = CandidateValue(metadata, "ExpectedSourceSha256");
        var values = new[] { candidateCommit, expectedVersion, expectedAbiVersion, expectedSourceSha256 };

        if (values.All(string.IsNullOrEmpty)) return true;
        if (values.Any(string.IsNullOrEmpty)) return false;
        if (!IsLowerHex(candidateCommit!, 40)) return false;
        if (expectedVersion!.Length > 64 || !CanonicalSemVer.IsMatch(expectedVersion)) return false;
        var abiText = expectedAbiVersion!;
        if (
            abiText.Any(character => character is < '0' or > '9') ||
            abiText[0] == '0' ||
            !uint.TryParse(abiText, NumberStyles.None, CultureInfo.InvariantCulture, out var abiVersion) ||
            abiVersion < 1)
        {
            return false;
        }
        if (!IsLowerHex(expectedSourceSha256!, 64)) return false;

        candidateIdentity = new(candidateCommit!, expectedVersion, abiVersion, expectedSourceSha256!);
        return true;
    }

    private static string? CandidateValue(IReadOnlyDictionary<string, string> metadata, string suffix) =>
        metadata.TryGetValue($"OpenBurnBar.DomainCore.{suffix}", out var value) ? value : null;

    private static bool IsLowerHex(string value, int length) =>
        value.Length == length && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static string? Value(IReadOnlyDictionary<string, string> metadata, string suffix) =>
        metadata.TryGetValue($"OpenBurnBar.DomainCore.{suffix}", out var value) ? value.Trim() : null;

    private static string? ValidMode(string? value) => value?.Trim().ToLowerInvariant() is var mode && mode is "legacy" or "shadow" or "rust" ? mode : null;

    private static string EnvironmentKey(string domain) => domain switch
    {
        "quota" => "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
        "cloudVault" => "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
        "cloudVaultRewrap" => "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
        "cloudVaultSearch" => "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
        "hermes" => "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
        "pricing" => "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
        _ => string.Empty,
    };

    private static DomainCoreBuildProfile FailClosedSigned() => new(
        "invalid-signed-profile",
        "signed",
        "invalid",
        null,
        false,
        Domains.ToDictionary(domain => domain, _ => "legacy", StringComparer.Ordinal),
        null,
        false);

    private static DomainCoreBuildProfile FailClosedDevelopment() => new(
        "invalid-development-profile",
        "development",
        "invalid",
        null,
        false,
        Domains.ToDictionary(domain => domain, _ => "legacy", StringComparer.Ordinal),
        null,
        false);

    private static DomainCoreBuildProfile FailClosedUntrusted(string authority) => new(
        "invalid-signed-profile",
        authority,
        "invalid",
        null,
        false,
        Domains.ToDictionary(domain => domain, _ => "legacy", StringComparer.Ordinal),
        null,
        false);
}
