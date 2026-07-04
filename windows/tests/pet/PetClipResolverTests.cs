using System;
using System.Collections.Generic;
using OpenBurnBar.App.Pet;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetClipResolverTests
{
    private static PetClipResolver Resolver(
        IReadOnlyDictionary<string, string>? aliases = null,
        params string[] available)
    {
        return new PetClipResolver(
            aliases ?? new Dictionary<string, string>(StringComparer.Ordinal),
            new HashSet<string>(available, StringComparer.Ordinal));
    }

    [Fact]
    public void PrefersExplicitSemanticAlias()
    {
        var aliases = new Dictionary<string, string>(StringComparer.Ordinal) { ["listen"] = "Listen_Loop" };
        var r = Resolver(aliases, "Listen_Loop", "idle");
        Assert.Equal("Listen_Loop", r.Resolve("listen"));
    }

    [Fact]
    public void FallsBackToNodeNameWhenItIsAClip()
    {
        var r = Resolver(null, "idle", "react", "think");
        Assert.Equal("react", r.Resolve("react"));
    }

    [Fact]
    public void FallsBackToIdleWhenNodeMissing()
    {
        var r = Resolver(null, "idle", "scuttle");
        Assert.Equal("idle", r.Resolve("listen"));
    }

    [Fact]
    public void FallsBackToSmallestWhenNoIdle()
    {
        var r = Resolver(null, "zeta", "alpha", "mid");
        Assert.Equal("alpha", r.Resolve("listen"));
    }

    [Fact]
    public void NoClips_ReturnsNull()
    {
        var r = Resolver();
        Assert.Null(r.Resolve("idle"));
    }

    [Theory]
    [InlineData("idle", true)]
    [InlineData("listen", true)]
    [InlineData("react", false)] // the one-shot beat does not loop
    public void ShouldLoop_OnlyReactIsOneShot(string node, bool loops)
    {
        Assert.Equal(loops, PetClipResolver.ShouldLoop(node));
    }
}
