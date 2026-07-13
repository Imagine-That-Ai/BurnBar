using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class DomainCoreBuildProfileResolverTests
{
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
    }

    [Fact]
    public void Signed_public_profile_ignores_environment_and_forbids_shadow_evidence()
    {
        var metadata = Signed("public-production", "public", "", false, "legacy");
        var profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "shadow");
        Assert.True(profile.IsValid);
        Assert.All(profile.Modes.Values, mode => Assert.Equal("legacy", mode));

        metadata["OpenBurnBar.DomainCore.EvidenceEnabled"] = "true";
        metadata["OpenBurnBar.DomainCore.Mode.hermes"] = "shadow";
        profile = DomainCoreBuildProfileResolver.Resolve(metadata, _ => "rust");
        Assert.False(profile.IsValid);
        Assert.False(profile.EvidenceEnabled);
        Assert.Null(profile.RolloutChannel);
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
        };
        foreach (var domain in new[] { "quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing" })
        {
            metadata[$"OpenBurnBar.DomainCore.Mode.{domain}"] = mode;
        }
        return metadata;
    }
}
