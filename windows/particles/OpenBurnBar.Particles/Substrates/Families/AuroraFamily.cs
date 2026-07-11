using OpenBurnBar.Particles.Model;
using OpenBurnBar.Particles.Substrates.Aurora;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Aurora family registry — C# port of Swift <c>Families/AuroraFamily.swift</c>.
/// Layered gradient curtains with additive glow: will-o-wisp plasma, cut-gem polar
/// ice, one continuous glowing filament, drifting spore-motes. Ids / labels / accents
/// mirror the Swift descriptors byte-for-byte.
/// </summary>
public static class AuroraFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "aurora.wisp", family: SubstrateFamily.Aurora,
            label: "Wisp Plasma", hint: "will-o-wisp",
            accent: new Rgba(170 / 255.0, 130 / 255.0, 1.0),
            accent2: new Rgba(236 / 255.0, 150 / 255.0, 232 / 255.0),
            make: () => new WispSubstrate()),
        new SubstrateDescriptor(
            id: "aurora.ice-prism", family: SubstrateFamily.Aurora,
            label: "Polar Ice Prism", hint: "glacier-facets",
            accent: new Rgba(150 / 255.0, 200 / 255.0, 1.0),
            accent2: new Rgba(200 / 255.0, 230 / 255.0, 1.0),
            make: () => new IcePrismSubstrate()),
        new SubstrateDescriptor(
            id: "aurora.filament", family: SubstrateFamily.Aurora,
            label: "Aurora Filament", hint: "filament",
            accent: new Rgba(150 / 255.0, 1.0, 200 / 255.0),
            accent2: new Rgba(170 / 255.0, 150 / 255.0, 1.0),
            make: () => new AuroraFilamentSubstrate()),
        new SubstrateDescriptor(
            id: "aurora.drift-motes", family: SubstrateFamily.Aurora,
            label: "Drift Motes", hint: "spores",
            accent: new Rgba(200 / 255.0, 180 / 255.0, 1.0),
            accent2: new Rgba(1.0, 220 / 255.0, 240 / 255.0),
            make: () => new DriftMotesSubstrate()),
    };
}
