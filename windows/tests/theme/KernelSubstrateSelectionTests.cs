using System.Collections.Generic;
using OpenBurnBar.App.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

public sealed class KernelSubstrateSelectionTests
{
    private static readonly HashSet<string> NativeSubstrateIds = new()
    {
        "constellation.starfire",
        "constellation.starsapphire",
        "constellation.stellarium",
        "constellation.rimefrost",
        "flow.plankton-wake",
        "flow.glass-ribbon",
        "flow.silk-streamline",
        "flow.petal-drift",
        "aurora.wisp",
        "aurora.ice-prism",
        "aurora.filament",
        "aurora.drift-motes",
        "mesh.mesh-caustic",
        "mesh.mesh-patch",
        "mesh.mesh-isoline",
        "mesh.mesh-grain",
        "moire.fringe-bloom",
        "moire.lattice-facet",
        "moire.ruling-grating",
        "moire.film-bubble",
        "volumetric.sunshaft",
        "volumetric.smoked-glass",
        "volumetric.dust-motes",
    };

    [Fact]
    public void EveryKernelResolvesToAPortedNativeSubstrate()
    {
        foreach (KernelCatalogEntry kernel in KernelCatalog.All)
        {
            Assert.Contains(KernelSubstrateSelection.SubstrateIdFor(kernel.Id), NativeSubstrateIds);
        }
    }

    [Fact]
    public void UnknownKernelFallsBackToTheSharedDefault()
    {
        Assert.Equal(
            KernelSubstrateSelection.SubstrateIdFor(KernelCatalog.DefaultId),
            KernelSubstrateSelection.SubstrateIdFor("not-a-kernel"));
    }
}
