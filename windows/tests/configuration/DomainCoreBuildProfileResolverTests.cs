using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class DomainCoreBuildProfileResolverTests
{
    private const string CandidateCommit = "0123456789abcdef0123456789abcdef01234567";
    private const string ExpectedVersion = "0.3.0";
    private const string ExpectedSourceSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public void Development_profile_accepts_valid_environment_modes_but_never_evidence()
    {
        var profile = DomainCoreBuildProfileResolver.Resolve(
            new Dictionary<string, string>(),
            key => key == "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE" ? "RUST" : null);

        Assert.True(profile.IsValid);
        Assert.Equal("rust", profile.Modes["hermes"]);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.RolloutChannel);
        Assert.Null(profile.CandidateIdentity);
    }

    [Fact]
    public void Signed_public_profile_ignores_environment_and_forbids_shadow_evidence()
    {
        var metadata = Signed("public-production", "public", "", false, "legacy");
        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "shadow");
        Assert.True(profile.IsValid);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));
        Assert.Equal(CandidateCommit, profile.CandidateIdentity?.CandidateCommit);
        Assert.False(profile.EvidenceEnabled);

        metadata["OpenBurnBar.DomainCore.EvidenceEnabled"] = "true";
        metadata["OpenBurnBar.DomainCore.Mode.hermes"] = "shadow";
        profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "rust");
        Assert.False(profile.IsValid);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.RolloutChannel);
        Assert.Null(profile.CandidateIdentity);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));
    }

    [Theory]
    [InlineData("internal")]
    [InlineData("beta")]
    public void Signed_rollout_profiles_require_matching_channel_evidence_and_quota_shadow(string channel)
    {
        var metadata = Signed(channel, channel, channel, true, "shadow");
        Assert.True(DomainCoreBuildProfileResolver.Resolve(metadata, _ => null).IsValid);

        metadata["OpenBurnBar.DomainCore.RolloutChannel"] = channel == "internal" ? "beta" : "internal";
        Assert.False(DomainCoreBuildProfileResolver.Resolve(metadata, _ => null).IsValid);
    }

    [Theory]
    [InlineData("1.0.0")]
    [InlineData("0.3.0-alpha.1")]
    [InlineData("12.34.56-rc.2+windows.x64")]
    public void Signed_profiles_expose_a_typed_canonical_candidate_identity(string version)
    {
        var metadata = Signed("internal", "internal", "internal", true, "shadow");
        metadata["OpenBurnBar.DomainCore.ExpectedVersion"] = version;

        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "rust");

        Assert.True(profile.IsValid);
        var candidate = Assert.IsType<DomainCoreCandidateIdentity>(profile.CandidateIdentity);
        Assert.Equal(CandidateCommit, candidate.CandidateCommit);
        Assert.Equal(version, candidate.ExpectedCoreVersion);
        Assert.Equal((uint)3, candidate.ExpectedCoreAbiVersion);
        Assert.Equal(ExpectedSourceSha256, candidate.ExpectedCoreSourceSha256);
    }

    [Theory]
    [InlineData("OpenBurnBar.DomainCore.CandidateCommit", "")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedVersion", "")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedAbiVersion", "")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedSourceSha256", "")]
    [InlineData("OpenBurnBar.DomainCore.CandidateCommit", "A123456789abcdef0123456789abcdef01234567")]
    [InlineData("OpenBurnBar.DomainCore.CandidateCommit", "0123456789abcdef0123456789abcdef0123456")]
    [InlineData("OpenBurnBar.DomainCore.CandidateCommit", "g123456789abcdef0123456789abcdef01234567")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedVersion", "01.2.3")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedVersion", "1.2.3-01")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedVersion", "1.2")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedVersion", "1.2.3 ")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedAbiVersion", "0")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedAbiVersion", "-1")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedAbiVersion", "03")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedAbiVersion", "4294967296")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedSourceSha256", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedSourceSha256", "gaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("OpenBurnBar.DomainCore.ExpectedSourceSha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    public void Every_signed_profile_rejects_a_missing_or_malformed_candidate_field(string key, string value)
    {
        foreach (var profileName in new[] { "public-production", "internal", "beta" })
        {
            var distribution = profileName == "public-production" ? "public" : profileName;
            var channel = profileName == "public-production" ? "" : profileName;
            var evidence = profileName != "public-production";
            var mode = profileName == "public-production" ? "legacy" : "shadow";
            var metadata = Signed(profileName, distribution, channel, evidence, mode);
            metadata[key] = value;

            var resolved = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "rust");

            Assert.False(resolved.IsValid);
            Assert.False(resolved.EvidenceEnabled);
            Assert.Null(resolved.CandidateIdentity);
            Assert.All(resolved.Modes.Values, resolvedMode => Assert.Equal("legacy", resolvedMode));
        }
    }

    [Fact]
    public void Candidate_identity_accepts_the_semver_length_and_uint32_upper_bound()
    {
        var metadata = Signed("beta", "beta", "beta", true, "shadow");
        var maximumLengthVersion = $"1.2.3+{new string('a', 58)}";
        Assert.Equal(64, maximumLengthVersion.Length);
        metadata["OpenBurnBar.DomainCore.ExpectedVersion"] = maximumLengthVersion;
        metadata["OpenBurnBar.DomainCore.ExpectedAbiVersion"] = uint.MaxValue.ToString();

        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => null);

        Assert.True(profile.IsValid);
        Assert.Equal(maximumLengthVersion, profile.CandidateIdentity?.ExpectedCoreVersion);
        Assert.Equal(uint.MaxValue, profile.CandidateIdentity?.ExpectedCoreAbiVersion);

        metadata["OpenBurnBar.DomainCore.ExpectedVersion"] += "a";
        profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => null);
        Assert.False(profile.IsValid);
        Assert.Null(profile.CandidateIdentity);
    }

    [Fact]
    public void Signed_profile_does_not_read_candidate_identity_from_environment()
    {
        var metadata = Signed("internal", "internal", "internal", true, "shadow");
        metadata.Remove("OpenBurnBar.DomainCore.CandidateCommit");

        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, key => key.Contains("CANDIDATE", StringComparison.Ordinal) ? CandidateCommit : null);

        Assert.False(profile.IsValid);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.CandidateIdentity);
    }

    [Fact]
    public void Signed_profile_rejects_an_entirely_absent_candidate_identity()
    {
        var metadata = Signed("beta", "beta", "beta", true, "shadow");
        foreach (var suffix in new[] { "CandidateCommit", "ExpectedVersion", "ExpectedAbiVersion", "ExpectedSourceSha256" })
        {
            metadata.Remove($"OpenBurnBar.DomainCore.{suffix}");
        }

        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => null);

        Assert.False(profile.IsValid);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.CandidateIdentity);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));
    }

    [Fact]
    public void Developer_may_omit_candidate_but_rejects_partial_or_invalid_metadata()
    {
        var profile = DomainCoreBuildProfileResolver.Resolve(new Dictionary<string, string>(), _ => null);
        Assert.True(profile.IsValid);
        Assert.Null(profile.CandidateIdentity);

        var partial = new Dictionary<string, string>
        {
            ["OpenBurnBar.DomainCore.CandidateCommit"] = CandidateCommit,
        };
        profile = DomainCoreBuildProfileResolver.Resolve(partial, _ => "rust");
        Assert.False(profile.IsValid);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.CandidateIdentity);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));
    }

    [Theory]
    [InlineData("sigend")]
    [InlineData("$(DOMAIN_CORE_BUILD_AUTHORITY)")]
    public void Unknown_authority_fails_closed_and_ignores_environment(string authority)
    {
        var metadata = Signed("internal", "internal", "internal", true, "shadow");
        metadata["OpenBurnBar.DomainCore.BuildAuthority"] = authority;

        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "rust");

        Assert.False(profile.IsValid);
        Assert.Equal(authority, profile.ArtifactAuthority);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.RolloutChannel);
        Assert.Null(profile.CandidateIdentity);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));
    }

    private static Dictionary<string, string> Signed(
        string name,
        string distribution,
        string channel,
        bool evidence,
        string mode)
    {
        var metadata = new Dictionary<string, string>
        {
            ["OpenBurnBar.DomainCore.BuildAuthority"] = "signed",
            ["OpenBurnBar.DomainCore.BuildProfile"] = name,
            ["OpenBurnBar.DomainCore.Distribution"] = distribution,
            ["OpenBurnBar.DomainCore.RolloutChannel"] = channel,
            ["OpenBurnBar.DomainCore.EvidenceEnabled"] = evidence.ToString(),
            ["OpenBurnBar.DomainCore.CandidateCommit"] = CandidateCommit,
            ["OpenBurnBar.DomainCore.ExpectedVersion"] = ExpectedVersion,
            ["OpenBurnBar.DomainCore.ExpectedAbiVersion"] = "3",
            ["OpenBurnBar.DomainCore.ExpectedSourceSha256"] = ExpectedSourceSha256,
        };
        foreach (var domain in new[] { "quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing" })
        {
            metadata[$"OpenBurnBar.DomainCore.Mode.{domain}"] = mode;
        }
        return metadata;
    }
}
