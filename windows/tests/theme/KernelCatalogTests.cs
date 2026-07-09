using OpenBurnBar.App.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

/// <summary>Locks the 31-kernel catalog against the shared WebGL2 bundle.</summary>
public sealed class KernelCatalogTests
{
    [Fact]
    public void All_HasThirtyOneKernels()
    {
        Assert.Equal(31, KernelCatalog.All.Count);
    }

    [Theory]
    [InlineData("fluid-aurora")]
    [InlineData("constellation")]
    [InlineData("volumetric")]
    [InlineData("aurora")]
    [InlineData("mesh")]
    [InlineData("flow")]
    [InlineData("boids")]
    [InlineData("origami")]
    public void Resolve_KnownIds(string id)
    {
        Assert.True(KernelCatalog.IsValid(id));
        Assert.Equal(id, KernelCatalog.Resolve(id));
    }

    [Fact]
    public void Resolve_Unknown_FallsBackToDefault()
    {
        Assert.Equal(KernelCatalog.DefaultId, KernelCatalog.Resolve("not-a-kernel"));
    }
}
