using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Volumetric family registry — C# port of Swift <c>Families/VolumetricFamily.swift</c>.
/// Depth / cloud-density fields with blur: Crepuscular Shafts + Smoked Glass Slab +
/// Silk Filament + Dust Motes. Ids / labels / accents mirror the Swift descriptors
/// byte-for-byte.
/// </summary>
public static class VolumetricFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "volumetric.sunshaft", family: SubstrateFamily.Volumetric,
            label: "Crepuscular Shafts", hint: "godrays",
            accent: new Rgba(120 / 255.0, 180 / 255.0, 1.0),
            accent2: new Rgba(1.0, 200 / 255.0, 150 / 255.0),
            make: () => new SunshaftSubstrate()),
        new SubstrateDescriptor(
            id: "volumetric.smoked-glass", family: SubstrateFamily.Volumetric,
            label: "Smoked Glass Slab", hint: "glass",
            accent: new Rgba(150 / 255.0, 170 / 255.0, 200 / 255.0),
            accent2: new Rgba(200 / 255.0, 210 / 255.0, 230 / 255.0),
            make: () => new SmokedGlassSubstrate()),
        new SubstrateDescriptor(
            id: "volumetric.silk-filament", family: SubstrateFamily.Volumetric,
            label: "Silk Filament", hint: "filament",
            accent: new Rgba(140 / 255.0, 190 / 255.0, 1.0),
            accent2: new Rgba(1.0, 215 / 255.0, 170 / 255.0),
            make: () => new SilkFilamentSubstrate()),
        new SubstrateDescriptor(
            id: "volumetric.dust-motes", family: SubstrateFamily.Volumetric,
            label: "Dust Motes", hint: "motes",
            accent: new Rgba(200 / 255.0, 200 / 255.0, 220 / 255.0),
            accent2: new Rgba(1.0, 210 / 255.0, 180 / 255.0),
            make: () => new DustMotesSubstrate()),
    };
}
