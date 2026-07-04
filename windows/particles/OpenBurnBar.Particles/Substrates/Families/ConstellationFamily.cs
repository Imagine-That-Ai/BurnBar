using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates.Families;

/// <summary>
/// Constellation family registry — C# port of Swift <c>Families/ConstellationFamily.swift</c>.
/// </summary>
/// <remarks>
/// Only the flagship <see cref="StarfireSubstrate"/> ("Stellar Plasma") is ported so far
/// (landed with the engine in PR #1202); the other three Constellation bespoke painters
/// (Star Sapphire / Stellarium / Rimefrost) are future ports, so this list is a faithful
/// but partial mirror of the 4-entry Swift registry. The Flow + Aurora families in this
/// lane are complete.
/// </remarks>
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
    };
}
