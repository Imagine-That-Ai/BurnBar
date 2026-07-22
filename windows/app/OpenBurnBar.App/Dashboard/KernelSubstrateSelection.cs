using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Maps the shared 31-name kernel catalog onto the native Win2D substrate
/// painters. Windows keeps the same picker and persisted ids as macOS while
/// avoiding WebView2 airspace over the XAML dashboard.
/// </summary>
public static class KernelSubstrateSelection
{
    private static readonly IReadOnlyDictionary<string, string> SubstrateByKernel =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["constellation"] = "constellation.stellarium",
            ["flow"] = "flow.silk-streamline",
            ["aurora"] = "aurora.wisp",
            ["mesh"] = "mesh.mesh-caustic",
            ["moire"] = "moire.fringe-bloom",
            ["volumetric"] = "volumetric.sunshaft",
            ["lic"] = "flow.plankton-wake",
            ["fluid-aurora"] = "aurora.filament",
            ["cloudfield"] = "volumetric.smoked-glass",
            ["plasma-orbs"] = "constellation.starfire",
            ["blobs-mesh"] = "mesh.mesh-patch",
            ["retro-plasma"] = "moire.film-bubble",
            ["inversion-lattice"] = "moire.lattice-facet",
            ["vogel-bloom"] = "constellation.starsapphire",
            ["crystal-drift"] = "aurora.ice-prism",
            ["ripple-lattice"] = "moire.ruling-grating",
            ["liquid-lumen"] = "flow.glass-ribbon",
            ["spectral-drift"] = "aurora.drift-motes",
            ["mycelium-mesh"] = "mesh.mesh-isoline",
            ["oilfield"] = "volumetric.dust-motes",
            ["suminagashi-drift"] = "flow.petal-drift",
            ["kinetic-stipple"] = "mesh.mesh-grain",
            ["agent1"] = "constellation.rimefrost",
            ["neural-bloom"] = "constellation.starfire",
            ["aether-lattice"] = "moire.lattice-facet",
            ["bat-signal"] = "volumetric.sunshaft",
            ["storm-signal"] = "flow.plankton-wake",
            ["origami"] = "mesh.mesh-patch",
            ["ink-diffusion"] = "volumetric.smoked-glass",
            ["petroleum-sheen"] = "moire.film-bubble",
            ["boids"] = "flow.silk-streamline",
        };

    public static string SubstrateIdFor(string? kernelId)
    {
        string resolved = KernelCatalog.Resolve(kernelId);
        return SubstrateByKernel.TryGetValue(resolved, out string? substrateId)
            ? substrateId
            : SubstrateByKernel[KernelCatalog.DefaultId];
    }
}
