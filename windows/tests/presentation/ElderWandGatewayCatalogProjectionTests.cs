using System;
using System.Linq;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

public sealed class ElderWandGatewayCatalogProjectionTests
{
    [Fact]
    public void Groups_ExcludesUnconfiguredCompositionPlaceholders()
    {
        var groups = ElderWandGatewayCatalogProjection.Groups(new[]
        {
            new ModelRoute("placeholder", "openburnbar", "openburnbar-local", 0, true),
        });

        Assert.Empty(groups);
    }

    [Fact]
    public void Groups_UsesAnExecutableDuplicateRouteWhenAvailable()
    {
        var groups = ElderWandGatewayCatalogProjection.Groups(new[]
        {
            new ModelRoute(
                "offline",
                "anthropic",
                "claude-sonnet-4",
                1,
                false,
                new Uri("https://offline.example/v1/messages")),
            new ModelRoute(
                "online",
                "anthropic",
                "claude-sonnet-4",
                2,
                true,
                new Uri("https://online.example/v1/messages")),
        });

        ElderWandModelOption option = Assert.Single(Assert.Single(groups).Options);
        Assert.Equal("claude-sonnet-4", option.Id);
        Assert.True(option.IsRouteEligible);
    }

    [Fact]
    public void Groups_PreservesProviderPriorityAndSortsModelTitles()
    {
        var groups = ElderWandGatewayCatalogProjection.Groups(new[]
        {
            new ModelRoute(
                "openai-z",
                "openai",
                "z-model",
                30,
                true,
                new Uri("https://openai.example/v1/chat/completions")),
            new ModelRoute(
                "anthropic",
                "anthropic",
                "claude-sonnet-4",
                10,
                true,
                new Uri("https://anthropic.example/v1/messages")),
            new ModelRoute(
                "openai-a",
                "openai",
                "a-model",
                20,
                true,
                new Uri("https://openai.example/v1/chat/completions")),
        });

        Assert.Equal(new[] { "Anthropic", "OpenAI" }, groups.Select(group => group.ProviderName));
        Assert.Equal(
            new[] { "a-model", "z-model" },
            groups[1].Options.Select(option => option.Title));
    }

    [Fact]
    public void Groups_LeavesNonHttpRoutesVisibleButDisabled()
    {
        var groups = ElderWandGatewayCatalogProjection.Groups(new[]
        {
            new ModelRoute(
                "unsupported",
                "custom-provider",
                "custom/model",
                1,
                true,
                new Uri("ftp://models.example/custom")),
        });

        ElderWandProviderGroup group = Assert.Single(groups);
        Assert.Equal("custom-provider", group.ProviderName);
        Assert.False(Assert.Single(group.Options).IsRouteEligible);
    }
}
