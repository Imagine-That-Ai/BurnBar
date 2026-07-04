using System.Collections.Generic;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Catalog;

/// <summary>
/// Volumetric family substrate registry — C# port of Swift
/// <c>Views/Substrate/Families/VolumetricFamily.swift</c>. Depth / cloud density fields
/// with blur: Crepuscular Shafts + Smoked Glass Slab + Silk Filament + Dust Motes.
/// Accent pairs are byte-identical to the Swift table.
/// </summary>
public static class VolumetricFamily
{
    public static readonly IReadOnlyList<SubstrateDescriptor> Styles = new[]
    {
        new SubstrateDescriptor(
            "volumetric.sunshaft", SubstrateFamily.Volumetric,
            "Crepuscular Shafts", "godrays",
            new Rgba(120 / 255.0, 180 / 255.0, 1.0), new Rgba(1.0, 200 / 255.0, 150 / 255.0),
            static () => new SunshaftSubstrate()),
        new SubstrateDescriptor(
            "volumetric.smoked-glass", SubstrateFamily.Volumetric,
            "Smoked Glass Slab", "glass",
            new Rgba(150 / 255.0, 170 / 255.0, 200 / 255.0), new Rgba(200 / 255.0, 210 / 255.0, 230 / 255.0),
            static () => new SmokedGlassSubstrate()),
        new SubstrateDescriptor(
            "volumetric.silk-filament", SubstrateFamily.Volumetric,
            "Silk Filament", "filament",
            new Rgba(140 / 255.0, 190 / 255.0, 1.0), new Rgba(1.0, 215 / 255.0, 170 / 255.0),
            static () => new SilkFilamentSubstrate()),
        new SubstrateDescriptor(
            "volumetric.dust-motes", SubstrateFamily.Volumetric,
            "Dust Motes", "motes",
            new Rgba(200 / 255.0, 200 / 255.0, 220 / 255.0), new Rgba(1.0, 210 / 255.0, 180 / 255.0),
            static () => new DustMotesSubstrate()),
    };
}
