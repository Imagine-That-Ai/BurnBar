using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// One selectable dashboard-kernel identity. The ids and picker labels mirror
/// macOS while Windows resolves every entry to an airspace-free native substrate.
/// </summary>
public sealed record KernelCatalogEntry(string Id, string Label);

/// <summary>
/// The 31 bundled kernels, in registry order. Hardcoded (rather than read back
/// from <c>window.__kernels</c>) so the picker renders instantly offline.
/// Keep in sync with <c>AgentLens/Views/Dashboard/Components/KernelBackdropView.swift</c>
/// and the engine registry.
/// </summary>
public static class KernelCatalog
{
    /// <summary>Matches the bundle's own fallback when no hash/query is supplied.</summary>
    public const string DefaultId = "fluid-aurora";

    public static IReadOnlyList<KernelCatalogEntry> All { get; } = new KernelCatalogEntry[]
    {
        new("constellation", "Constellation"),
        new("flow", "Flow Field"),
        new("aurora", "Aurora"),
        new("mesh", "Iridescent Mesh"),
        new("moire", "Moiré"),
        new("volumetric", "Volumetric"),
        new("lic", "Flow Imaging"),
        new("fluid-aurora", "Fluid Aurora"),
        new("cloudfield", "Cloud Field"),
        new("plasma-orbs", "Plasma Orbs"),
        new("blobs-mesh", "Blobs Mesh"),
        new("retro-plasma", "Retro Plasma"),
        new("inversion-lattice", "Inversion Lattice"),
        new("vogel-bloom", "Vogel Bloom"),
        new("crystal-drift", "Crystal Drift"),
        new("ripple-lattice", "Ripple Lattice"),
        new("liquid-lumen", "Liquid Lumen"),
        new("spectral-drift", "Spectral Drift"),
        new("mycelium-mesh", "Mycelium Mesh"),
        new("oilfield", "Oilfield"),
        new("suminagashi-drift", "Suminagashi Drift"),
        new("kinetic-stipple", "Kinetic Stipple"),
        new("agent1", "Agent 1"),
        new("neural-bloom", "Neural Bloom"),
        new("aether-lattice", "Aether Lattice"),
        new("bat-signal", "Beacon"),
        new("storm-signal", "Tempest"),
        new("origami", "Origami"),
        new("ink-diffusion", "Ink Diffusion"),
        new("petroleum-sheen", "Petroleum Sheen"),
        new("boids", "Boids"),
    };

    /// <summary>Whether <paramref name="id"/> names a real kernel; guards the JS bridge against junk.</summary>
    public static bool IsValid(string? id) =>
        !string.IsNullOrEmpty(id) && All.Any(e => string.Equals(e.Id, id, StringComparison.Ordinal));

    /// <summary>Clamp a persisted id back to a known kernel (default when missing/stale).</summary>
    public static string Resolve(string? id) => IsValid(id) ? id! : DefaultId;

    public static string Label(string? id) =>
        All.FirstOrDefault(e => string.Equals(e.Id, id, StringComparison.Ordinal))?.Label ?? id ?? DefaultId;
}

/// <summary>
/// Shared preference keys for the kernel backdrop so the renderer and the
/// settings picker bind to the same store entries. Mirrors macOS
/// <c>KernelBackdropPreferences</c>.
/// </summary>
public static class KernelBackdropPreferences
{
    /// <summary>Selected kernel id. Default <see cref="KernelCatalog.DefaultId"/>.</summary>
    public const string KernelKey = "backdropKernel";

    /// <summary>
    /// Master gate: when on, the dashboard backdrop renders the selected native
    /// kernel analog instead of the layout-driven Win2D swarm fallback.
    /// </summary>
    public const string EnabledKey = "useKernelBackdrop";
}
