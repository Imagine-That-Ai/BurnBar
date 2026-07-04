using System.Collections.Generic;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Catalog;

/// <summary>
/// Constellation family substrate registry — C# port of Swift
/// <c>Views/Substrate/Families/ConstellationFamily.swift</c>. The star-field / link
/// family: Stellar Plasma (Starfire, landed in #1202) + Cut Star Sapphire + Drawn
/// Constellation + Dendritic Frost. Accent pairs are byte-identical to the Swift table.
/// </summary>
public static class ConstellationFamily
{
    public static readonly IReadOnlyList<SubstrateDescriptor> Styles = new[]
    {
        new SubstrateDescriptor(
            "constellation.starfire", SubstrateFamily.Constellation,
            "Stellar Plasma", "twinkle",
            new Rgba(131 / 255.0, 142 / 255.0, 1.0), new Rgba(150 / 255.0, 200 / 255.0, 1.0),
            static () => new StarfireSubstrate()),
        new SubstrateDescriptor(
            "constellation.starsapphire", SubstrateFamily.Constellation,
            "Cut Star Sapphire", "facets",
            new Rgba(120 / 255.0, 170 / 255.0, 1.0), new Rgba(180 / 255.0, 220 / 255.0, 1.0),
            static () => new StarSapphireSubstrate()),
        new SubstrateDescriptor(
            "constellation.stellarium", SubstrateFamily.Constellation,
            "Drawn Constellation", "lines",
            new Rgba(150 / 255.0, 170 / 255.0, 1.0), new Rgba(200 / 255.0, 215 / 255.0, 1.0),
            static () => new StellariumSubstrate()),
        new SubstrateDescriptor(
            "constellation.rimefrost", SubstrateFamily.Constellation,
            "Dendritic Frost", "frost",
            new Rgba(190 / 255.0, 215 / 255.0, 1.0), new Rgba(225 / 255.0, 240 / 255.0, 1.0),
            static () => new RimefrostSubstrate()),
    };
}
