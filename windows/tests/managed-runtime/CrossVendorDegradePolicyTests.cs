using System;
using System.Collections.Generic;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CrossVendorDegradePolicyTests
{
    [Fact]
    public void EnvironmentPolicyIsDisabledUnlessExplicitlyEnabled()
    {
        var environment = new Dictionary<string, string?>
        {
            [CrossVendorDegradePolicy.VendorsEnvironmentVariable] = "openai",
        };

        CrossVendorDegradePolicy policy = CrossVendorDegradePolicy.FromEnvironment(environment);

        Assert.False(policy.IsEnabled);
        Assert.Equal(new[] { "deepseek", "zai", "moonshot" }, policy.AllowedVendorIds);
    }

    [Theory]
    [InlineData("1")]
    [InlineData("TRUE")]
    [InlineData("yes")]
    [InlineData("on")]
    public void EnvironmentPolicyNormalizesExplicitVendorAllowlist(string flag)
    {
        var environment = new Dictionary<string, string?>
        {
            [CrossVendorDegradePolicy.EnabledEnvironmentVariable] = flag,
            [CrossVendorDegradePolicy.VendorsEnvironmentVariable] = " OpenAI, ZAI, openai ",
        };

        CrossVendorDegradePolicy policy = CrossVendorDegradePolicy.FromEnvironment(environment);

        Assert.True(policy.IsEnabled);
        Assert.Equal(new[] { "openai", "zai" }, policy.AllowedVendorIds);
    }

    [Fact]
    public void PolicyAllowsOnlyPreferredOpenAICompatibleModel()
    {
        CrossVendorDegradePolicy policy = CrossVendorDegradePolicy.Create(
            true,
            new[] { "openai", "anthropic" },
            new Dictionary<string, string> { ["openai"] = "gpt-fallback" });

        Assert.True(policy.Allows(Route("openai", "gpt-fallback", "openai-compatible")));
        Assert.False(policy.Allows(Route("openai", "other-model", "openai-compatible")));
        Assert.False(policy.Allows(Route("anthropic", "claude", "anthropic")));
        Assert.False(policy.Allows(Route("zai", "glm", "openai-compatible")));
    }

    [Fact]
    public void PolicyClampsCandidatesAndVendorCount()
    {
        string[] vendors = new string[CrossVendorDegradePolicy.MaximumVendorCount + 5];
        for (int index = 0; index < vendors.Length; index++) vendors[index] = "vendor-" + index;

        CrossVendorDegradePolicy policy = CrossVendorDegradePolicy.Create(
            true,
            vendors,
            preferredModelByVendorId: new Dictionary<string, string>(),
            maxCandidates: int.MaxValue);

        Assert.Equal(CrossVendorDegradePolicy.MaximumVendorCount, policy.AllowedVendorIds.Count);
        Assert.Equal(CrossVendorDegradePolicy.MaximumCandidatesLimit, policy.MaxCandidates);
    }

    private static ModelRoute Route(string vendor, string model, string format) => new(
        vendor + "-route",
        vendor,
        model,
        0,
        true,
        Routing: new ModelRouteRoutingMetadata(
            FormatFamily: format,
            TrustStatus: ModelRouteTrustStatus.Ready));
}
