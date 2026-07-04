using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Constellation family registry — C# port of Swift <c>Families/ConstellationFamily.swift</c>.
/// The star-field / link family: Stellar Plasma (Starfire, landed in #1202) + Cut Star
/// Sapphire + Drawn Constellation + Dendritic Frost (the remaining three landed with the
/// Volumetric lane, #1213). Ids / labels / accents mirror the Swift descriptors
/// byte-for-byte.
/// </summary>
public static class ConstellationFamily
{
    public static readonly SubstrateDescriptor[] Styles =
    {
        new SubstrateDescriptor(
            id: "constellation.starfire", family: SubstrateFamily.Constellation,
            label: "Stellar Plasma", hint: "twinkle",
            accent: new Rgba(131 / 255.0, 142 / 255.0, 1.0),
            accent2: new Rgba(150 / 255.0, 200 / 255.0, 1.0),
            make: () => new StarfireSubstrate()),
        new SubstrateDescriptor(
            id: "constellation.starsapphire", family: SubstrateFamily.Constellation,
            label: "Cut Star Sapphire", hint: "facets",
            accent: new Rgba(120 / 255.0, 170 / 255.0, 1.0),
            accent2: new Rgba(180 / 255.0, 220 / 255.0, 1.0),
            make: () => new StarSapphireSubstrate()),
        new SubstrateDescriptor(
            id: "constellation.stellarium", family: SubstrateFamily.Constellation,
            label: "Drawn Constellation", hint: "lines",
            accent: new Rgba(150 / 255.0, 170 / 255.0, 1.0),
            accent2: new Rgba(200 / 255.0, 215 / 255.0, 1.0),
            make: () => new StellariumSubstrate()),
        new SubstrateDescriptor(
            id: "constellation.rimefrost", family: SubstrateFamily.Constellation,
            label: "Dendritic Frost", hint: "frost",
            accent: new Rgba(190 / 255.0, 215 / 255.0, 1.0),
            accent2: new Rgba(225 / 255.0, 240 / 255.0, 1.0),
            make: () => new RimefrostSubstrate()),
    };
}
